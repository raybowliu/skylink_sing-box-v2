"""Owned WARP routing transactions. Node credentials are never edited."""
import base64
import configparser
import copy
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

OWNER='SKYBYTE WARP routing v1'
MEDIA=['netflix.com','netflix.net','nflxext.com','nflximg.com','nflximg.net','nflxso.net','nflxvideo.net',
       'disneyplus.com','disney-plus.net','dssott.com','bamgrid.com','youtube.com','youtu.be','googlevideo.com','ytimg.com','youtubei.googleapis.com',
       'primevideo.com','amazonvideo.com','aiv-cdn.net','aiv-delivery.net','tiktok.com','tiktokv.com','tiktokcdn.com','tiktokcdn-us.com','byteoversea.com','ibytedtos.com']
AI=['openai.com','chatgpt.com','oaistatic.com','oaiusercontent.com','anthropic.com','claude.ai','claude.com']
FIELDS=('route','outbounds')

def atomic(path,data):
    path=Path(path)
    if path.is_symlink():raise ValueError('Refusing WARP symlink')
    fd,tmp=tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd,'w') as f:json.dump(data,f,indent=2);f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def read_state(base):
    p=base/'warp-state.json'
    if p.is_symlink():raise ValueError('WARP state is a symlink')
    if not p.exists():return None
    d=json.loads(p.read_text())
    if d.get('owner')!=OWNER or d.get('schema')!=1 or d['mode'] not in ('direct','restricted','global'):raise ValueError('WARP state ownership/schema mismatch')
    if type(d['port']) is not int or not 1024<=d['port']<=65535 or type(d['udp']) is not bool:raise ValueError('Invalid WARP proxy settings')
    return d

def view(cfg):return {k:copy.deepcopy(cfg.get(k)) for k in FIELDS}

def put(cfg,routing):
    for k,v in routing.items():
        if v is None:cfg.pop(k,None)
        else:cfg[k]=copy.deepcopy(v)
    return cfg

def render(baseline,mode,port,udp,domains):
    result=copy.deepcopy(baseline)
    if mode=='direct':return result
    result['outbounds'].append({'type':'socks','tag':'skybyte-warp','server':'127.0.0.1','server_port':port,'version':'5',**({} if udp else {'network':'tcp'})})
    route=result['route'];prefix=[]
    if mode=='restricted':
        prefix=[{'action':'sniff','timeout':'500ms'}]
        if not udp:prefix.append({'domain_suffix':domains,'network':'udp','action':'reject'})
        prefix.append({'domain_suffix':domains,'action':'route','outbound':'skybyte-warp'})
    else:
        route['final']='skybyte-warp'
        if not udp:prefix=[{'network':'udp','action':'reject'}]
    route['rules']=prefix+route.get('rules',[])
    return result

def config_paths(base,conf):
    paths=[conf]
    if (base/'argo-state.json').exists():paths.append(base/'argo-server.json')
    if (base/'users.json').exists():
        users=json.loads((base/'users.json').read_text())
        if users.get('owner')!='SKYBYTE user quotas v1':raise ValueError('Invalid user owner')
        for u in users['users']:
            if not re.fullmatch('[0-9a-f]{16}',u['id']):raise ValueError('Invalid account ID')
            if not u.get('deleted'):paths.append(base/'users'/u['id']/'server.json')
    for p in paths:
        if p.is_symlink() or p.parent.is_symlink():raise ValueError('Config symlink')
    return paths

def domains_parse(text):
    domains=sorted(set(text.replace(',', ' ').split()))
    if not domains or len(domains)>200 or any(len(x)>253 or not re.fullmatch(r'(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}',x) for x in domains):raise ValueError('Invalid domain suffix list')
    return sorted(set(d.lower() for d in domains))

