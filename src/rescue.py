"""Restricted-network helpers; never change host DNS, routing or trust settings."""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tarfile
import tempfile


def architecture(machine,component):
    names={'x86_64':'amd64','aarch64':'arm64','arm64':'arm64','i386':'386','i486':'386','i586':'386','i686':'386',
           'armv7l':'armv7' if component=='sing-box' else 'arm'}
    if component not in ('sing-box','cloudflared') or machine not in names:raise ValueError('Unsupported Linux architecture')
    return names[machine]


def family():
    available=[]
    for version,target in (('4','1.1.1.1'),('6','2606:4700:4700::1111')):
        try:
            r=subprocess.run(['ip','-'+version,'route','get',target],capture_output=True,timeout=3)
            if r.returncode==0:available.append(version)
        except (OSError,subprocess.SubprocessError):pass
    return available[0] if len(available)==1 else 'auto'


def public_address(text):
    if not isinstance(text,str) or not text or len(text)>253:raise ValueError('Invalid public address')
    try:
        value=ipaddress.ip_address(text)
        if not value.is_global:raise ValueError('A public address is required')
        return str(value)
    except ValueError:
        if not re.fullmatch(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}',text):raise ValueError('Supply a public IP or hostname') from None
        return text.lower()


def verified_asset(directory,component,version,machine,destination):
    root=Path(directory)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():raise ValueError('Use an absolute trusted offline directory')
    arch=architecture(machine,component)
    if component=='sing-box':
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',version):raise ValueError('Invalid core version')
        name=f'sing-box-{version}-linux-{arch}.tar.gz';metadata=root/f'sing-box-{version}-release.json';tag='v'+version;repo='SagerNet/sing-box'
    else:
        name='cloudflared-linux-'+arch;metadata=root/'cloudflared-release.json';repo='cloudflare/cloudflared';tag=None
    if metadata.is_symlink() or not metadata.is_file() or metadata.stat().st_size>4194304:raise ValueError('Missing offline release metadata')
    release=json.loads(metadata.read_text())
    if release.get('draft') or release.get('prerelease'):raise ValueError('Stable release required')
    if tag and release['tag_name']!=tag:raise ValueError('Wrong offline core version')
    tag=release['tag_name']
    if component=='cloudflared' and not re.fullmatch(r'[0-9]{4}\.[0-9]+\.[0-9]+',tag):raise ValueError('Invalid cloudflared release')
    asset=next(a for a in release['assets'] if a['name']==name)
    if asset['browser_download_url']!=f'https://github.com/{repo}/releases/download/{tag}/{name}':raise ValueError('Wrong release asset origin')
    digest=asset.get('digest','')
    if not re.fullmatch(r'sha256:[a-fA-F0-9]{64}',digest):raise ValueError('Offline SHA256 required')
    source=root/name
    if source.is_symlink() or not source.is_file() or source.stat().st_size>268435456:raise ValueError('Missing/unsafe offline asset')
    data=source.read_bytes()
    if hashlib.sha256(data).hexdigest()!=digest[7:].lower():raise ValueError('Offline asset digest mismatch')
    target=Path(destination)
    if target.is_symlink():raise ValueError('Destination symlink')
    if component=='sing-box':
        # Extract only the expected regular binary, never archive paths or links.
        with tarfile.open(source,'r:gz') as archive:
            member=archive.getmember(f'sing-box-{version}-linux-{arch}/sing-box')
            if not member.isfile() or member.size>268435456:raise ValueError('Invalid archived binary')
            data=archive.extractfile(member).read()
    fd,tmp=tempfile.mkstemp(dir=target.parent)
    try:
        with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
        os.chmod(tmp,0o755);os.replace(tmp,target)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)


def argo_options(state,edge,transport):
    if edge not in ('auto','4','6') or transport not in ('auto','quic','http2'):raise ValueError('Invalid Argo transport settings')
    state=dict(state);state.update(edge_ip_version=edge,transport=transport)
    return state


def edge_probe(version):
    # A successful TCP connect is only TCP reachability, not a registered tunnel.
    af={'4':socket.AF_INET,'6':socket.AF_INET6,'auto':socket.AF_UNSPEC}[version]
    successes=0
    for host in ('region1.v2.argotunnel.com','region2.v2.argotunnel.com'):
        try:
            candidates=socket.getaddrinfo(host,7844,af,socket.SOCK_STREAM)
            for fam,kind,proto,_,address in candidates[:4]:
                try:
                    with socket.socket(fam,kind,proto) as sock:
                        sock.settimeout(2);sock.connect(address)
                    successes+=1;break
                except OSError:pass
        except OSError:pass
    return successes


if __name__=='__main__':
    import sys
    action,*args=sys.argv[1:]
    try:
        if action=='family':print(family())
        elif action=='arch':print(architecture(*args))
        elif action=='address':print(public_address(args[0]))
        elif action=='asset':verified_asset(*args)
        elif action=='edge':print(edge_probe(args[0]))
        elif action=='options':
            path=Path(args[0])
            if path.is_symlink():raise ValueError('Argo state symlink')
            data=argo_options(json.loads(path.read_text()),*args[1:]);fd,tmp=tempfile.mkstemp(dir=path.parent)
            with os.fdopen(fd,'w') as f:json.dump(data,f,indent=2)
            os.replace(tmp,path)
        else:raise ValueError('Unknown restricted-network operation')
    except (ValueError,KeyError,TypeError,OSError,StopIteration,tarfile.TarError):
        raise SystemExit('Restricted-network validation failed / 受限网络参数或离线文件校验失败') from None
