#!/usr/bin/env bash
# SKYBYTE Manager V2.1 community manager; review before running, Debian/Ubuntu only
set -Eeuo pipefail
umask 077
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
BASE=/etc/singbox-v2
CONF=/etc/sing-box/config.json
SYSTEMD_DIR=/etc/systemd/system
OS_RELEASE=/etc/os-release
MANAGER_BIN=/usr/local/sbin/singbox-v2
SYSCTL_FILE=/etc/sysctl.d/90-singbox-v2-bbr.conf
META=$BASE/state.json
REPORT=$BASE/reports
BACKUP=$BASE/backups
BIN=/usr/local/bin/sing-box
LOCK=/run/singbox-v2.lock

# Language preference is independent of sing-box configuration.
LANG_FILE="$BASE/language.conf"
LANGUAGE_CHOICE=""
load_language() {
  if [[ -f "$LANG_FILE" ]]; then
    local value
    value=$(cat "$LANG_FILE")
    case "$value" in zh_CN|en_US) LANGUAGE_CHOICE=$value;; esac
  fi
}
select_language() {
  local choice
  while :; do
    printf '\n========== Language / 语言 ==========\n 1. 简体中文\n 2. English\n=======================================\n'
    read -r -p '请选择语言 / Select language [1/2]: ' choice || return 1
    case "$choice" in 1) LANGUAGE_CHOICE=zh_CN;; 2) LANGUAGE_CHOICE=en_US;; *) continue;; esac
    printf '%s\n' "$LANGUAGE_CHOICE" > "$LANG_FILE"
    chmod 600 "$LANG_FILE"
    break
  done
}
say(){ printf '%s\n' "$(L "$1" "$2")"; }
L() { if [[ "$LANGUAGE_CHOICE" == en_US ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
 GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[1;36m'; RESET=$'\033[0m'
else GREEN=''; RED=''; YELLOW=''; CYAN=''; RESET=''; fi
YOUTUBE='https://www.youtube.com/@SKYBYTE9119'
ok(){ printf '%s✔ %s%s\n' "$GREEN" "$*" "$RESET"; }
warn(){ printf '%s⚠ %s%s\n' "$YELLOW" "$*" "$RESET"; }
err(){ printf '%s✖ %s%s\n' "$RED" "$*" "$RESET" >&2; }
need_root(){ [[ $EUID == 0 ]] || { err "$(L '需要 root 权限' 'Root privileges required')"; exit 1; }; }
confirm(){ local answer; read -r -p "$1 $(L '[输入 YES 确认]' '[Type YES to confirm]'): " answer || return 1; [[ $answer =~ ^[[:space:]]*[Yy][Ee][Ss][[:space:]]*$ ]]; }
notice(){ if [[ "$LANGUAGE_CHOICE" == en_US ]]; then cat <<'EOF_EN'
[LEGAL & PRIVACY NOTICE] Use only for lawful networking education and server administration. You must comply with applicable law and service terms. Updating software or changing firewall/network settings may interrupt service or cause data loss; make backups first. Provided as-is to the extent permitted by law. Third-party components retain their licenses.
Installation and updates can contact github.com, api.github.com and GitHub release CDNs; these services can see your source IP. Installation queries api.ipify.org for your public IPv4. The optional IP report queries ipinfo.io, which may retain your IP and request metadata; reports are stored locally in /etc/singbox-v2/reports and deleted after 30 days. No developer telemetry and no intentional upload of node credentials. Auto-update is opt-in. HY2 requires TLS. A no-domain self-signed certificate mode is available, but clients must securely trust the certificate.
EOF_EN
else cat <<'EOF'
【法律与隐私披露】此工具仅供合法网络技术学习和服务器管理；使用者应遵守适用法律和服务条款。更改防火墙、网络参数及更新软件可能导致中断或损失，请提前备份。软件按现状提供，不排除依法不得排除的责任。第三方软件遵循其许可证。
安装/更新可能连接：github.com、api.github.com、GitHub 发布文件 CDN，访问服务会暴露请求来源 IP。安装时 api.ipify.org 用于识别出口 IP。可选 IP 检测使用 ipinfo.io，报告保存在本地 /etc/singbox-v2/reports，默认保留 30 天；第三方可能记录来源 IP、查询目标和请求时间。无开发者遥测或上传节点密钥；请勿公开包含凭据的配置和导出文件。自动更新默认关闭。HY2 必须有 TLS 证书，无域名用户可生成自签名证书，客户端必须正确配置信任，不能默认跳过证书验证。
EOF
fi
}
require_cmd(){ command -v "$1" >/dev/null || { err "$(L "缺少命令 $1" "Missing command: $1")"; return 1; }; }
valid_port(){ [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
state(){ python3 - "$META" "$1" <<'PY'
import json,sys
with open(sys.argv[1]) as f: d=json.load(f)
print(d.get(sys.argv[2],''))
PY
}
protocol_mode(){
 python3 - "$CONF" <<'PY'
import json,sys
p={i['type'] for i in json.load(open(sys.argv[1]))['inbounds']}
if {'vless','hysteria2'} <= p: print('3')
elif 'vless' in p: print('1')
elif 'hysteria2' in p: print('2')
else: raise ValueError('No supported installed protocols')
PY
}
check_owned(){ [[ -f $META && -f $CONF ]] || { err "$(L '未发现由本脚本部署的节点' 'No deployment managed by this script was found')"; return 1; }; }
backup(){
 check_owned || return 1
 local path
 path="$BACKUP/$(date +%Y%m%d-%H%M%S)-$RANDOM"
 mkdir -m 700 "$path" || return 1; cp -a "$(dirname "$CONF")" "$path/config" || return 1
 cp "$META" "$path/state.json" || return 1
 cp "$BIN" "$path/sing-box.bin" || return 1
 if [[ -f "$BASE/hop.nft" ]]; then cp "$BASE/hop.nft" "$path/hop.nft" || return 1; fi
 python3 - "$path" "$CONF" <<'PY' || return 1
import json,sys,shutil,pathlib
root=pathlib.Path(sys.argv[1]); cfg=json.load(open(sys.argv[2])); meta=json.load(open(root/'state.json'))
for i in cfg['inbounds']:
 if i['type']=='hysteria2':
  for field,name in [('certificate_path','hy2-backup.crt'),('key_path','hy2-backup.key')]:
   shutil.copyfile(i['tls'][field],root/'config'/name)
   i['tls'][field]=str(pathlib.Path(sys.argv[2]).parent/name)
  meta['cert_path']=i['tls']['certificate_path']
(root/'config'/'config.json').write_text(json.dumps(cfg,indent=2))
(root/'state.json').write_text(json.dumps(meta,indent=2))
PY
 chmod -R go-rwx "$path" || return 1; printf '%s\n' "$path"
}
validate_certificate(){
 local cert=$1 key=$2 name=$3 certpub keypub
 LC_ALL=C openssl x509 -in "$cert" -noout -checkend 0 >/dev/null || { err "$(L '证书无效或已过期' 'Certificate invalid or expired')"; return 1; }
 if [[ $name =~ ^[0-9.]+$ ]]; then
  LC_ALL=C openssl x509 -in "$cert" -noout -checkip "$name" | grep -q "does match" || { err "$(L '证书 IP 不匹配' 'Certificate IP does not match')"; return 1; }
 else
  LC_ALL=C openssl x509 -in "$cert" -noout -checkhost "$name" | grep -q "does match" || { err "$(L '证书域名不匹配' 'Certificate hostname does not match')"; return 1; }
 fi
 certpub=$(openssl x509 -in "$cert" -pubkey -noout) || return 1
 keypub=$(openssl pkey -in "$key" -pubout -passin pass: 2>/dev/null) || return 1
 [[ $certpub == "$keypub" ]] || { err "$(L '证书和私钥不匹配' 'Certificate and private key do not match')"; return 1; }
}
# Download only a verified release binary; never execute a package installer on updates.
download_binary(){
 local version=$1 target=$2 arch tmp asset sum
 [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
 case "$(uname -m)" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) err "$(L '不支持此架构' 'Unsupported architecture')"; return 1;; esac
 tmp=$(mktemp -d) || return 1
 asset="sing-box-$version-linux-$arch.tar.gz"
 if ! curl -fsSL --retry 2 --max-time 180 "https://github.com/SagerNet/sing-box/releases/download/v$version/$asset" -o "$tmp/$asset" ||
    ! curl -fsSL --retry 2 --max-time 30 "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v$version" -o "$tmp/release.json"; then rm -rf "$tmp"; return 1; fi
 sum=$(python3 - "$tmp/release.json" "$asset" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); assert not r['draft'] and not r['prerelease']
a=next(a for a in r['assets'] if a['name']==sys.argv[2])
digest=a.get('digest') or ''; assert digest.startswith('sha256:')
print(digest.split(':',1)[1])
PY
 ) || { rm -rf "$tmp"; return 1; }
 if [[ ! $sum =~ ^[a-fA-F0-9]{64}$ ]] || ! printf '%s  %s\n' "$sum" "$tmp/$asset" | sha256sum -c - >/dev/null; then rm -rf "$tmp"; return 1; fi
 tar -xzf "$tmp/$asset" -C "$tmp" || { rm -rf "$tmp"; return 1; }
 command install -m 755 "$tmp/sing-box-$version-linux-$arch/sing-box" "$target"
 local rc=$?; rm -rf "$tmp"; return "$rc"
}
setup_service(){ cat >"$SYSTEMD_DIR/sing-box.service" <<EOF
[Unit]
Description=sing-box (managed by singbox-v2)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
 systemctl daemon-reload; }
# Installation requires a clean deployment; configuration generation is separately testable.
write_config(){
 python3 - "$@" <<'PY'
import json,sys
conf,meta,domain,cert,key,sni,uuid,priv,pub,sid,password,ip,mode,cert_mode=sys.argv[1:]
d={'log':{'level':'info','timestamp':True},'inbounds':[{'type':'vless','tag':'reality','listen':'0.0.0.0','listen_port':443,'users':[{'name':'user1','uuid':uuid,'flow':'xtls-rprx-vision'}],'tls':{'enabled':True,'server_name':sni,'reality':{'enabled':True,'handshake':{'server':sni,'server_port':443},'private_key':priv,'short_id':[sid]}}},{'type':'hysteria2','tag':'hy2','listen':'0.0.0.0','listen_port':443,'users':[{'name':'user1','password':password}],'tls':{'enabled':True,'server_name':domain,'certificate_path':cert,'key_path':key}}],'outbounds':[{'type':'direct','tag':'direct'}],'route':{'final':'direct'}}
if mode=='1': d['inbounds']=d['inbounds'][:1]
elif mode=='2': d['inbounds']=d['inbounds'][1:]
with open(conf,'w') as f:json.dump(d,f,indent=2)
with open(meta,'w') as f:json.dump({'mode':mode,'cert_mode':cert_mode,'cert_path':cert,'ip':ip,'domain':domain,'sni':sni,'uuid':uuid,'public_key':pub,'sid':sid,'hy2_password':password,'hop':False,'hop_start':20000,'hop_end':30000},f,indent=2)
PY
}
install_protocol(){
 need_root
 [[ -r $OS_RELEASE ]] || return 1
 # shellcheck source=/dev/null
 . "$OS_RELEASE"
 case ${ID:-} in ubuntu|debian) ;; *) err "$(L '仅支持 Ubuntu/Debian' 'Ubuntu/Debian required')"; return 1;; esac
 local mode="${1:-}" cert_mode="" 
 if [[ -z "$mode" ]]; then printf '\033[1;32m%s\033[0m\n' "$(L '1 Reality 单协议 | 2 HY2 单协议 | 3 双协议 | 0 返回' '1 Reality only | 2 HY2 only | 3 Dual | 0 Back')"
 read -r -p '> ' mode || return; fi
 [[ "$mode" == 0 ]] && return 0
 [[ "$mode" =~ ^[123]$ ]] || { err "Invalid selection"; return 1; }
 notice; confirm "$(L '同意声明并安装所选协议？' 'Accept notice and install selected protocol(s)?')" || return 0
 if [[ -e $CONF || -e $META || -e $BIN ]] || command -v sing-box >/dev/null; then err "$(L '发现已有配置，拒绝覆盖' 'Existing configuration or binary found; refusing to overwrite')"; return 1; fi
 if systemctl list-unit-files sing-box.service --no-legend 2>/dev/null | grep -q sing-box; then err "$(L '已有 sing-box 服务，拒绝覆盖' 'Existing sing-box service found; refusing to overwrite')"; return 1; fi
 require_cmd ss || { apt-get update && apt-get install -y iproute2 || return 1; }
 if [[ $mode != 2 ]] && ss -H -ltn '( sport = :443 )' | grep -q .; then err "$(L 'TCP 443 已被占用' 'TCP 443 is occupied')"; return 1; fi
 if [[ $mode != 1 ]] && ss -H -lun '( sport = :443 )' | grep -q .; then err "$(L 'UDP 443 已被占用' 'UDP 443 is occupied')"; return 1; fi
 local domain="" cert="" key="" sni=""
 if [[ $mode != 1 ]]; then
  say 'HY2证书: 1 无域名(自动自签名)  2 已有证书' 'HY2 certificate: 1 No domain (self-signed)  2 Existing certificate'
  read -r -p '> ' cert_mode
  case "$cert_mode" in
   1) say '需要客户端安全地导入证书并启用验证。' 'Client must securely import and verify the certificate.';;
   2) read -r -p "$(L '证书域名：' 'Certificate domain: ')" domain
      [[ $domain =~ ^[a-zA-Z0-9.-]+$ && $domain == *.* ]] || { err "$(L '域名无效' 'Invalid domain')"; return 1; }
      read -r -p "$(L 'TLS 完整证书路径：' 'TLS fullchain path: ')" cert
      read -r -p "$(L 'TLS 私钥路径：' 'TLS key path: ')" key
      [[ -f $cert && -f $key ]] || { err "$(L '证书或私钥不存在' 'Certificate/key missing')"; return 1; };;
   *) err "$(L '无效证书选项' 'Invalid certificate option')"; return 1;;
  esac
 fi
 if [[ $mode != 2 ]]; then
  read -r -p "$(L 'Reality 握手域名 [addons.mozilla.org]：' 'Reality handshake [addons.mozilla.org]: ')" sni
  sni=${sni:-addons.mozilla.org}
  [[ $sni =~ ^[a-zA-Z0-9.-]+$ ]] || { err "$(L '无效 SNI' 'Invalid SNI')"; return 1; }
 fi
 say '安装依赖...' 'Installing dependencies...'; apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl ca-certificates python3 iproute2 util-linux nftables || return 1
 require_cmd getent; getent ahostsv4 github.com >/dev/null || { err "$(L 'GitHub DNS 解析失败，请先修复 DNS' 'GitHub DNS lookup failed; fix DNS first')"; return 1; }
 mkdir -p "$(dirname "$BIN")"
 if [[ $cert_mode == 2 ]]; then validate_certificate "$cert" "$key" "$domain" || return 1; fi
 download_binary "$(latest)" "$BIN" || { err "$(L '官方安装失败' 'Release installation failed')"; return 1; }
 chmod 755 "$BIN"
 local uuid pair priv="" pub="" sid="" passwd ip
 uuid=$(cat /proc/sys/kernel/random/uuid)
 if [[ $mode != 2 ]]; then pair=$("$BIN" generate reality-keypair)
 priv=$(sed -n 's/^PrivateKey: *//p' <<<"$pair"); pub=$(sed -n 's/^PublicKey: *//p' <<<"$pair")
 [[ -n $priv && -n $pub ]] || { err "$(L 'Reality 密钥生成失败' 'Reality key generation failed')"; return 1; }; fi
 sid=$(openssl rand -hex 4); passwd=$(openssl rand -hex 16)
 ip=$(curl -4fsS --max-time 15 https://api.ipify.org) || { err "$(L '公网 IPv4 查询失败' 'Public IPv4 lookup failed')"; return 1; }
 python3 - "$ip" <<'PY' || return 1
import ipaddress,sys
assert ipaddress.ip_address(sys.argv[1]).is_global
PY
 mkdir -p "$(dirname "$CONF")"
 if [[ $cert_mode == 1 ]]; then
  [[ ! -e $(dirname "$CONF")/hy2-selfsigned.crt && ! -e $(dirname "$CONF")/hy2-selfsigned.key ]] || { err "TLS files already exist"; return 1; }
  domain="$ip"; cert="$(dirname "$CONF")/hy2-selfsigned.crt"; key="$(dirname "$CONF")/hy2-selfsigned.key"
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 -subj "/CN=$ip" -addext "subjectAltName=IP:$ip" -keyout "$key" -out "$cert" >/dev/null 2>&1 || return 1
  chmod 600 "$key"; chmod 644 "$cert"
 fi
 if [[ $mode != 1 ]]; then validate_certificate "$cert" "$key" "$domain" || return 1; fi
 write_config "$CONF" "$META" "$domain" "$cert" "$key" "$sni" "$uuid" "$priv" "$pub" "$sid" "$passwd" "$ip" "$mode" "$cert_mode"
 chmod 600 "$CONF" "$META"
 "$BIN" check -c "$CONF" || { err "$(L '配置检查失败' 'Configuration check failed')"; return 1; }
 # Binary installation does not create a package unit; create our managed service.
 setup_service
 if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then if [[ $mode != 2 ]]; then ufw allow 443/tcp; fi; if [[ $mode != 1 ]]; then ufw allow 443/udp; fi; fi
 systemctl daemon-reload; systemctl enable --now sing-box; systemctl restart sing-box
 sleep 2; systemctl is-active --quiet sing-box || { err "$(L '服务启动失败，请查看 journalctl -u sing-box' 'Service failed; inspect journalctl -u sing-box')"; return 1; }
 if [[ $cert_mode == 1 ]]; then echo "$(L '自签名证书：' 'Self-signed certificate: ')$cert"; openssl x509 -in "$cert" -noout -fingerprint -sha256; say '务必将证书安全导入客户端并验证，链接本身不足以建立信任。' 'Securely import and verify certificate on client; URL alone cannot establish trust.'; fi
 ok "$(L '部署完成；请检查云防火墙' 'Installed; check provider firewall')"; exports
}
exports(){
 check_owned || return
 python3 - "$META" "$BASE" "$CONF" <<'PY'
import base64,json,os,sys,urllib.parse,subprocess
s=json.load(open(sys.argv[1]));base=sys.argv[2];ip=s['ip']
config=json.load(open(sys.argv[3])); inbound={i['type']:i for i in config['inbounds'] if i['type'] in ('vless','hysteria2')}
if not inbound: raise ValueError('No supported installed protocols')
mode='3' if len(inbound)==2 else '1' if 'vless' in inbound else '2'
if 'vless' in inbound:
 i=inbound['vless'];s.update(uuid=i['users'][0]['uuid'],sni=i['tls']['server_name'],sid=i['tls']['reality']['short_id'][0])
if 'hysteria2' in inbound:
 i=inbound['hysteria2'];s.update(hy2_password=i['users'][0]['password'],domain=i['tls']['server_name'],cert_path=i['tls']['certificate_path'])
d=s.get('domain','');sni=s.get('sni','')
vp=inbound.get('vless',{}).get('listen_port',443); hp=inbound.get('hysteria2',{}).get('listen_port',443)
cert_pem=None; fingerprint=None
self_signed=s.get('cert_mode')=='1'
if mode!='1':
 identity=subprocess.check_output(['openssl','x509','-in',s['cert_path'],'-noout','-issuer','-subject','-nameopt','RFC2253'],text=True).splitlines()
 names=[line.split('=',1)[1].strip() for line in identity]
 self_signed=self_signed or names[0]==names[1]
if mode!='1' and self_signed:
 import hashlib,ssl
 cert_pem=open(s['cert_path']).read()
 fingerprint=hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert_pem)).hexdigest()
v='vless://{}@{}:{}?{}#SKYBYTE-Reality'.format(s.get('uuid',''),ip,vp,urllib.parse.urlencode({'encryption':'none','flow':'xtls-rprx-vision','security':'reality','sni':sni,'fp':'chrome','pbk':s.get('public_key',''),'sid':s.get('sid',''),'type':'tcp'}))
h='hysteria2://{}@{}:{}?{}#SKYBYTE-HY2'.format(urllib.parse.quote(s.get('hy2_password',''),safe=''),ip,hp,urllib.parse.urlencode(dict({'sni':d,'insecure':'0'}, **({'pinSHA256':fingerprint} if fingerprint else {}))))
links=[v] if mode=='1' else [h] if mode=='2' else [v,h]
def write(name,content):
 path=os.path.join(base,name)
 with open(path,'w') as f:f.write(content)
 os.chmod(path,0o600)
 return path
write('nodes.txt','\n'.join(links)+'\n'); write('subscription-base64.txt',base64.b64encode(('\n'.join(links)+'\n').encode()).decode()+'\n')
out=[];proxy=[]
if mode!='2':
 out.append({'type':'vless','tag':'SKYBYTE-Reality','server':ip,'server_port':vp,'uuid':s['uuid'],'flow':'xtls-rprx-vision','tls':{'enabled':True,'server_name':sni,'utls':{'enabled':True,'fingerprint':'chrome'},'reality':{'enabled':True,'public_key':s['public_key'],'short_id':s['sid']}}})
 proxy.append({'name':'SKYBYTE-Reality','type':'vless','server':ip,'port':vp,'uuid':s['uuid'],'network':'tcp','tls':True,'servername':sni,'client-fingerprint':'chrome','flow':'xtls-rprx-vision','reality-opts':{'public-key':s['public_key'],'short-id':s['sid']}})
if mode!='1':
 tls={'enabled':True,'server_name':d}
 if self_signed:tls['certificate']=cert_pem.splitlines()
 ho={'type':'hysteria2','tag':'SKYBYTE-HY2','server':ip,'server_port':hp,'password':s['hy2_password'],'tls':tls}
 if s.get('hop'):ho.update({'server_ports':[f"{s['hop_start']}:{s['hop_end']}"],'hop_interval':'30s'})
 out.append(ho)
 mp={'name':'SKYBYTE-HY2','type':'hysteria2','server':ip,'port':hp,'password':s['hy2_password'],'sni':d,'skip-cert-verify':False}
 if s.get('hop'):mp['ports']=f"{s['hop_start']}-{s['hop_end']}";mp['hop-interval']=30
 if self_signed:mp['fingerprint']=fingerprint
 proxy.append(mp)
write('outbounds.json',json.dumps({'outbounds':out},ensure_ascii=False,indent=2)+'\n')
if cert_pem: write('hy2-client-ca.pem',cert_pem)
def scalar(x):return json.dumps(x,ensure_ascii=False) if isinstance(x,str) else ('true' if x is True else 'false' if x is False else str(x))
def yaml_dump(v,level=0):
 lines=[]
 if isinstance(v,dict):
  for k,val in v.items():
   key=' '*level+str(k)+':'
   if isinstance(val,(list,dict)):lines.append(key);lines.extend(yaml_dump(val,level+2))
   else:lines.append(key+' '+scalar(val))
 elif isinstance(v,list):
  for val in v:
   if isinstance(val,(list,dict)):lines.append(' '*level+'-');lines.extend(yaml_dump(val,level+2))
   else:lines.append(' '*level+'- '+scalar(val))
 return lines
yaml_config={'proxies':proxy}
if cert_pem: yaml_config['tls']={'custom-certifactes':[cert_pem]}
write('mihomo-proxies.yaml','# SKYBYTE: merge proxies AND tls trust settings with your Mihomo config.\n'+'\n'.join(yaml_dump(yaml_config))+'\n')
notes=[]
if mode!='1' and self_signed:notes.append('HY2 self-signed TLS: JSON/YAML include the trusted public certificate. For Shadowrocket/v2rayN securely import hy2-client-ca.pem as a trusted CA and verify its SHA256 fingerprint: ' + str(fingerprint) + ' . URI pinning support varies; keep verification enabled. Never import the private key.')
if s.get('hop'):notes.append('Port hopping requires client-specific support, matching server NAT and cloud firewall; basic URI does NOT encode it.')
write('subscription-notes.txt','\n'.join(notes or ['Check client support before importing.'])+'\n')
print('SKYBYTE local files / 本地文件:')
for name in ['nodes.txt','subscription-base64.txt','outbounds.json','mihomo-proxies.yaml','subscription-notes.txt']:print('  '+os.path.join(base,name))
print('Sensitive node links / 节点链接（请勿公开）:')
for link in links:print(('\033[1;31m'+link+'\033[0m') if sys.stdout.isatty() and not os.getenv('NO_COLOR') else link)
for note in notes:print(('\033[1;33m' if sys.stdout.isatty() and not os.getenv('NO_COLOR') else '')+'WARNING: '+note+('\033[0m' if sys.stdout.isatty() and not os.getenv('NO_COLOR') else ''))
PY
}

