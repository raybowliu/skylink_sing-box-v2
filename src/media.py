"""Anonymous service-page probes; evidence is never a playback guarantee."""
import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.parse

PROBES={
 'Netflix':['https://www.netflix.com/title/81280792','https://www.netflix.com/title/70143836'],
 'Disney+':['https://www.disneyplus.com/'],
 'YouTube Premium':['https://www.youtube.com/premium'],
 'Amazon Prime Video':['https://www.primevideo.com/'],
 'TikTok':['https://www.tiktok.com/','https://www.tiktok.com/passport/web/store_region/']}
LABELS={
 'catalog':('片目页面有视频信息；播放未验证','Catalog video metadata; playback unverified'),
 'supported':('页面声明地区支持；播放未验证','Page reports supported location; playback unverified'),
 'offer':('页面提供订阅入口；订阅资格未验证','Subscription offer shown; eligibility unverified'),
 'restricted':('页面明确提示地区限制','Explicit location restriction on page'),
 'unknown':('页面可访问；解锁状态未知','Page reachable; unlock status unknown'),
 'verification':('访问被拒绝或需验证；解锁未知','Access denied/verification required; unlock unknown'),
 'network':('连接/DNS/TLS失败；解锁未知','Connection/DNS/TLS failed; unlock unknown'),
 'changed':('响应异常或页面变化；解锁未知','Unexpected response/page changed; unlock unknown')}

def fetch(url,path='4',port=None,post=False):
    # Ignore curlrc/proxy environment. No login cookies, authorization or node data.
    with tempfile.TemporaryDirectory() as tmp:
        body=Path(tmp)/'body'
        cmd=['curl','-q','--silent','--show-error','--location','--max-redirs','4',
             '--proto','=https','--proto-redir','=https','--connect-timeout','4','--max-time','12',
             '--max-filesize','8388608','--limit-rate','1M','--user-agent','Mozilla/5.0 SKYBYTE-Manager/2.4',
             '--header','Accept-Language: en-US,en;q=0.9','--output',str(body),
             '--write-out','%{http_code}\n%{url_effective}']
        if path=='warp':cmd+=['--noproxy','','--proxy','socks5h://127.0.0.1:'+str(port)]
        else:cmd+=['--noproxy','*','-'+path]
        if post:cmd+=['--request','POST','--data','']
        cmd.append(url)
        try:r=subprocess.run(cmd,capture_output=True,text=True,timeout=15)
        except (subprocess.TimeoutExpired,OSError):return {'error':True,'code':0,'body':'','url':url}
        lines=r.stdout.splitlines()
        code=int(lines[0]) if lines and lines[0].isdigit() else 0
        text=body.read_bytes()[:8388608].decode('utf-8','replace') if body.exists() else ''
        return {'error':r.returncode!=0,'code':code,'body':text,'url':lines[1] if len(lines)>1 else url}

def country(text,key):
    m=re.search(r'"'+re.escape(key)+r'"\s*:\s*"([A-Za-z]{2})"',text)
    return m[1].upper() if m else '-'

def classify(service,responses):
    region='-';main=responses[0];body=main['body'];low=body.lower()
    result={'service':service,'status':'unknown','region':region,'http_code':main['code']}
    if main['error']:result['status']='network';return result
    if main['code'] in (401,403,429,451) or any(x in low for x in ['verify you are human','cf-chl-','robot check','unusual traffic']):
        result['status']='verification';return result
    if main['code']!=200:result['status']='changed';return result
    if service=='Netflix':
        m=re.search(r'"requestCountry"\s*:\s*\{\s*"id"\s*:\s*"([A-Za-z]{2})"',body)
        result['region']=m[1].upper() if m else '-'
        if any(not r['error'] and r['code']==200 and re.search(r'<meta\b[^>]*(?:property|name)=["\']og:video',r['body'],re.I) for r in responses):result['status']='catalog'
    elif service=='Disney+':
        result['region']=country(body,'countryCode')
        if re.search(r'"inSupportedLocation"\s*:\s*false',body) or '/unavailable' in urllib.parse.urlsplit(main['url']).path:
            result['status']='restricted'
        elif re.search(r'"inSupportedLocation"\s*:\s*true',body):result['status']='supported'
    elif service=='YouTube Premium':
        result['region']=country(body,'countryCode')
        if 'premium is not available in your country' in low:result['status']='restricted'
        elif 'purchaseButtonOverride' in body or 'start trial' in low:result['status']='offer'
    elif service=='Amazon Prime Video':
        result['region']=country(body,'currentTerritory')
        if 'this video is currently unavailable to watch in your location' in low:result['status']='restricted'
    elif service=='TikTok':
        if len(responses)>1 and not responses[1]['error'] and responses[1]['code']==200:
            try:
                region=json.loads(responses[1]['body'])['data']['store_region']
                if re.fullmatch('[A-Za-z]{2}',region):result['region']=region.upper()
            except (ValueError,KeyError,TypeError):pass
        if 'not available in your region' in low:result['status']='restricted'
    return result

def probe(service,path,port):
    rows=[fetch(url,path,port,service=='TikTok' and n==1) for n,url in enumerate(PROBES[service])]
    return classify(service,rows)

def run(paths,report,port=None,language='zh_CN'):
    en=language=='en_US';results=[]
    for path in paths:
        if path=='warp' and not (port and 1024<=port<=65535):raise ValueError('Invalid WARP proxy port')
        label={'4':'VPS IPv4','6':'VPS IPv6','warp':'WARP proxy (remote DNS)'}[path]
        print('\n'+label+'\n'+'-'*64,flush=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            rows=list(pool.map(lambda s:probe(s,path,port),PROBES))
        for row in rows:
            row['path']=path;results.append(row)
            color='\033[1;32m' if row['status'] in ('catalog','offer','supported') else '\033[1;33m'
            if not __import__('sys').stdout.isatty() or os.environ.get('NO_COLOR'):color=''
            print(color+row['service']+' | '+LABELS[row['status']][int(en)]+' | '+('Region hint: ' if en else '页面地区提示：')+row['region']+' | HTTP '+str(row['http_code'])+('\033[0m' if color else ''))
    report=Path(report);report.mkdir(exist_ok=True,mode=0o700)
    if report.is_symlink():raise ValueError('Report directory is a symlink')
    fd,tmp=tempfile.mkstemp(prefix='media-',suffix='.json',dir=report)
    with os.fdopen(fd,'w') as f:
        json.dump({'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'playback_verified':False,'results':results},f,ensure_ascii=False,indent=2)
    print(('Report: ' if en else '报告：')+tmp)
    return results

if __name__=='__main__':
    import sys
    paths,report,port,lang=sys.argv[1:]
    run(paths.split(','),report,int(port) if port else None,lang)