def switch(base,conf,binary,mode,port,udp,domains):
    if mode not in ('direct','restricted','global') or not 1024<=port<=65535:raise ValueError('Invalid WARP mode/port')
    prior=read_state(base)
    state=copy.deepcopy(prior) if prior else {'owner':OWNER,'schema':1,'configs':{}}
    originals={};planned={}
    for path in config_paths(base,conf):
        cfg=json.loads(path.read_text());originals[path]=cfg
        old=state['configs'].get(str(path))
        if old:
            if view(cfg)!=old['applied']:raise ValueError('Routing changed outside manager; refusing overwrite: '+str(path))
            baseline=old['baseline']
        else:
            if cfg.get('endpoints') or any(o['type']!='direct' for o in cfg['outbounds']) or cfg['route'].get('final')!='direct':raise ValueError('Unmanaged routing; refusing overwrite')
            baseline=view(cfg)
        routing=render(baseline,mode,port,udp,domains)
        candidate=put(copy.deepcopy(cfg),routing)
        fd,tmp=tempfile.mkstemp(dir=path.parent)
        try:
            with os.fdopen(fd,'w') as f:json.dump(candidate,f)
            r=subprocess.run([binary,'check','-c',tmp],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
            if r.returncode:raise ValueError('WARP candidate config failed validation')
        finally:os.unlink(tmp)
        planned[path]=candidate;state['configs'][str(path)]={'baseline':baseline,'applied':routing}
    state.update(mode=mode,port=port,udp=udp,domains=domains)
    try:
        for p,cfg in planned.items():atomic(p,cfg)
        atomic(base/'warp-state.json',state)
    except BaseException:
        for p,cfg in originals.items():atomic(p,cfg)
        if prior:atomic(base/'warp-state.json',prior)
        elif (base/'warp-state.json').exists():(base/'warp-state.json').unlink()
        raise

def restore_routing(base,conf,snapshot,binary):
    saved=snapshot/'warp-state.json'
    new=json.loads(saved.read_text()) if saved.exists() else None
    if saved.is_symlink():raise ValueError('Backup state symlink')
    prior=read_state(base)
    originals={}
    if new and (new.get('owner')!=OWNER or new.get('schema')!=1):raise ValueError('Invalid WARP backup')
    planned={}
    for path in config_paths(base,conf):
        if path==conf:source=snapshot/'config'/'config.json'
        elif path==base/'argo-server.json':source=snapshot/'argo-server.json'
        else:source=snapshot/'users'/path.parent.name/'server.json'
        current=json.loads(path.read_text());originals[path]=copy.deepcopy(current)
        if source.exists():
            if source.is_symlink():raise ValueError('Backup symlink')
            routing=view(json.loads(source.read_text()))
        else:
            old=prior['configs'].get(str(path)) if prior else None
            if old:
                if view(current)!=old['applied']:raise ValueError('New account routing changed; refusing overwrite')
                baseline=old['baseline']
            else:
                if any(o['type']!='direct' for o in current['outbounds']):raise ValueError('Unmanaged new account routing')
                baseline=view(current)
            routing=render(baseline,new['mode'],new['port'],new['udp'],new['domains']) if new else baseline
            if new:new['configs'][str(path)]={'baseline':baseline,'applied':routing}
        planned[path]=put(current,routing)
    for path,cfg in planned.items():
        fd,tmp=tempfile.mkstemp(dir=path.parent)
        try:
            with os.fdopen(fd,'w') as f:json.dump(cfg,f)
            r=subprocess.run([binary,'check','-c',tmp],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
            if r.returncode:raise ValueError('Restored WARP config failed validation')
        finally:os.unlink(tmp)
    try:
        for path,cfg in planned.items():atomic(path,cfg)
        if new:atomic(base/'warp-state.json',new)
        elif (base/'warp-state.json').exists():(base/'warp-state.json').unlink()
    except BaseException:
        for path,cfg in originals.items():atomic(path,cfg)
        if prior:atomic(base/'warp-state.json',prior)
        raise

def gateway(profile,port,target,binary):
    p=configparser.ConfigParser(interpolation=None,strict=True)
    try:
        with open(profile) as f:p.read_file(f)
    except configparser.Error:raise ValueError('Invalid WireGuard profile') from None
    if set(p.sections())!={'Interface','Peer'}:raise ValueError('Expected one Interface and Peer')
    if set(p['Interface'])-{'privatekey','address','dns','mtu','listenport'} or set(p['Peer'])-{'publickey','allowedips','endpoint','persistentkeepalive','reserved'}:raise ValueError('Unsupported profile directives; scripts are never executed')
    a=p['Interface'];b=p['Peer']
    for key in (a['privatekey'],b['publickey']):
        if len(base64.b64decode(key,validate=True))!=32:raise ValueError('Invalid WireGuard key')
    addresses=[str(ipaddress.ip_interface(x.strip())) for x in a['address'].split(',')]
    allowed=[str(ipaddress.ip_network(x.strip(),strict=False)) for x in b['allowedips'].split(',')]
    if {ipaddress.ip_interface(x).version for x in addresses}!={4,6} or set(allowed)!={'0.0.0.0/0','::/0'}:raise ValueError('A dual-stack WARP profile is required')
    endpoint=b['endpoint'].strip();match=re.fullmatch(r'(?:\[([^]]+)\]|([^:\s]+)):(\d+)',endpoint)
    if not match:raise ValueError('Invalid peer Endpoint')
    address=match[1] or match[2];peer_port=int(match[3])
    if not 1<=peer_port<=65535:raise ValueError('Invalid peer port')
    reserved=[int(x.strip()) for x in b.get('reserved','0,0,0').split(',')]
    if len(reserved)!=3 or any(not 0<=x<=255 for x in reserved):raise ValueError('Invalid reserved bytes')
    mtu=int(a.get('mtu','1280'));listen=int(a.get('listenport','0'))
    if not 1280<=mtu<=9000 or not 0<=listen<=65535:raise ValueError('Invalid MTU/listen port')
    cfg={'log':{'level':'warn'},'inbounds':[{'type':'socks','tag':'warp-local','listen':'127.0.0.1','listen_port':port}],
         'outbounds':[{'type':'direct','tag':'direct'}],
         'endpoints':[{'type':'wireguard','tag':'warp-wg','system':False,'address':addresses,'private_key':a['privatekey'],'listen_port':listen,'mtu':mtu,
                       'peers':[{'address':address,'port':peer_port,'public_key':b['publickey'],'allowed_ips':allowed,'reserved':reserved,'persistent_keepalive_interval':int(b.get('persistentkeepalive','25'))}]}],
         'dns':{'servers':[{'type':'https','tag':'warp-dns','server':'1.1.1.1','path':'/dns-query','detour':'warp-wg'},{'type':'local','tag':'bootstrap'}]},
         'route':{'final':'warp-wg','default_domain_resolver':'warp-dns'}}
    try:ipaddress.ip_address(address)
    except ValueError:cfg['endpoints'][0]['domain_resolver']='bootstrap'
    fd,tmp=tempfile.mkstemp(dir=target.parent)
    try:
        with os.fdopen(fd,'w') as f:json.dump(cfg,f)
        r=subprocess.run([binary,'check','-c',tmp],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
        if r.returncode:raise ValueError('Gateway config failed validation')
        atomic(target,cfg)
    finally:os.unlink(tmp)

if __name__=='__main__':
    import sys
    base,conf,binary,action,*args=sys.argv[1:];base=Path(base);conf=Path(conf)
    if action=='switch':switch(base,conf,binary,args[0],int(args[1]),args[2]=='true',domains_parse(args[3]))
    elif action=='restore':restore_routing(base,conf,Path(args[0]),binary)
    elif action=='gateway':gateway(args[0],int(args[1]),base/'warp-gateway.json',binary)
    elif action=='port':
        state=read_state(base)
        if not state:raise ValueError('WARP routing is not configured')
        print(state['port'])
    elif action=='status':
        state=read_state(base)
        print('WARP: '+(state['mode']+' | 127.0.0.1:'+str(state['port'])+' | UDP: '+str(state['udp']) if state else 'not configured'))
    elif action=='forget_argo':
        state=read_state(base)
        if state:
            state['configs'].pop(str(base/'argo-server.json'),None);atomic(base/'warp-state.json',state)
    elif action=='defaults':print(' '.join(MEDIA+AI))
    elif action=='guard':read_state(base)
    else:raise ValueError('Unknown WARP action')