bbr(){ need_root; confirm "$(L '更改系统 TCP 拥塞控制为 BBR、默认队列为 FQ？' 'Change system TCP congestion control to BBR and default qdisc to FQ?')" || return 0; modprobe tcp_bbr 2>/dev/null || :; if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then err "$(L '内核不支持 BBR' 'Kernel does not support BBR')"; return 1; fi
 printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >"$SYSCTL_FILE"
 sysctl -p "$SYSCTL_FILE"; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc; }
hop_disable(){ nft delete table ip singbox_v2_hop 2>/dev/null || :; if [[ -f $META ]]; then python3 - "$META" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['hop']=False
with open(p,'w') as f:json.dump(d,f,indent=2)
PY
 fi; say '已关闭本工具管理的端口跳跃规则' 'Disabled managed port-hopping rules'; }
hop(){ check_owned || return; [[ "$(protocol_mode)" != 1 ]] || { err "$(L '未安装 HY2' 'HY2 not installed')"; return 1; }; require_cmd nft || return 1; say '端口跳跃仅支持 IPv4，规则通过专属 systemd 服务持久化。请同步修改云防火墙。' 'Port hopping is IPv4 only and uses a dedicated systemd service. Also configure your provider firewall.'; say '1 开启  2 关闭' '1 Enable  2 Disable'; read -r -p '> ' choice
 if [[ $choice == 2 ]]; then confirm "$(L '关闭端口跳跃？' 'Disable HY2 port hopping?')" && { systemctl disable --now singbox-v2-hop.service 2>/dev/null || :; hop_disable; }; return; fi
 [[ $choice == 1 ]] || return 0
 read -r -p "$(L '起始端口 [20000]: ' 'Start port [20000]: ')" start; start=${start:-20000}; read -r -p "$(L '结束端口 [30000]: ' 'End port [30000]: ')" end; end=${end:-30000}
 if ! valid_port "$start" || ! valid_port "$end" || ! (( 10#$start<=10#$end && 10#$start>=1024 && 10#$end-10#$start<=10000 )); then err "$(L '端口范围非法（最多10001个）' 'Invalid range (maximum 10001 ports)')"; return 1; fi
 start=$((10#$start)); end=$((10#$end))
 confirm "$(L "启用 UDP $start-$end 转发到 443？" "Forward UDP $start-$end to 443?")" || return 0
 nft list table ip singbox_v2_hop >/dev/null 2>&1 && { err "$(L '已存在端口跳跃规则，请先关闭' 'Hopping table exists; disable it first')"; return 1; }
 cat >"$SYSTEMD_DIR/singbox-v2-hop.service" <<EOF
[Unit]
Description=singbox V2 HY2 IPv4 port hopping
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $BASE/hop.nft
ExecStop=/usr/sbin/nft delete table ip singbox_v2_hop
[Install]
WantedBy=multi-user.target
EOF
 cat >"$BASE/hop.nft" <<EOF
add table ip singbox_v2_hop
add chain ip singbox_v2_hop prerouting { type nat hook prerouting priority dstnat; policy accept; }
add rule ip singbox_v2_hop prerouting udp dport $start-$end redirect to :443
EOF
 systemctl daemon-reload; systemctl enable --now singbox-v2-hop.service || { err "$(L '开启失败' 'Enable failed')"; return 1; }
 if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then ufw allow "$start:$end/udp"; warn "$(L '关闭跳跃后请按需要手动删除 UFW 范围规则' 'After disabling hopping, remove UFW range rules manually if needed')"; fi
 python3 - "$META" "$start" "$end" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d.update(hop=True,hop_start=int(sys.argv[2]),hop_end=int(sys.argv[3]))
with open(p,'w') as f:json.dump(d,f,indent=2)
PY
 say '已启用。请在客户端配置 server_ports 和 hop_interval=30s' 'Enabled. Configure server_ports and hop_interval=30s on clients'; }
latest(){ curl -4fsSL --max-time 25 https://api.github.com/repos/SagerNet/sing-box/releases/latest | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d.get("prerelease") and not d.get("draft"); print(d["tag_name"].lstrip("v"))'; }
update(){
 check_owned || return 1
 local new current
 current=$("$BIN" version | awk 'NR==1{print $3}'); new=$(latest) || return 1
 printf '%s -> %s\n' "$current" "$new"
 [[ $current != "$new" ]] || return 0
 confirm "$(L '更新会短暂中断连接，继续？' 'Update briefly interrupts connections. Continue?')" || return 0
 apply_update "$new"
}
apply_update(){
 local new=$1 snap candidate
 candidate=$(mktemp "$BASE/sing-box.candidate.XXXXXX") || return 1
 snap=$(backup) || { rm -f "$candidate"; return 1; }
 download_binary "$new" "$candidate" || { rm -f "$candidate"; return 1; }
 "$candidate" check -c "$CONF" || { rm -f "$candidate"; return 1; }
 command install -m 755 "$candidate" "$BIN" || return 1; rm -f "$candidate"
 if ! systemctl restart sing-box || ! service_healthy; then
  command install -m 755 "$snap/sing-box.bin" "$BIN"; systemctl restart sing-box || :
  err "$(L '更新失败，已恢复原二进制' 'Update failed; original binary restored')"; return 1
 fi
 ok "$(L '更新完成，请检查客户端连接' 'Updated; verify client connectivity')"
}
service_healthy(){ sleep 2; systemctl is-active --quiet sing-box; }
update_auto(){
 check_owned || return 1
 local current new
 current=$("$BIN" version | awk 'NR==1{print $3}'); new=$(latest) || return 1
 [[ $current == "$new" ]] || apply_update "$new"
}
configure_auto(){ need_root; say '1 启用每周自动更新  2 关闭' '1 Enable weekly automatic updates  2 Disable'; read -r -p '> ' x
 if [[ $x == 1 ]]; then
 check_owned || return 1
 warn "$(L '自动更新会短暂中断服务；请保留备份' 'Automatic updates briefly interrupt service; retain backups')"
 cat >"$SYSTEMD_DIR/singbox-v2-update.service" <<EOF
[Unit]
Description=sing-box v2 weekly update
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash $MANAGER_BIN --auto-update
EOF
 cat >"$SYSTEMD_DIR/singbox-v2-update.timer" <<'EOF'
[Unit]
Description=sing-box v2 weekly update timer
[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=15min
Persistent=true
[Install]
WantedBy=timers.target
EOF
 command install -m 700 "$SCRIPT_PATH" "$MANAGER_BIN"; systemctl daemon-reload; systemctl enable --now singbox-v2-update.timer
 elif [[ $x == 2 ]]; then systemctl disable --now singbox-v2-update.timer 2>/dev/null || :; fi; }
ipcheck(){ notice; confirm "$(L '访问 ipinfo.io 检查 IP 并保存本地报告？' 'Query ipinfo.io and save the IP report locally?')" || return 0; local stamp path; stamp=$(date +%Y%m%d-%H%M%S); path="$REPORT/ip-$stamp.json"; curl -4fsSL --max-time 20 https://ipinfo.io/json >"$path" || { rm -f "$path"; err "$(L 'IP 检测失败' 'IP lookup failed')"; return 1; }; chmod 600 "$path"; python3 -m json.tool "$path"; find "$REPORT" -type f -mtime +30 -delete; say "报告：$path；不是风险或解锁报告" "Report: $path; not a reputation/unblocking test"; }
netcheck(){ local stamp path; stamp=$(date +%Y%m%d-%H%M%S); path="$REPORT/net-$stamp.txt"; { echo "date=$(date -Is)"; echo 'route:'; ip route get 1.1.1.1; echo 'DNS:'; getent ahostsv4 github.com | sed -n '1,3p'; echo 'HTTP:'; curl -4 -o /dev/null -sS --max-time 15 -w 'github_https_code=%{http_code} connect=%{time_connect}s total=%{time_total}s\n' https://github.com || :; echo 'TCP listeners:'; ss -lnt '( sport = :443 )'; echo 'UDP listeners:'; ss -lnu '( sport = :443 )'; } | tee "$path"; chmod 600 "$path"; find "$REPORT" -type f -mtime +30 -delete; say '仅为基础连通性，不测三网回程、UDP 丢包或吞吐量' 'Basic connectivity only; no route-back, UDP loss or throughput testing'; }
firewall_audit(){
 if command -v ufw >/dev/null; then
  local rules; rules=$(LC_ALL=C ufw status); printf '%s\n' "$rules"
  if [[ -f $META && $(protocol_mode) != 1 && $rules == *'Status: active'* ]]; then
   grep -Eq '443/udp[[:space:]]+ALLOW' <<<"$rules" || warn "$(L '未检测到 UDP 443 放行，请检查规则' 'UDP 443 allow rule not detected; inspect rules')"
   if [[ $(state hop) == True ]]; then
    grep -F "$(state hop_start):$(state hop_end)/udp" <<<"$rules" | grep -q ALLOW || warn "$(L '未检测到跳跃 UDP 范围放行' 'Hopping UDP range allow rule not detected')"
   fi
  fi
 else warn "$(L '未安装 UFW；请检查 nftables 和云防火墙' 'UFW unavailable; inspect nftables and provider firewall')"; fi
 warn "$(L '云防火墙须在服务商控制台检查' 'Check provider firewall in the hosting console')"
}
status(){ systemctl --no-pager status sing-box 2>&1 | head -25 || :; echo 'TCP:'; ss -ltn '( sport = :443 )'; echo 'UDP:'; ss -lun '( sport = :443 )'; echo 'UFW:'; firewall_audit; echo 'Hop:'; nft list table ip singbox_v2_hop 2>/dev/null || :; }
restore(){
 check_owned || return 1
 local path snap
 find "$BACKUP" -mindepth 1 -maxdepth 1 -type d | sort -r
 read -r -p "$(L '完整备份路径：' 'Full backup directory path: ')" path || return
 path=$(realpath "$path") || return 1
 [[ $path == "$(realpath "$BACKUP")/"* && -f $path/config/config.json && -f $path/sing-box.bin && -f $path/state.json ]] || { err "$(L '备份路径错误' 'Invalid backup path')"; return 1; }
 confirm "$(L '恢复配置并重启？' 'Restore configuration and restart?')" || return 0
 snap=$(backup) || return 1
 cp -a "$path/config/." "$(dirname "$CONF")" || return 1; cp "$path/state.json" "$META" || return 1
 command install -m 755 "$path/sing-box.bin" "$BIN" || return 1
 if ! "$BIN" check -c "$CONF" || ! systemctl restart sing-box || ! service_healthy; then
  cp -a "$snap/config/." "$(dirname "$CONF")"; cp "$snap/state.json" "$META"
  command install -m 755 "$snap/sing-box.bin" "$BIN"; systemctl restart sing-box || :
  err "$(L '恢复失败，已回滚' 'Restore failed; rolled back')"; return 1
 fi
 # Hopping is host state: avoid restoring metadata claiming rules that are absent.
 systemctl disable --now singbox-v2-hop.service 2>/dev/null || :
 hop_disable
 ok "$(L '配置已恢复；需要跳跃时请重新开启' 'Configuration restored; re-enable hopping if needed')"
}
# Optional fresh-server preparation. No SSH, firewall, kernel or reboot changes.
initialize_server(){
 need_root
 if [[ ! -r $OS_RELEASE ]]; then err "$(L '无法识别操作系统' 'Cannot detect operating system')"; return 1; fi
 # shellcheck source=/dev/null
 . "$OS_RELEASE"
 case "${ID:-}" in
  ubuntu|debian) ;;
  *) err "$(L "只支持 Ubuntu/Debian，当前：${ID:-unknown}" "Ubuntu/Debian only; detected ${ID:-unknown}")"; return 1;;
 esac
 command -v apt-get >/dev/null || { err "$(L '缺少 apt-get' 'apt-get not found')"; return 1; }
 say "系统：${PRETTY_NAME:-$ID}" "System: ${PRETTY_NAME:-$ID}"
 say '本功能将更新 apt 索引、升级已安装软件、安装诊断工具。' 'This updates apt indexes, upgrades installed packages, and installs diagnostic tools.'
 say '不会自动启用 UFW、变更 SSH、修改 BBR 或重启系统。' 'Does not enable UFW, change SSH/BBR, or reboot.'
 warn "$(L '升级可能更改内核、SSH 等软件包；建议先做 VPS 快照并保留控制台。' 'Updates may change kernel/SSH; create a snapshot and retain console access.')"
 confirm "$(L '确认执行新服务器初始化？' 'Initialize this server (including system upgrade)?')" || { say '已取消' Cancelled; return 0; }
 local -a packages=(curl wget nano vim unzip zip tar openssl ca-certificates ufw iproute2 iputils-ping dnsutils traceroute mtr-tiny net-tools netcat-openbsd jq git socat lsof htop python3 bc util-linux nftables)
 # Installing chrony can remove timesyncd; keep an existing active time-sync service.
 if ! systemctl is-active --quiet chrony && ! systemctl is-active --quiet systemd-timesyncd && ! systemctl is-active --quiet ntp && ! systemctl is-active --quiet ntpsec; then packages+=(chrony); fi
 say '更新软件索引...' 'Updating package indexes...'
 apt-get update || { err "$(L '软件索引更新失败' 'Package index update failed')"; return 1; }
 say '升级已安装软件（不会自动执行 full-upgrade）...' 'Upgrading packages (not full-upgrade)...'
 DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || { err "$(L '系统升级失败；请检查 apt/dpkg 状态' 'Upgrade failed; check apt/dpkg status')"; return 1; }
 say '安装基础工具...' 'Installing essential tools...'
 DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || { err "$(L '工具安装失败' 'Tool installation failed')"; return 1; }
 say '检测时间同步服务...' 'Checking time synchronization...'
 if command -v timedatectl >/dev/null 2>&1; then timedatectl status --no-pager 2>/dev/null || :; fi
 # Do not forcibly disable an existing time-sync daemon.
 if systemctl is-active --quiet chrony 2>/dev/null; then
  say 'chrony 已运行。' 'chrony is running.'
 elif systemctl is-active --quiet systemd-timesyncd 2>/dev/null || systemctl is-active --quiet ntp 2>/dev/null || systemctl is-active --quiet ntpsec 2>/dev/null; then
  say '其他时间同步服务正在运行，不会强制切换到 chrony。' 'Another time synchronization service is running; not switching.'
 else
  say '尝试启用 chrony 时间同步...' 'Trying to enable chrony...'
  systemctl enable --now chrony 2>/dev/null || warn "$(L 'chrony 未启动，请人工检查' 'chrony did not start; check manually')"
 fi
 say '========== 只读检查 ==========' '========== Read-only checks =========='
 echo 'DNS github.com:'
 getent ahostsv4 github.com | sed -n '1,3p' || say 'DNS 解析失败' 'DNS resolution failed'
 say 'GitHub HTTPS:' 'GitHub HTTPS:'
 curl -4sS -I -L --connect-timeout 8 --max-time 18 -o /dev/null -w 'HTTP %{http_code}\n' https://github.com || warn "$(L 'HTTPS 无法连接' 'HTTPS connection failed')"
 say 'SSH 监听端口（仅查看）：' 'SSH listening ports (read-only):'
 ss -ltnp | grep -E 'sshd|:22[[:space:]]' || say '未识别 sshd 监听，请自行核实实际 SSH 端口' 'Could not identify sshd; verify actual SSH port'
 say 'UFW 状态（没有自动开启）：' 'UFW status (not enabled automatically):'
 ufw status verbose || :
 say '系统内核：' Kernel:
 uname -r
 say '如内核或关键服务已升级，请在维护窗口确认后自行决定是否重启。' 'If kernel or essential services were upgraded, plan a manual reboot if necessary.'
 say '新服务器初始化结束。' 'Server initialization complete.'
}

# UFW safety: never assume SSH port 22, and never bypass cloud firewall checks.
detect_ssh_ports(){
 local ports connection_port
 connection_port=$(awk '{print $4}' <<<"${SSH_CONNECTION:-}")
 ports=$(ss -H -lntp | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -nu)
 if [[ -z $ports ]] && command -v sshd >/dev/null; then ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -nu); fi
 if valid_port "$connection_port"; then ports=$(printf '%s\n%s\n' "$ports" "$connection_port" | sed '/^$/d' | sort -nu); fi
 SSH_PORTS=$ports
 printf '%s\n' "$(L '识别到 SSH 端口（请确认）：' 'Detected SSH ports (verify): ')$ports"
}
firewall(){
 need_root
 say '1 安装 UFW  2 开启  3 关闭  4 查看状态  5 放行端口  6 删除规则  0 返回' '1 Install UFW  2 Enable  3 Disable  4 Status  5 Allow port  6 Delete rule  0 Back'
 local choice port proto
 read -r -p '> ' choice || return
 case "$choice" in
 1) confirm "$(L '安装 UFW？' 'Install UFW?')" && apt-get update && apt-get install -y ufw ;;
 2)
   require_cmd ufw || return
   say '当前 SSH 监听信息（必须人工核实）：' 'SSH listener information (VERIFY manually):'
   detect_ssh_ports
   read -r -p "$(L '输入当前 SSH TCP 端口（请核实云控制台/sshd 设置）：' 'Enter verified SSH TCP port: ')" port
   port=${port:-${SSH_PORTS:-}}
   valid_port "$port" || { err "$(L 'SSH 端口无效' 'Invalid SSH port')"; return 1; }
   warn "$(L '如果 SSH 端口判断错误，开启 UFW 可能导致远程连接断开！请保留 VPS 控制台访问。' 'Wrong SSH port may lock you out. Keep VPS console access.')"
   say '将放行 SSH 端口与当前部署节点的 443 端口。' 'Will allow SSH and relevant deployed 443 ports.'
   confirm "$(L '确认开启 UFW 防火墙？' 'Enable UFW now?')" || return 0
   ufw allow "$port/tcp" || return 0
   local detected
   while read -r detected; do [[ -z $detected ]] || ufw allow "$detected/tcp" || return 1; done <<<"$SSH_PORTS"
   if [[ -f $META ]]; then
    case "$(protocol_mode)" in 1) ufw allow 443/tcp;; 2) ufw allow 443/udp;; 3) ufw allow 443/tcp; ufw allow 443/udp;; esac
   fi
   if [[ -f $META && $(state hop) == True ]]; then ufw allow "$(state hop_start):$(state hop_end)/udp" || return 1; fi
   ufw default deny incoming; ufw default allow outgoing; ufw --force enable
   warn "$(L '如有 HY2 跳跃或云防火墙，需另外确认规则。' 'Check HY2 hopping and provider firewall rules separately.')" ;;
 3) require_cmd ufw && confirm "$(L '关闭 UFW 会降低保护，确定？' 'Disable UFW and reduce protection?')" && ufw --force disable ;;
 4) require_cmd ufw && ufw status verbose ;;
 5) require_cmd ufw || return
    read -r -p "$(L '端口：' 'Port: ')" port; valid_port "$port" || return 1
    read -r -p "$(L '协议 (tcp/udp)：' 'Protocol (tcp/udp): ')" proto; [[ $proto == tcp || $proto == udp ]] || return 1
    confirm "$(L "放行 $port/$proto？" "Allow $port/$proto?")" && ufw allow "$port/$proto" ;;
 6) require_cmd ufw || return; ufw status numbered
    read -r -p "$(L '规则编号：' 'Rule number: ')" port; [[ $port =~ ^[0-9]+$ ]] || return 1
    confirm "$(L '删除指定规则？确认不会影响 SSH！' 'Delete rule? Ensure SSH stays reachable!')" && ufw --force delete "$port" ;;
 0) return;; *) err "$(L '无效选择' 'Invalid choice')";;
 esac
 return 0
}
service_manager(){
 say '1 状态  2 启动  3 重启  4 停止  5 开机自启  6 配置检查  0 返回' '1 Status  2 Start  3 Restart  4 Stop  5 Enable at boot  6 Config check  0 Back'
 local x; read -r -p '> ' x || return
 case "$x" in
 1) status;; 2) check_owned && confirm "$(L '启动 sing-box？' 'Start sing-box?')" && systemctl start sing-box;;
 3) check_owned && confirm "$(L '重启 sing-box？' 'Restart sing-box?')" && "$BIN" check -c "$CONF" && systemctl restart sing-box;;
 4) check_owned && warn "$(L '所有节点将断开连接' 'All nodes will disconnect')" && confirm "$(L '停止 sing-box？' 'Stop sing-box?')" && systemctl stop sing-box;;
 5) check_owned && confirm "$(L '设置开机自启？' 'Enable sing-box at boot?')" && systemctl enable sing-box;;
 6) check_owned && "$BIN" check -c "$CONF";; 0) return;; *) err "$(L '无效选择' 'Invalid choice')";; esac
 return 0
}
traffic(){
 say 'vnStat 统计 VPS 网卡流量，不能区分 Reality/HY2；历史数据从安装后开始。' 'vnStat tracks VPS interface traffic, NOT Reality/HY2 separately. History starts when installed.'
 say '1 安装 vnStat  2 今日  3 本月  4 实时网速  5 历史汇总  0 返回' '1 Install vnStat  2 Today  3 Monthly  4 Live  5 History  0 Back'
 local x; read -r -p '> ' x || return
 case "$x" in
 1) confirm "$(L '安装 vnStat？' 'Install vnStat?')" && apt-get update && apt-get install -y vnstat && systemctl enable --now vnstat;;
 2) require_cmd vnstat && vnstat -d;; 3) require_cmd vnstat && vnstat -m;;
 4) require_cmd vnstat && vnstat -l;; 5) require_cmd vnstat && vnstat;; 0) return;; *) err "$(L '无效选择' 'Invalid choice')";; esac
 return 0
}
subscription(){
 check_owned || return
 warn "$(L '仅生成本地订阅文件；不会开启公开的 HTTP/HTTPS 订阅服务。' 'Local subscription files only; no public HTTP/HTTPS service will be started.')"
 exports || return 1
 say '通用 URI/base64 仅适用于支持该格式和 HY2 证书验证的客户端。Mihomo YAML 为代理片段，sing-box JSON 为出站片段。' 'URIs/base64 require client support and HY2 cert trust. Mihomo YAML and sing-box JSON are fragments.'
}

