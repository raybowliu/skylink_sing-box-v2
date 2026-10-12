"""Run real manager functions in an isolated directory; never change host services."""
import base64
import contextlib
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import shlex
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('BASH_BIN', 'bash')
SB = os.environ.get('SING_BOX_BIN')
MIHOMO = os.environ.get('MIHOMO_BIN')
OPENSSL = os.environ.get('OPENSSL_BIN', 'openssl')


def port(kind=socket.SOCK_STREAM):
    with socket.socket(type=kind) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class ManagerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.base = self.root / 'manager'
        self.config = self.root / 'config'
        self.base.mkdir()
        (self.root/'systemd').mkdir()
        (self.root/'os-release').write_text('ID=debian\nPRETTY_NAME=Debian\n')
        self.config.mkdir()
        self.backups = self.base / 'backups'
        self.backups.mkdir()
        self.bin = self.root / 'sing-box'
        self.bin.write_text('#!/bin/sh\nexit 0\n')
        self.bin.chmod(0o700)
        self.cert = self.root / 'server.crt'
        self.key = self.root / 'server.key'
        subprocess.run([OPENSSL, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '2', '-subj', '/CN=127.0.0.1', '-addext',
                        'subjectAltName=IP:127.0.0.1,DNS:node.example', '-addext', 'basicConstraints=critical,CA:TRUE',
                        '-keyout', str(self.key), '-out', str(self.cert)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.password = secrets.token_urlsafe(24) + ':@ /?#'
        self.uuid = str(uuid.uuid4())
        self.private = self.public = ''
        if SB:
            result = subprocess.check_output([SB, 'generate', 'reality-keypair'], text=True)
            keys = dict(line.split(': ', 1) for line in result.strip().splitlines())
            self.private, self.public = keys['PrivateKey'], keys['PublicKey']

    def shell(self, command, input=None, ok=True):
        quote = shlex.quote
        variables = dict(BASE=self.base, CONF=self.config / 'config.json',
                         META=self.base / 'state.json', BACKUP=self.backups, BIN=self.bin,
                         LANG_FILE=self.base / 'language.conf', LANGUAGE_CHOICE='en_US',
                         REPORT=self.base / 'reports', SYSTEMD_DIR=self.root/'systemd',
                         OS_RELEASE=self.root/'os-release', MANAGER_BIN=self.root/'manager-command',
                         MANAGER_LIB=self.root/'manager-lib',
                         SYSCTL_FILE=self.root/'bbr.conf')
        script = 'source ' + quote(str(ROOT / 'singbox-v2.sh')) + '\n'
        script += '\n'.join(k + '=' + quote(str(v)) for k, v in variables.items()) + '\n'
        script += 'openssl(){ command ' + quote(OPENSSL) + ' "$@"; }\n'
        result = subprocess.run([BASH, '-c', script + command], input=input, text=True,
                                capture_output=True)
        if ok and result.returncode:
            self.fail(result.stderr + result.stdout)
        return result

    def configure(self, mode='3', cert_mode='1'):
        args = [self.config / 'config.json', self.base / 'state.json', '127.0.0.1',
                self.cert, self.key, 'addons.mozilla.org', self.uuid, self.private,
                self.public, secrets.token_hex(4), self.password, '127.0.0.1', mode, cert_mode]
        self.shell('write_config ' + ' '.join(shlex.quote(str(x)) for x in args))
        return json.loads((self.config / 'config.json').read_text())

    def exported(self, mode='3', cert_mode='1', hop=False):
        self.configure(mode, cert_mode)
        meta = json.loads((self.base / 'state.json').read_text())
        # Wrong cached mode: protocol detection must use the actual inbounds.
        meta.update(mode='1' if mode != '1' else '3', hop=hop)
        (self.base / 'state.json').write_text(json.dumps(meta))
        self.shell('exports')
        return json.loads((self.base / 'outbounds.json').read_text())

    def test_case_insensitive_confirmation(self):
        for word in ['yes', 'YES', 'Yes', 'yEs', '  YES  ']:
            self.shell('confirm test', input=word + '\n')
        for word in ['y', 'no', '', 'yes please', 'y e s']:
            self.assertNotEqual(self.shell('confirm test', input=word + '\n', ok=False).returncode, 0)

    def test_port_validation(self):
        for value in ['1', '443', '00443', '65535']:
            self.shell('valid_port ' + value)
        for value in ['0', '65536', '-1', 'abc', '999999999999999999999']:
            self.assertNotEqual(self.shell('valid_port ' + shlex.quote(value), ok=False).returncode, 0)

    def test_bilingual_language_persistence(self):
        self.shell('select_language; load_language; L 中文 English', input='2\n')
        self.assertEqual((self.base / 'language.conf').read_text(), 'en_US\n')
        self.assertEqual((self.base / 'language.conf').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.shell('LANGUAGE_CHOICE=zh_CN; L 中文 English').stdout, '中文')
        self.assertEqual(self.shell('LANGUAGE_CHOICE=en_US; L 中文 English').stdout, 'English')

    def test_three_server_modes(self):
        for mode, types in [('1', ['vless']), ('2', ['hysteria2']), ('3', ['vless', 'hysteria2'])]:
            cfg = self.configure(mode)
            self.assertEqual([i['type'] for i in cfg['inbounds']], types)
            if SB:
                subprocess.run([SB, 'check', '-c', str(self.config / 'config.json')], check=True)

    def test_exports_detect_protocol_and_secure_tls(self):
        for mode, count in [('1', 1), ('2', 1), ('3', 2)]:
            out = self.exported(mode)['outbounds']
            self.assertEqual(len(out), count)
            links = (self.base / 'nodes.txt').read_text().splitlines()
            self.assertEqual(len(links), count)
            encoded = (self.base / 'subscription-base64.txt').read_text()
            self.assertEqual(base64.b64decode(encoded).decode(), '\n'.join(links) + '\n')
            for node in out:
                self.assertFalse(node['tls'].get('insecure', False))
                if node['type'] == 'hysteria2':
                    self.assertEqual(node['password'], self.password)
                    self.assertEqual(node['tls']['certificate'], self.cert.read_text().splitlines())
            self.assertNotIn('PRIVATE KEY', (self.base / 'mihomo-proxies.yaml').read_text())
            for file in self.base.iterdir():
                if file.is_file():
                    self.assertEqual(file.stat().st_mode & 0o777, 0o600)
            if SB:
                subprocess.run([SB, 'check', '-c', str(self.base / 'outbounds.json')], check=True)

    def test_hy2_uri_escapes_password_and_pins_cert(self):
        import urllib.parse
        self.exported('2')
        uri = urllib.parse.urlsplit((self.base / 'nodes.txt').read_text().strip())
        self.assertEqual(urllib.parse.unquote(uri.username), self.password)
        query = urllib.parse.parse_qs(uri.query)
        self.assertEqual(query['insecure'], ['0'])
        der = ssl.PEM_cert_to_DER_cert(self.cert.read_text())
        self.assertEqual(query['pinSHA256'], [hashlib.sha256(der).hexdigest()])
        self.assertNotIn('REPLACE_WITH', (self.base / 'mihomo-proxies.yaml').read_text())
        self.assertIn('custom-certifactes:', (self.base / 'mihomo-proxies.yaml').read_text())

    def test_existing_certificate_and_hopping_export(self):
        out = self.exported('2', '2', True)['outbounds'][0]
        self.assertEqual(out['tls']['certificate'],self.cert.read_text().splitlines())
        self.assertEqual(out['server_ports'], ['20000:30000'])
        self.assertEqual(out['hop_interval'], '30s')
        yaml = (self.base / 'mihomo-proxies.yaml').read_text()
        self.assertIn('skip-cert-verify: false', yaml)
        self.assertIn('ports: "20000-30000"', yaml)

    def test_exports_follow_modified_protocol_ports(self):
        config=self.configure('3')
        for inbound in config['inbounds']: inbound['listen_port']=8443
        (self.config/'config.json').write_text(json.dumps(config))
        self.shell('exports')
        out=json.loads((self.base/'outbounds.json').read_text())['outbounds']
        self.assertEqual([i['server_port'] for i in out],[8443,8443])
        self.assertTrue(all(':8443?' in i for i in (self.base/'nodes.txt').read_text().splitlines()))

    def test_each_node_is_separated_and_trust_notes_are_localized(self):
        self.configure('3')
        for lang, label in [('zh_CN','节点：'),('en_US','Node: ')]:
            result=self.shell('LANGUAGE_CHOICE='+lang+'; exports')
            lines=result.stdout.splitlines()
            for index,line in enumerate(lines):
                if line.startswith(('vless://','hysteria2://')):
                    self.assertEqual(lines[index-3],'-'*64)
            self.assertEqual(sum(i.startswith(label) for i in lines),2)
            notes=(self.base/'subscription-notes.txt').read_text()
            self.assertIn('无域名模式仍使用 TLS' if lang=='zh_CN' else 'No-domain mode still uses self-signed TLS',notes)

    def test_ios_trust_profile_contains_only_public_certificate(self):
        import plistlib
        self.exported('2')
        profile=plistlib.loads((self.base/'hy2-client-ca.mobileconfig').read_bytes())
        self.assertEqual(profile['PayloadType'],'Configuration')
        self.assertEqual(len(profile['PayloadContent']),1)
        payload=profile['PayloadContent'][0]
        self.assertEqual(payload['PayloadType'],'com.apple.security.root')
        self.assertEqual(payload['PayloadContent'],ssl.PEM_cert_to_DER_cert(self.cert.read_text()))
        self.assertNotIn(self.password.encode(),(self.base/'hy2-client-ca.mobileconfig').read_bytes())
        self.assertNotIn(self.key.read_bytes(),(self.base/'hy2-client-ca.mobileconfig').read_bytes())
        self.assertEqual((self.base/'hy2-client-ca.mobileconfig').stat().st_mode & 0o777,0o600)
        self.assertEqual((self.base/'hy2-client-ca.cer').read_bytes(),payload['PayloadContent'])

    def test_leaf_cert_does_not_get_root_profile_or_leave_stale_profile(self):
        self.exported('2')
        self.assertTrue((self.base/'hy2-client-ca.mobileconfig').exists())
        subprocess.run([OPENSSL,'req','-x509','-key',str(self.key),'-days','2','-subj','/CN=127.0.0.1',
                        '-addext','subjectAltName=IP:127.0.0.1','-addext','basicConstraints=critical,CA:FALSE',
                        '-out',str(self.cert)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        self.shell('exports')
        self.assertFalse((self.base/'hy2-client-ca.mobileconfig').exists())
        self.assertIn('not a CA',(self.base/'subscription-notes.txt').read_text())

    def test_hy2_diagnostics_uses_actual_port_and_does_not_print_credentials(self):
        config=self.configure('2');config['inbounds'][0]['listen_port']=8443
        (self.config/'config.json').write_text(json.dumps(config))
        result=self.shell("""systemctl(){ return 0; }
ss(){ printf 'UNCONN 0 0 0.0.0.0:8443 0.0.0.0:*\\n'; }
ufw(){ printf 'Status: active\\n8443/udp ALLOW Anywhere\\n'; }
hy2_diagnostics""")
        self.assertIn('Local UDP 8443 has a listener',result.stdout)
        self.assertIn('Certificate expiry, name and key matching checks passed',result.stdout)
        self.assertNotIn('allow rule not detected',result.stdout)
        self.assertNotIn(self.password,result.stdout+result.stderr)
        self.assertIn('do not prove phone-to-VPS UDP reachability',result.stdout)

    def test_hy2_diagnostics_reports_stopped_service_and_missing_udp(self):
        self.configure('2')
        result=self.shell("""systemctl(){ return 1; }
ss(){ :; }
ufw(){ printf 'Status: inactive\\n'; }
hy2_diagnostics""")
        self.assertIn('sing-box is not active',result.stderr)
        self.assertIn('No local UDP 443 listener',result.stderr)

    def test_certificate_names_and_key_matching(self):
        command = 'validate_certificate ' + ' '.join(map(shlex.quote, [str(self.cert), str(self.key)]))
        self.shell(command + ' 127.0.0.1')
        self.shell(command + ' node.example')
        for name in ['127.0.0.2', 'wrong.example']:
            self.assertNotEqual(self.shell(command + ' ' + name, ok=False).returncode, 0)
        other = self.root / 'other.key'
        subprocess.run([OPENSSL, 'genrsa', '-out', str(other), '2048'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertNotEqual(self.shell('validate_certificate ' + ' '.join(map(shlex.quote,
                           [str(self.cert), str(other), '127.0.0.1'])), ok=False).returncode, 0)

    def test_backup_external_tls_and_restore(self):
        self.configure('2')
        before = self.shell('backup').stdout.strip()
        backup = Path(before)
        self.assertTrue((backup / 'sing-box.bin').is_file())
        self.assertTrue((backup / 'config' / 'config.json').is_file())
        self.assertEqual((backup / 'config' / 'hy2-backup.key').read_bytes(), self.key.read_bytes())
        self.cert.unlink()
        self.key.unlink()
        # Current backup requires usable files; restore must back up a still-operating deployment first.
        current = json.loads((self.config / 'config.json').read_text())
        current['inbounds'][0]['tls'].update(certificate_path=str(backup/'config'/'hy2-backup.crt'),
                                          key_path=str(backup/'config'/'hy2-backup.key'))
        (self.config/'config.json').write_text(json.dumps(current))
        self.shell('systemctl(){ :; }; service_healthy(){ :; }; nft(){ :; }; restore',
                   input=before + '\nyEs\n')
        restored = json.loads((self.config/'config.json').read_text())
        self.assertTrue(Path(restored['inbounds'][0]['tls']['key_path']).is_file())
        self.assertFalse(json.loads((self.base/'state.json').read_text())['hop'])

    def test_update_rolls_back_on_failed_start(self):
        self.configure('1')
        original = self.bin.read_bytes()
        code = '''download_binary(){ printf '#!/bin/sh\\nexit 0\\n# candidate\\n' > "$2"; chmod 700 "$2"; }
systemctl(){ :; }
service_healthy(){ return 1; }
apply_update 1.14.3'''
        result = self.shell(code, ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.bin.read_bytes(), original)
        self.assertEqual(list(self.base.glob('sing-box.candidate*')),[])

    def test_update_rejects_invalid_candidate(self):
        self.configure('1')
        original = self.bin.read_bytes()
        code = '''download_binary(){ printf '#!/bin/sh\\nexit 1\\n' > "$2"; chmod 700 "$2"; }
apply_update 1.14.3'''
        self.assertNotEqual(self.shell(code, ok=False).returncode, 0)
        self.assertEqual(self.bin.read_bytes(), original)

    def test_ssh_detection_preserves_connection_port(self):
        result = self.shell('''ss(){ printf '%s\\n' 'LISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=1))'; }
SSH_CONNECTION='192.0.2.1 1234 192.0.2.2 2200'
detect_ssh_ports
printf '%s' "$SSH_PORTS"''')
        self.assertIn('2200\n2222', result.stdout)

    def test_firewall_warns_missing_hy2_udp(self):
        self.configure('2')
        result = self.shell("ufw(){ printf 'Status: active\\n22/tcp ALLOW Anywhere\\n'; }; firewall_audit")
        self.assertIn('UDP 443 allow rule not detected', result.stdout)
        self.assertIn('provider firewall', result.stdout)

    def test_vnstat_daily_and_monthly(self):
        for choice, argument in [('2','-d'),('3','-m')]:
            result = self.shell('vnstat(){ printf "VNSTAT %s\\n" "$*"; }; traffic', input=choice+'\n')
            self.assertIn('NOT Reality/HY2 separately', result.stdout)
            self.assertIn('VNSTAT '+argument, result.stdout)

    def test_service_config_checked_before_restart(self):
        result = self.shell('systemctl(){ printf "SYSTEMCTL %s\\n" "$*"; }; service_manager', input='3\nyes\n', ok=False)
        self.assertNotIn('SYSTEMCTL restart', result.stdout)
        self.configure('1')
        result = self.shell('systemctl(){ printf "SYSTEMCTL %s\\n" "$*"; }; service_manager', input='3\nyes\n')
        self.assertIn('SYSTEMCTL restart sing-box', result.stdout)

    def test_ascii_brand_and_bilingual_menus(self):
        for language, text in [('en_US','View node information'), ('zh_CN','查看节点信息')]:
            result = self.shell('need_root(){ :; }; flock(){ :; }; LANGUAGE_CHOICE='+language+'; main', input='0\n')
            self.assertIn('███████╗', result.stdout)
            self.assertIn('SKYBYTE Manager V2.1', result.stdout)
            self.assertIn('https://www.youtube.com/@SKYBYTE9119', result.stdout)
            self.assertIn(text, result.stdout)

    def prepare_uninstall(self):
        self.configure('2')
        self.shell('systemctl(){ :; }; setup_service')
        (self.config/'unrelated.conf').write_text('keep user config')
        (self.base/'unrelated.txt').write_text('keep user file')

    def test_uninstall_cancellation_preserves_deployment(self):
        self.prepare_uninstall()
        self.shell('need_root(){ :; }; uninstall_manager', input='no\n')
        self.assertTrue(self.bin.exists())
        self.assertTrue((self.config/'config.json').exists())
        self.assertEqual(list(self.backups.iterdir()),[])

    def test_uninstall_backs_up_and_preserves_external_certs_and_unknown_files(self):
        self.prepare_uninstall()
        result=self.shell('need_root(){ :; }; systemctl(){ :; }; nft(){ return 1; }; uninstall_manager', input='yEs\n')
        self.assertIn('Uninstalled;',result.stdout)
        self.assertFalse(self.bin.exists())
        self.assertFalse((self.config/'config.json').exists())
        self.assertFalse((self.base/'state.json').exists())
        self.assertFalse((self.root/'systemd'/'sing-box.service').exists())
        self.assertTrue(self.cert.exists());self.assertTrue(self.key.exists())
        self.assertTrue((self.config/'unrelated.conf').exists())
        self.assertTrue((self.base/'unrelated.txt').exists())
        snapshots=list(self.backups.iterdir());self.assertEqual(len(snapshots),1)
        self.assertTrue((snapshots[0]/'sing-box.bin').exists())
        self.assertEqual((snapshots[0]/'config'/'hy2-backup.key').read_bytes(),self.key.read_bytes())

    def test_uninstall_removes_owned_auxiliary_units_and_manager_copies(self):
        self.prepare_uninstall()
        self.shell('need_root(){ :; }; systemctl(){ :; }; configure_auto',input='1\n')
        (self.root/'manager-lib').write_bytes((ROOT/'singbox-v2.sh').read_bytes())
        (self.root/'systemd'/'singbox-v2-hop.service').write_text('Description=singbox V2 HY2 IPv4 port hopping\n')
        result=self.shell("""need_root(){ :; }
systemctl(){ printf 'SYSTEMCTL %s\\n' "$*"; }
nft(){ printf 'NFT %s\\n' "$*"; }
uninstall_manager""",input='yes\n')
        self.assertFalse((self.root/'manager-lib').exists())
        self.assertFalse((self.root/'manager-command').exists())
        self.assertEqual(list((self.root/'systemd').iterdir()),[])
        self.assertIn('NFT delete table ip singbox_v2_hop',result.stdout)
        self.assertLess(result.stdout.index('disable --now singbox-v2-update.timer'),
                        result.stdout.index('disable --now sing-box.service'))

    def test_uninstall_preserves_unowned_hop_table_and_executable(self):
        self.prepare_uninstall()
        (self.root/'manager-command').write_text('unrelated executable')
        result=self.shell('need_root(){ :; }; systemctl(){ :; }; nft(){ printf UNEXPECTED_NFT; }; uninstall_manager',input='yes\n')
        self.assertNotIn('UNEXPECTED_NFT',result.stdout)
        self.assertEqual((self.root/'manager-command').read_text(),'unrelated executable')

    def test_uninstall_refuses_symlinked_binary(self):
        self.prepare_uninstall()
        target=self.root/'external-binary';self.bin.rename(target);self.bin.symlink_to(target)
        result=self.shell('need_root(){ :; }; uninstall_manager',input='yes\n',ok=False)
        self.assertNotEqual(result.returncode,0)
        self.assertTrue(target.exists());self.assertTrue(self.bin.is_symlink())

    def test_uninstall_preserves_existing_certificates_even_with_reserved_names(self):
        self.configure('2','2')
        self.shell('systemctl(){ :; }; setup_service')
        cert=self.config/'hy2-selfsigned.crt';key=self.config/'hy2-selfsigned.key'
        cert.write_bytes(self.cert.read_bytes());key.write_bytes(self.key.read_bytes())
        cfg=json.loads((self.config/'config.json').read_text())
        cfg['inbounds'][0]['tls'].update(certificate_path=str(cert),key_path=str(key))
        (self.config/'config.json').write_text(json.dumps(cfg))
        self.shell('need_root(){ :; }; systemctl(){ :; }; uninstall_manager',input='yes\n')
        self.assertTrue(cert.exists());self.assertTrue(key.exists())

    def test_uninstall_removes_new_and_legacy_managed_selfsigned_files(self):
        for legacy in [False,True]:
            self.bin.write_text('#!/bin/sh\nexit 0\n');self.bin.chmod(0o700)
            self.configure('2','1')
            self.shell('systemctl(){ :; }; setup_service')
            cert=self.config/'hy2-selfsigned.crt';key=self.config/'hy2-selfsigned.key'
            cert.write_bytes(self.cert.read_bytes());key.write_bytes(self.key.read_bytes())
            cfg=json.loads((self.config/'config.json').read_text())
            cfg['inbounds'][0]['tls'].update(certificate_path=str(cert),key_path=str(key))
            (self.config/'config.json').write_text(json.dumps(cfg))
            meta=json.loads((self.base/'state.json').read_text());meta['cert_path']=str(cert)
            if legacy:meta.pop('managed_certificates',None)
            else:meta['managed_certificates']=[str(cert),str(key)]
            (self.base/'state.json').write_text(json.dumps(meta))
            self.shell('need_root(){ :; }; systemctl(){ :; }; uninstall_manager',input='yes\n')
            self.assertFalse(cert.exists());self.assertFalse(key.exists())

    def test_uninstall_refuses_modified_service(self):
        self.prepare_uninstall()
        (self.root/'systemd'/'sing-box.service').write_text('Description=another deployment\n')
        result=self.shell('need_root(){ :; }; uninstall_manager',input='yes\n',ok=False)
        self.assertNotEqual(result.returncode,0)
        self.assertTrue(self.bin.exists())
        self.assertTrue((self.config/'config.json').exists())

    def test_uninstall_backup_failure_or_stop_failure_preserves_config(self):
        for failure in ['backup(){ return 1; }','systemctl(){ return 1; }']:
            self.prepare_uninstall()
            result=self.shell('need_root(){ :; }; '+failure+'; uninstall_manager',input='yes\n',ok=False)
            self.assertNotEqual(result.returncode,0)
            self.assertTrue(self.bin.exists())
            self.assertTrue((self.config/'config.json').exists())

    def test_installer_refuses_existing_user_config(self):
        self.configure('2')
        before = (self.config/'config.json').read_bytes()
        result = self.shell('need_root(){ :; }; install_protocol 2', input='yes\n', ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('refusing to overwrite', result.stderr)
        self.assertEqual((self.config/'config.json').read_bytes(), before)

    def test_weekly_auto_update_installs_manager_command(self):
        self.configure('1')
        self.shell('need_root(){ :; }; systemctl(){ :; }; configure_auto', input='1\n')
        self.assertEqual((self.root/'manager-command').read_bytes(), (ROOT/'singbox-v2.sh').read_bytes())
        service = (self.root/'systemd'/'singbox-v2-update.service').read_text()
        self.assertIn('--auto-update', service)
        self.assertTrue((self.root/'systemd'/'singbox-v2-update.timer').exists())

    def test_firewall_enable_keeps_ssh_and_hopping(self):
        self.configure('2')
        meta = json.loads((self.base/'state.json').read_text()); meta['hop']=True
        (self.base/'state.json').write_text(json.dumps(meta))
        result = self.shell("""need_root(){ :; }
ss(){ printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1))\\n'; }
ufw(){ printf 'UFW %s\\n' "$*"; }
firewall""", input='2\n\nyes\n')
        for rule in ['2222/tcp','443/udp','20000:30000/udp']:
            self.assertIn('UFW allow '+rule,result.stdout)
        self.assertIn('UFW --force enable', result.stdout)

    def test_hopping_persistence_and_disable(self):
        self.configure('2')
        mocks = """nft(){ if [[ $1 == list ]]; then return 1; fi; }
systemctl(){ :; }
ufw(){ printf 'Status: inactive\\n'; }
"""
        self.shell(mocks+'hop', input='1\n20000\n20100\nyes\n')
        self.assertIn('udp dport 20000-20100 redirect to :443', (self.base/'hop.nft').read_text())
        self.assertIn('ExecStop=/usr/sbin/nft delete table ip singbox_v2_hop',
                      (self.root/'systemd'/'singbox-v2-hop.service').read_text())
        self.assertTrue(json.loads((self.base/'state.json').read_text())['hop'])
        self.shell(mocks+'hop', input='2\nyes\n')
        self.assertFalse(json.loads((self.base/'state.json').read_text())['hop'])

    def test_initialization_does_not_enable_firewall_or_reboot(self):
        result = self.shell("""need_root(){ :; }
apt-get(){ printf 'APT %s\\n' "$*"; }
systemctl(){ printf 'SYSTEMCTL %s\\n' "$*"; }
timedatectl(){ :; }
getent(){ :; }
curl(){ :; }
ss(){ :; }
ufw(){ printf 'UFW %s\\n' "$*"; }
initialize_server""", input='yes\n')
        self.assertIn('APT upgrade -y',result.stdout)
        self.assertIn('APT install -y',result.stdout)
        self.assertNotIn('UFW --force enable',result.stdout)
        self.assertNotIn('SYSTEMCTL reboot',result.stdout)

    def test_bbr_fq_writes_only_managed_sysctl(self):
        self.shell("""need_root(){ :; }
modprobe(){ :; }
sysctl(){ if [[ $1 == -n ]]; then printf 'reno cubic bbr\\n'; fi; }
bbr""", input='yes\n')
        self.assertEqual((self.root/'bbr.conf').read_text(),
                         'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n')

    def test_download_requires_matching_release_digest(self):
        import tarfile
        version='1.14.3'
        payload=self.root/('sing-box-'+version+'-linux-amd64')
        payload.mkdir(); (payload/'sing-box').write_text('#!/bin/sh\nexit 0\n')
        archive=self.root/'release.tar.gz'
        with tarfile.open(archive,'w:gz') as tar: tar.add(payload,arcname=payload.name)
        asset=payload.name+'.tar.gz'
        manifest=self.root/'release.json'
        digest=hashlib.sha256(archive.read_bytes()).hexdigest()
        mocks="""uname(){ printf x86_64; }
sha256sum(){ shasum -a 256 "$@"; }
curl(){ local url= out=; while (($#)); do if [[ $1 == -o ]]; then out=$2; shift 2; else url=$1; shift; fi; done
if [[ $url == *.tar.gz ]]; then cp """+shlex.quote(str(archive))+""" "$out"; else cp """+shlex.quote(str(manifest))+""" "$out"; fi; }
"""
        data={'draft':False,'prerelease':False,'assets':[{'name':asset,'digest':'sha256:'+digest}]}
        manifest.write_text(json.dumps(data))
        target=self.root/'downloaded'
        self.shell(mocks+'download_binary '+version+' '+shlex.quote(str(target)))
        original=target.read_bytes()
        data['assets'][0]['digest']='sha256:'+'0'*64; manifest.write_text(json.dumps(data))
        self.assertNotEqual(self.shell(mocks+'download_binary '+version+' '+shlex.quote(str(target)),ok=False).returncode,0)
        self.assertEqual(target.read_bytes(),original)

    @unittest.skipUnless(MIHOMO, 'Set MIHOMO_BIN for Mihomo YAML validation')
    def test_mihomo_yaml_supported_schema(self):
        import yaml
        for mode in ['1','2','3']:
            self.exported(mode)
            parsed=yaml.safe_load((self.base/'mihomo-proxies.yaml').read_text())
            self.assertEqual(len(parsed['proxies']),1 if mode!='3' else 2)
            if mode!='1': self.assertEqual(parsed['tls']['custom-certifactes'],[self.cert.read_text()])
            subprocess.run([MIHOMO,'-t','-d',str(self.root/'mihomo-data'),'-f',str(self.base/'mihomo-proxies.yaml')],
                           check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

    @unittest.skipUnless(SB, 'Set SING_BOX_BIN to run real HY2 connectivity tests')
    def test_hy2_handshake_with_trust_and_reject_untrusted(self):
        cfg = self.configure('2')
        udp, mixed = port(socket.SOCK_DGRAM), port()
        cfg['inbounds'][0]['listen'] = '127.0.0.1'
        cfg['inbounds'][0]['listen_port'] = udp
        server_file = self.root/'server.json'
        server_file.write_text(json.dumps(cfg))
        exported = self.exported('2')['outbounds'][0]
        exported.update(server_port=udp)
        client = {'inbounds':[{'type':'mixed','listen':'127.0.0.1','listen_port':mixed}],
                  'outbounds':[exported], 'route':{'final':exported['tag']}}
        client_file = self.root/'client.json'
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200); self.end_headers(); self.wfile.write(b'SKYBYTE HY2 verified')
            def log_message(self, *_):
                pass
        webserver = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=webserver.serve_forever, daemon=True); thread.start()
        self.addCleanup(webserver.server_close)
        self.addCleanup(webserver.shutdown)
        url = 'http://127.0.0.1:'+str(webserver.server_port)
        with contextlib.ExitStack() as stack:
            def start(file):
                log = stack.enter_context(open(self.root/(file.stem+'.log'), 'w+'))
                proc = subprocess.Popen([SB,'run','-c',str(file)], stdout=log, stderr=log)
                def stop():
                    proc.terminate()
                    try: proc.wait(timeout=5)
                    except subprocess.TimeoutExpired: proc.kill(); proc.wait()
                stack.callback(stop)
                return proc, log
            server, _ = start(server_file)
            client_file.write_text(json.dumps(client))
            proc, log = start(client_file)
            try:
                deadline = time.monotonic()+10
                while time.monotonic()<deadline:
                    result = subprocess.run(['curl','--silent','--show-error','--max-time','2',
                                '--noproxy','', '--proxy','socks5h://127.0.0.1:'+str(mixed), url], capture_output=True)
                    if result.returncode == 0: break
                    time.sleep(.2)
                self.assertEqual(result.stdout, b'SKYBYTE HY2 verified', result.stderr.decode())
                self.assertIsNone(server.poll())
            finally:
                proc.terminate(); proc.wait(timeout=5)
            client['outbounds'][0]['tls'].pop('certificate')
            client['inbounds'][0]['listen_port']=mixed=port()
            client_file.write_text(json.dumps(client))
            proc, log = start(client_file)
            time.sleep(.5)
            result = subprocess.run(['curl','--silent','--show-error','--max-time','3','--noproxy','',
                                     '--proxy','socks5h://127.0.0.1:'+str(mixed),url],capture_output=True)
            self.assertNotEqual(result.returncode,0)
            log.flush(); log.seek(0)
            self.assertIn('certificate',log.read())
            if MIHOMO:
                import yaml
                config=yaml.safe_load((self.base/'mihomo-proxies.yaml').read_text())
                config['proxies'][0]['port']=udp
                proxy_port=port()
                config.update({'mixed-port':proxy_port,'mode':'rule','rules':['MATCH,SKYBYTE-HY2'],
                               'external-controller':'','ipv6':False})
                config_file=self.root/'mihomo.yaml'
                config_file.write_text(yaml.safe_dump(config))
                mh_log=stack.enter_context(open(self.root/'mihomo.log','w+'))
                mh=subprocess.Popen([MIHOMO,'-d',str(self.root/'mihomo-data'),'-f',str(config_file)],
                                    stdout=mh_log,stderr=mh_log)
                def stop_mh():
                    mh.terminate()
                    try: mh.wait(timeout=5)
                    except subprocess.TimeoutExpired: mh.kill(); mh.wait()
                stack.callback(stop_mh)
                deadline=time.monotonic()+10
                while time.monotonic()<deadline:
                    result=subprocess.run(['curl','--silent','--show-error','--max-time','2',
                                           '--noproxy','', '--proxy','socks5h://127.0.0.1:'+str(proxy_port),url],
                                          capture_output=True)
                    if result.returncode==0: break
                    time.sleep(.2)
                mh_log.flush(); mh_log.seek(0)
                self.assertEqual(result.stdout,b'SKYBYTE HY2 verified',mh_log.read())


if __name__ == '__main__':
    unittest.main(verbosity=2)