action_failed(){ err "$(L '操作失败；请检查上面的输出' 'Operation failed; inspect the output above')"; }
main(){ need_root; require_cmd flock
 while :; do
  printf '%s' "$CYAN"
  printf '\n==============================================\n'
  cat <<'LOGO'
   ███████╗██╗  ██╗██╗   ██╗██████╗ ██╗   ██╗████████╗███████╗
   ██╔════╝██║ ██╔╝╚██╗ ██╔╝██╔══██╗╚██╗ ██╔╝╚══██╔══╝██╔════╝
   ███████╗█████╔╝  ╚████╔╝ ██████╔╝ ╚████╔╝    ██║   █████╗
   ╚════██║██╔═██╗   ╚██╔╝  ██╔══██╗  ╚██╔╝     ██║   ██╔══╝
   ███████║██║  ██╗   ██║   ██████╔╝   ██║      ██║   ███████╗
   ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚═════╝    ╚═╝      ╚═╝   ╚══════╝
                  SKYBYTE Manager V2.1
                Reality · Hysteria2 · VPS
LOGO
  printf '        sing-box · Reality · HY2\n'
  printf '==============================================%s\n' "$RESET"
  printf '%s' "$GREEN"
  if [[ $LANGUAGE_CHOICE == en_US ]]; then
   cat <<'MENU'
 1. sing-box (Reality Vision)
 2. Hysteria 2
 3. sing-box + Hysteria 2 Dual
 4. View node information
 5. Local subscription exports
 6. UFW firewall management
 7. Firewall status
 8. Service & node status / controls
 9. VPS traffic (vnStat)
10. Enable BBR + FQ
11. HY2 port hopping
12. Check/update sing-box
13. Weekly auto-update
14. Backup configuration
15. Restore configuration
16. IP information check
17. Network diagnostics
18. Recent logs
19. Legal and privacy notice
20. Initialize new server
21. Change language
 0. Exit
MENU
  else
   cat <<'MENU'
 1. sing-box（Reality Vision）
 2. Hysteria 2
 3. sing-box + Hysteria 2 双协议
 4. 查看节点信息
 5. 本地订阅节点管理
 6. UFW 防火墙管理
 7. 查看防火墙状态
 8. 节点运行状态与控制
 9. VPS 流量统计（vnStat）
10. 开启 BBR + FQ
11. HY2 端口跳跃
12. 手动检查更新
13. 每周自动更新
14. 备份配置
15. 恢复配置
16. IP 信息检测
17. 网络诊断
18. 查看最近日志
19. 法律隐私声明
20. 新服务器初始化
21. 切换语言
 0. 退出
MENU
  fi
  printf '%s' "$RESET"
  printf '%sYouTube: %s%s\n' "$CYAN" "$YOUTUBE" "$RESET"
  read -r -p "$(L '请选择：' 'Select: ')" x || exit 0
  [[ $x != 0 ]] || return 0
  set +e
  (
   set -Eeuo pipefail
   trap action_failed ERR
  case "$x" in
   1|2|3) install_protocol "$x";;
   4) exports;; 5) subscription;; 6) firewall;; 7) firewall_audit;;
   8) service_manager;; 9) traffic;; 10) bbr;; 11) hop;; 12) update;; 13) configure_auto;;
   14) backup;; 15) restore;; 16) ipcheck;; 17) netcheck;; 18) journalctl -u sing-box -n 80 --no-pager;;
   19) notice;; 20) initialize_server;; 21) select_language;; 0) exit 0;; *) err "$(L '无效选项' 'Invalid choice')";;
  esac
  )
  set -e
  load_language
 done
}

bootstrap(){
 need_root
 require_cmd flock || return 1
 mkdir -p "$BASE" "$REPORT" "$BACKUP"; chmod 700 "$BASE" "$REPORT" "$BACKUP"
 exec 9>"$LOCK"; flock -n 9 || { err "$(L '其他管理任务正在运行' 'Another manager is running')"; return 1; }
 load_language
 if [[ -z $LANGUAGE_CHOICE ]]; then
  if [[ ${1:-} == --auto-update || ${1:-} == --notice ]]; then LANGUAGE_CHOICE=en_US; else select_language || return 1; fi
 fi
 export LANGUAGE_CHOICE
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
 bootstrap "${1:-}" || exit 1
 case "${1:-}" in --auto-update) update_auto;; --notice) notice;; *) main;; esac
fi
