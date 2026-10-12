#!/usr/bin/env bash
# SKYBYTE Manager V2.1 community manager; review before running, Debian/Ubuntu only
set -Eeuo pipefail
umask 077
BASE=/etc/singbox-v2
CONF=/etc/sing-box/config.json
META=$BASE/state.json
REPORT=$BASE/reports
BACKUP=$BASE/backups
BIN=/usr/local/bin/sing-box
LOCK=/run/singbox-v2.lock
mkdir -p "$BASE" "$REPORT" "$BACKUP"
chmod 700 "$BASE" "$REPORT" "$BACKUP"
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
L() { if [[ "$LANGUAGE_CHOICE" == en_US ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
# Ask on first interactive run, but never block unattended updates.
if [[ "${1:-}" != --auto-update ]]; then
  load_language
  [[ -n "$LANGUAGE_CHOICE" ]] || select_language
else
  load_language
  LANGUAGE_CHOICE=${LANGUAGE_CHOICE:-en_US}
fi
export LANGUAGE_CHOICE
exec 9>"$LOCK"; flock -n 9 || { echo "$(L '其他管理任务正在运行' 'Another management task is already running')"; exit 1; }
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
 GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[1;36m'; RESET=$'\033[0m'
else GREEN=''; RED=''; YELLOW=''; CYAN=''; RESET=''; fi
YOUTUBE='https://www.youtube.com/@SKYBYTE9119'
ok(){ printf '%s✔ %s%s\n' "$GREEN" "$*" "$RESET"; }
warn(){ printf '%s⚠ %s%s\n' "$YELLOW" "$*" "$RESET"; }
err(){ printf '%s✖ %s%s\n' "$RED" "$*" "$RESET" >&2; }
need_root(){ [[ $EUID == 0 ]] || { err "$(L '需要 root 权限' 'Root privileges required')"; exit 1; }; }
confirm(){ local answer; read -r -p "$1 $(L '[输入 YES 确认]' '[Type YES to confirm]'): " answer; answer="${answer//[[:space:]]/}"; [[ "${answer,,}" == yes ]]; }
notice(){ if [[ "$LANGUAGE_CHOICE" == en_US ]]; then cat <<'EOF_EN'
[LEGAL & PRIVACY NOTICE] Use only for lawful networking education and server administration. You must comply with applicable law and service terms. Updating software or changing firewall/network settings may interrupt service or cause data loss; make backups first. Provided as-is to the extent permitted by law. Third-party components retain their licenses.
Installation and updates can contact sing-box.app, github.com, api.github.com and GitHub release CDNs; these services can see your source IP. Installation queries api.ipify.org for your public IPv4. The optional IP report queries ipinfo.io, which may retain your IP and request metadata; reports are stored locally in /etc/singbox-v2/reports and deleted after 30 days. No developer telemetry and no intentional upload of node credentials. Auto-update is opt-in. HY2 requires TLS. A no-domain self-signed certificate mode is available, but clients must securely trust the certificate.
EOF_EN
else cat <<'EOF'
【法律与隐私披露】此工具仅供合法网络技术学习和服务器管理；使用者应遵守适用法律和服务条款。更改防火墙、网络参数及更新软件可能导致中断或损失，请提前备份。软件按现状提供，不排除依法不得排除的责任。第三方软件遵循其许可证。
安装/更新可能连接：sing-box.app、github.com、api.github.com、GitHub 发布文件 CDN，访问服务会暴露请求来源 IP。安装时 api.ipify.org 用于识别出口 IP。可选 IP 检测使用 ipinfo.io，报告保存在本地 /etc/singbox-v2/reports，默认保留 30 天；第三方可能记录来源 IP、查询目标和请求时间。无开发者遥测或上传节点密钥；请勿公开包含凭据的配置和导出文件。自动更新默认关闭。HY2 必须有 TLS 证书，无域名用户可生成自签名证书，客户端必须正确配置信任，不能默认跳过证书验证。
EOF
fi
}
require_cmd(){ command -v "$1" >/dev/null || { err "缺少命令 $1"; return 1; }; }
valid_port(){ [[ $1 =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
state(){ python3 - "$META" "$1" <<'PY'
import json,sys
with open(sys.argv[1]) as f: d=json.load(f)
print(d.get(sys.argv[2],''))
PY
}
check_owned(){ [[ -f $META && -f $CONF ]] || { err "$(L '未发现由本脚本部署的节点' 'No deployment managed by this script was found')"; return 1; }; }
backup(){ check_owned || return; local path="$BACKUP/$(date +%Y%m%d-%H%M%S)-$RANDOM"; mkdir -p "$path"; chmod 700 "$path"; cp -a /etc/sing-box "$path/"; cp -a "$META" "$path/state.json"; if command -v sing-box >/dev/null; then cp -a "$(command -v sing-box)" "$path/sing-box"; fi; printf '%s\n' "$path"; }
installer(){ local tmp; tmp=$(mktemp); curl -fLSs --retry 2 --connect-timeout 10 --max-time 90 https://sing-box.app/install.sh -o "$tmp" || { rm -f "$tmp"; return 1; }; sh "$tmp" "$@"; local rc=$?; rm -f "$tmp"; return "$rc"; }
setup_service(){ cat >/etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box (managed by singbox-v2)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
 systemctl daemon-reload; }
# If an official package created a service, do not replace it: install requires a clean VPS.
install(){
 need_root
 local mode="${1:-}" cert_mode="" 
 if [[ -z "$mode" ]]; then printf '\033[1;32m%s\033[0m\n' "$(L '1 Reality 单协议 | 2 HY2 单协议 | 3 双协议 | 0 返回' '1 Reality only | 2 HY2 only | 3 Dual | 0 Back')"
 read -r -p '> ' mode || return; fi
 [[ "$mode" == 0 ]] && return
 [[ "$mode" =~ ^[123]$ ]] || { err "Invalid selection"; return 1; }
 notice; confirm "$(L '同意声明并安装所选协议？' 'Accept notice and install selected protocol(s)?')" || return 0
 [[ ! -e $CONF && ! -e $META ]] || { err '发现已有配置，拒绝覆盖'; return 1; }
 if systemctl list-unit-files sing-box.service --no-legend 2>/dev/null | grep -q sing-box; then err '已有 sing-box 服务，拒绝覆盖'; return 1; fi
 for x in sing-box xray nginx; do :; done
 if [[ $mode != 2 ]] && ss -H -ltn '( sport = :443 )' | grep -q .; then err 'TCP 443 is occupied'; return 1; fi
 if [[ $mode != 1 ]] && ss -H -lun '( sport = :443 )' | grep -q .; then err 'UDP 443 is occupied'; return 1; fi
 local domain="" cert="" key="" sni=""
 if [[ $mode != 1 ]]; then
  echo "$(L 'HY2证书: 1 无域名(自动自签名)  2 已有证书' 'HY2 certificate: 1 No domain (self-signed)  2 Existing certificate')"
  read -r -p '> ' cert_mode
  case "$cert_mode" in
   1) echo "$(L '需要客户端安全地导入证书并启用验证。' 'Client must securely import and verify the certificate.')";;
   2) read -r -p "$(L '证书域名：' 'Certificate domain: ')" domain
      [[ $domain =~ ^[a-zA-Z0-9.-]+$ && $domain == *.* ]] || { err 'Invalid domain'; return 1; }
      read -r -p "$(L 'TLS 完整证书路径：' 'TLS fullchain path: ')" cert
      read -r -p "$(L 'TLS 私钥路径：' 'TLS key path: ')" key
      [[ -f $cert && -f $key ]] || { err 'Certificate/key missing'; return 1; };;
   *) err 'Invalid certificate option'; return 1;;
  esac
 fi
 if [[ $mode != 2 ]]; then
  read -r -p "$(L 'Reality 握手域名 [addons.mozilla.org]：' 'Reality handshake [addons.mozilla.org]: ')" sni
  sni=${sni:-addons.mozilla.org}
  [[ $sni =~ ^[a-zA-Z0-9.-]+$ ]] || { err 'Invalid SNI'; return 1; }
 fi
 echo "$(L '安装依赖...' 'Installing dependencies...')"; apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl ca-certificates python3 iproute2 util-linux nftables || return 1
 require_cmd getent; getent ahostsv4 github.com >/dev/null || { err 'GitHub DNS 解析失败，请先修复 DNS'; return 1; }
 installer || { err '官方安装失败'; return 1; }
 local sb; sb=$(command -v sing-box || true); [[ -n $sb ]] || { err 'sing-box 未安装'; return 1; }
 # Official script may install /usr/bin and service; use our own single managed path
 cp -a "$sb" "$BIN"; chmod 755 "$BIN"
 local uuid pair priv pub sid passwd ip
 uuid=$(cat /proc/sys/kernel/random/uuid); pair=$("$BIN" generate reality-keypair)
 priv=$(sed -n 's/^PrivateKey: *//p' <<<"$pair"); pub=$(sed -n 's/^PublicKey: *//p' <<<"$pair")
 [[ -n $priv && -n $pub ]] || { err 'Reality 密钥生成失败'; return 1; }
 sid=$(openssl rand -hex 4); passwd=$(openssl rand -hex 16)
 ip=$(curl -4fsS --max-time 15 https://api.ipify.org) || { err '公网 IPv4 查询失败'; return 1; }
 python3 - "$ip" <<'PY' || return 1
import ipaddress,sys
assert ipaddress.ip_address(sys.argv[1]).is_global
PY
 mkdir -p /etc/sing-box
 if [[ $cert_mode == 1 ]]; then
  domain="$ip"; cert=/etc/sing-box/hy2-selfsigned.crt; key=/etc/sing-box/hy2-selfsigned.key
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 -subj "/CN=$ip" -addext "subjectAltName=IP:$ip" -keyout "$key" -out "$cert" >/dev/null 2>&1 || return 1
  chmod 600 "$key"; chmod 644 "$cert"
 fi
 python3 - "$CONF" "$META" "$domain" "$cert" "$key" "$sni" "$uuid" "$priv" "$pub" "$sid" "$passwd" "$ip" "$mode" "$cert_mode" <<'PY'
import json,sys
conf,meta,domain,cert,key,sni,uuid,priv,pub,sid,password,ip,mode,cert_mode=sys.argv[1:]
d={'log':{'level':'info','timestamp':True},'inbounds':[{'type':'vless','tag':'reality','listen':'0.0.0.0','listen_port':443,'users':[{'name':'user1','uuid':uuid,'flow':'xtls-rprx-vision'}],'tls':{'enabled':True,'server_name':sni,'reality':{'enabled':True,'handshake':{'server':sni,'server_port':443},'private_key':priv,'short_id':[sid]}}},{'type':'hysteria2','tag':'hy2','listen':'0.0.0.0','listen_port':443,'users':[{'name':'user1','password':password}],'tls':{'enabled':True,'server_name':domain,'certificate_path':cert,'key_path':key}}],'outbounds':[{'type':'direct','tag':'direct'}],'route':{'final':'direct'}}
if mode=='1': d['inbounds']=d['inbounds'][:1]
elif mode=='2': d['inbounds']=d['inbounds'][1:]
with open(conf,'w') as f:json.dump(d,f,indent=2)
with open(meta,'w') as f:json.dump({'mode':mode,'cert_mode':cert_mode,'cert_path':cert,'ip':ip,'domain':domain,'sni':sni,'uuid':uuid,'public_key':pub,'sid':sid,'hy2_password':password,'hop':False,'hop_start':20000,'hop_end':30000},f,indent=2)
PY
 chmod 600 "$CONF" "$META"
 "$BIN" check -c "$CONF" || { err '配置检查失败'; return 1; }
 # Official installation's service may have been installed by installer. Keep its unit if present.
 setup_service
 if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then [[ $mode != 2 ]] && ufw allow 443/tcp; [[ $mode != 1 ]] && ufw allow 443/udp; fi
 systemctl daemon-reload; systemctl enable --now sing-box; systemctl restart sing-box
 sleep 2; systemctl is-active --quiet sing-box || { err '服务启动失败，请查看 journalctl -u sing-box'; return 1; }
 if [[ $cert_mode == 1 ]]; then echo "$(L '自签名证书：' 'Self-signed certificate: ')$cert"; openssl x509 -in "$cert" -noout -fingerprint -sha256; echo "$(L '务必将证书安全导入客户端并验证，链接本身不足以建立信任。' 'Securely import and verify certificate on client; URL alone cannot establish trust.')"; fi
 echo '部署完成。按实际协议检查云防火墙。'; exports
}
exports(){
 check_owned || return
 python3 - "$META" "$BASE" <<'PY'
import base64,json,os,sys,urllib.parse
s=json.load(open(sys.argv[1]));base=sys.argv[2];ip=s['ip'];mode=s.get('mode','3');d=s.get('domain','');sni=s.get('sni','')
v='vless://{}@{}:443?{}#SKYBYTE-Reality'.format(s['uuid'],ip,urllib.parse.urlencode({'encryption':'none','flow':'xtls-rprx-vision','security':'reality','sni':sni,'fp':'chrome','pbk':s['public_key'],'sid':s['sid'],'type':'tcp'}))
h='hysteria2://{}@{}:443?{}#SKYBYTE-HY2'.format(s['hy2_password'],ip,urllib.parse.urlencode({'sni':d}))
links=[v] if mode=='1' else [h] if mode=='2' else [v,h]
def write(name,content):
 path=os.path.join(base,name)
 with open(path,'w') as f:f.write(content)
 os.chmod(path,0o600)
 return path
write('nodes.txt','\n'.join(links)+'\n'); write('subscription-base64.txt',base64.b64encode(('\n'.join(links)+'\n').encode()).decode()+'\n')
out=[];proxy=[]
if mode!='2':
 out.append({'type':'vless','tag':'SKYBYTE-Reality','server':ip,'server_port':443,'uuid':s['uuid'],'flow':'xtls-rprx-vision','tls':{'enabled':True,'server_name':sni,'utls':{'enabled':True,'fingerprint':'chrome'},'reality':{'enabled':True,'public_key':s['public_key'],'short_id':s['sid']}}})
 proxy.append({'name':'SKYBYTE-Reality','type':'vless','server':ip,'port':443,'uuid':s['uuid'],'network':'tcp','tls':True,'servername':sni,'client-fingerprint':'chrome','flow':'xtls-rprx-vision','reality-opts':{'public-key':s['public_key'],'short-id':s['sid']}})
if mode!='1':
 tls={'enabled':True,'server_name':d}
 if s.get('cert_mode')=='1':tls['certificate_path']='REPLACE_WITH_TRUSTED_CLIENT_CERT_PATH'
 ho={'type':'hysteria2','tag':'SKYBYTE-HY2','server':ip,'server_port':443,'password':s['hy2_password'],'tls':tls}
 if s.get('hop'):ho.update({'server_ports':[f"{s['hop_start']}:{s['hop_end']}"],'hop_interval':'30s'})
 out.append(ho)
 mp={'name':'SKYBYTE-HY2','type':'hysteria2','server':ip,'port':443,'password':s['hy2_password'],'sni':d,'skip-cert-verify':False}
 if s.get('hop'):mp['ports']=f"{s['hop_start']}-{s['hop_end']}";mp['hop-interval']=30
 if s.get('cert_mode')=='1':mp['ca']='REPLACE_WITH_TRUSTED_CLIENT_CERT_PATH'
 proxy.append(mp)
write('outbounds.json',json.dumps(out,ensure_ascii=False,indent=2)+'\n')
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
write('mihomo-proxies.yaml','# SKYBYTE: proxy fragments, merge with a compatible Mihomo config.\n'+'\n'.join(yaml_dump({'proxies':proxy}))+'\n')
notes=[]
if mode!='1' and s.get('cert_mode')=='1':notes.append('HY2 self-signed TLS: securely transfer/trust the generated cert on client and replace REPLACE_WITH_TRUSTED_CLIENT_CERT_PATH. Do NOT disable certificate verification. Confirm each client supports custom CA.')
if s.get('hop'):notes.append('Port hopping requires client-specific support, matching server NAT and cloud firewall; basic URI does NOT encode it.')
write('subscription-notes.txt','\n'.join(notes or ['Check client support before importing.'])+'\n')
print('SKYBYTE local files / 本地文件:')
for name in ['nodes.txt','subscription-base64.txt','outbounds.json','mihomo-proxies.yaml','subscription-notes.txt']:print('  '+os.path.join(base,name))
print('Sensitive node links / 节点链接（请勿公开）:')
for link in links:print(('\033[1;31m'+link+'\033[0m') if sys.stdout.isatty() and not os.getenv('NO_COLOR') else link)
for note in notes:print('WARNING:',note)
PY
}

bbr(){ need_root; confirm "$(L '更改系统 TCP 拥塞控制为 BBR、默认队列为 FQ？' 'Change system TCP congestion control to BBR and default qdisc to FQ?')" || return; modprobe tcp_bbr 2>/dev/null || :; if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then err "$(L '内核不支持 BBR' 'Kernel does not support BBR')"; return 1; fi
 printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >/etc/sysctl.d/90-singbox-v2-bbr.conf
 sysctl -p /etc/sysctl.d/90-singbox-v2-bbr.conf; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc; }
hop_rules(){ local start=$1 end=$2; nft add table ip singbox_v2_hop; nft 'add chain ip singbox_v2_hop prerouting { type nat hook prerouting priority dstnat; policy accept; }'; nft add rule ip singbox_v2_hop prerouting udp dport "$start-$end" redirect to :443; }
hop_disable(){ nft delete table ip singbox_v2_hop 2>/dev/null || :; if [[ -f $META ]]; then python3 - "$META" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['hop']=False
with open(p,'w') as f:json.dump(d,f,indent=2)
PY
 fi; echo "$(L '已关闭本工具管理的端口跳跃规则' 'Disabled managed port-hopping rules')"; }
hop(){ check_owned || return; [[ "$(state mode)" != 1 ]] || { err 'HY2 not installed'; return 1; }; require_cmd nft; echo "$(L '端口跳跃仅支持 IPv4，规则通过专属 systemd 服务持久化。请同步修改云防火墙。' 'Port hopping is IPv4 only and uses a dedicated systemd service. Also configure your provider firewall.')"; echo "$(L '1 开启  2 关闭' '1 Enable  2 Disable')"; read -r -p '> ' choice
 if [[ $choice == 2 ]]; then confirm "$(L '关闭端口跳跃？' 'Disable HY2 port hopping?')" && { systemctl disable --now singbox-v2-hop.service 2>/dev/null || :; hop_disable; }; return; fi
 [[ $choice == 1 ]] || return
 read -r -p "$(L '起始端口 [20000]: ' 'Start port [20000]: ')" start; start=${start:-20000}; read -r -p "$(L '结束端口 [30000]: ' 'End port [30000]: ')" end; end=${end:-30000}
 valid_port "$start" && valid_port "$end" && (( start<=end && start>=1024 && end-start<=10000 && (end<443 || start>443) )) || { err '端口范围非法（最多10001个）'; return 1; }
 confirm "启用 UDP $start-$end 转发到 443？" || return
 nft list table ip singbox_v2_hop >/dev/null 2>&1 && { err '已存在端口跳跃规则，请先关闭'; return 1; }
 cat >/etc/systemd/system/singbox-v2-hop.service <<EOF
[Unit]
Description=singbox V2 HY2 IPv4 port hopping
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/singbox-v2/hop.nft
ExecStop=/usr/sbin/nft delete table ip singbox_v2_hop
[Install]
WantedBy=multi-user.target
EOF
 cat >"$BASE/hop.nft" <<EOF
add table ip singbox_v2_hop
add chain ip singbox_v2_hop prerouting { type nat hook prerouting priority dstnat; policy accept; }
add rule ip singbox_v2_hop prerouting udp dport $start-$end redirect to :443
EOF
 systemctl daemon-reload; systemctl enable --now singbox-v2-hop.service || { err '开启失败'; return 1; }
 if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow "$start:$end/udp"; echo '关闭跳跃后请按需要手动删除对应 UFW 范围规则'; fi
 python3 - "$META" "$start" "$end" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d.update(hop=True,hop_start=int(sys.argv[2]),hop_end=int(sys.argv[3]))
with open(p,'w') as f:json.dump(d,f,indent=2)
PY
 echo "$(L '已启用。请在客户端配置 server_ports 和 hop_interval=30s' 'Enabled. Configure server_ports and hop_interval=30s on clients')"; }
latest(){ curl -4fsSL --max-time 25 https://api.github.com/repos/SagerNet/sing-box/releases/latest | python3 -c 'import json,sys; d=json.load(sys.stdin); assert not d.get("prerelease") and not d.get("draft"); print(d["tag_name"].lstrip("v"))'; }
update(){ check_owned || return; local current new archive oldbin; current=$(sing-box version | awk 'NR==1{print $3}'); new=$(latest) || { err "$(L '无法查询新版本' 'Could not query latest release')"; return 1; }; echo "当前：$current 最新：$new"; [[ $current != "$new" ]] || return 0
 confirm "$(L '升级会短暂中断连接，是否继续？' 'Upgrading briefly interrupts connections. Continue?')" || return 0
 archive=$(backup); oldbin=$(command -v sing-box); echo "备份：$archive"
 # Update the managed binary only; official script may alter unit/package paths, so use downloaded official package via install script cautiously.
 installer --version "$new" || { err "$(L '下载或安装失败，检查当前服务' 'Download/install failed; check current service')"; return 1; }
 local newbin; newbin=$(command -v sing-box)
 cp -a "$newbin" "$BIN"; chmod 755 "$BIN"
 if ! "$BIN" check -c "$CONF" || ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
  err '新版本检查或启动失败，回滚二进制...'; cp -a "$archive/sing-box" "$BIN"; systemctl restart sing-box || :; return 1
 fi
 echo "更新完成：$new；检查客户端连通性。"; }
# Timed updates cannot prompt interactively. Run unattended in a separate path and rollback.
update_auto(){ check_owned || return; local current new snap b; current=$(sing-box version | awk 'NR==1{print $3}'); new=$(latest) || return 0; [[ $current != "$new" ]] || return 0
 snap=$(backup); installer --version "$new" || return 1; b=$(command -v sing-box); cp -a "$b" "$BIN"
 if ! "$BIN" check -c "$CONF" || ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then cp -a "$snap/sing-box" "$BIN"; systemctl restart sing-box || :; return 1; fi
 echo "自动更新 $current -> $new，备份 $snap"; }
configure_auto(){ need_root; echo "$(L '1 启用每周自动更新  2 关闭' '1 Enable weekly automatic updates  2 Disable')"; read -r -p '> ' x
 if [[ $x == 1 ]]; then
 cat >/etc/systemd/system/singbox-v2-update.service <<EOF
[Unit]
Description=sing-box v2 weekly update
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/sbin/singbox-v2 --auto-update
EOF
 cat >/etc/systemd/system/singbox-v2-update.timer <<'EOF'
[Unit]
Description=sing-box v2 weekly update timer
[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=15min
Persistent=true
[Install]
WantedBy=timers.target
EOF
 install -m 700 "$(readlink -f "$0")" /usr/local/sbin/singbox-v2; systemctl daemon-reload; systemctl enable --now singbox-v2-update.timer
 elif [[ $x == 2 ]]; then systemctl disable --now singbox-v2-update.timer 2>/dev/null || :; fi; }
ipcheck(){ notice; confirm "$(L '访问 ipinfo.io 检查 IP 并保存本地报告？' 'Query ipinfo.io and save the IP report locally?')" || return; local stamp path; stamp=$(date +%Y%m%d-%H%M%S); path="$REPORT/ip-$stamp.json"; curl -4fsSL --max-time 20 https://ipinfo.io/json >"$path" || { rm -f "$path"; err 'IP 检测失败'; return 1; }; chmod 600 "$path"; python3 -m json.tool "$path"; find "$REPORT" -type f -mtime +30 -delete; echo "报告：$path；非风险分/流媒体解锁报告"; }
netcheck(){ local stamp path; stamp=$(date +%Y%m%d-%H%M%S); path="$REPORT/net-$stamp.txt"; { echo "date=$(date -Is)"; echo 'route:'; ip route get 1.1.1.1; echo 'DNS:'; getent ahostsv4 github.com | head -3; echo 'HTTP:'; curl -4 -o /dev/null -sS --max-time 15 -w 'github_https_code=%{http_code} connect=%{time_connect}s total=%{time_total}s\n' https://github.com || :; echo 'TCP listeners:'; ss -lnt '( sport = :443 )'; echo 'UDP listeners:'; ss -lnu '( sport = :443 )'; } | tee "$path"; chmod 600 "$path"; find "$REPORT" -type f -mtime +30 -delete; echo "$(L '仅为基础连通性，不测三网回程、UDP 丢包或吞吐量' 'Basic connectivity only; no route-back, UDP loss or throughput testing')"; }
status(){ systemctl --no-pager status sing-box 2>&1 | head -25 || :; echo 'TCP:'; ss -ltn '( sport = :443 )'; echo 'UDP:'; ss -lun '( sport = :443 )'; echo 'UFW:'; command -v ufw >/dev/null && ufw status || :; echo 'Hop:'; nft list table ip singbox_v2_hop 2>/dev/null || :; }
restore(){ local arr choice path; mapfile -t arr < <(find "$BACKUP" -mindepth 1 -maxdepth 1 -type d | sort -r); ((${#arr[@]})) || { err "$(L '没有备份' 'No backups found')"; return; }; printf '%s\n' "${arr[@]}"; read -r -p "$(L '粘贴要恢复的完整备份路径：' 'Full backup directory path to restore: ')" path
 [[ $path == "$BACKUP/"* && -d $path && -f $path/sing-box/config.json && -f $path/sing-box ]] || { err "$(L '备份路径错误' 'Invalid backup path')"; return 1; }
 confirm "$(L '恢复会重启节点并替换配置，继续？' 'Restore config and restart service. Continue?')" || return; backup >/dev/null; cp -a "$path/sing-box/." /etc/sing-box/; cp -a "$path/state.json" "$META"; cp -a "$path/sing-box" "$BIN"; "$BIN" check -c "$CONF" && systemctl restart sing-box; }
# Optional fresh-server preparation. No SSH, firewall, kernel or reboot changes.
initialize_server(){
 need_root
 if [[ ! -r /etc/os-release ]]; then err "$(L '无法识别操作系统' 'Cannot detect operating system')"; return 1; fi
 . /etc/os-release
 case "${ID:-}" in
  ubuntu|debian) ;;
  *) err "只支持 Ubuntu/Debian，当前：${ID:-unknown}"; return 1;;
 esac
 command -v apt-get >/dev/null || { err "$(L '缺少 apt-get' 'apt-get not found')"; return 1; }
 echo "系统：${PRETTY_NAME:-$ID}"
 echo "$(L '本功能将更新 apt 索引、升级已安装软件、安装诊断工具。' 'This updates apt indexes, upgrades installed packages, and installs diagnostic tools.')"
 echo "$(L '不会自动启用 UFW、变更 SSH、修改 BBR 或重启系统。' 'Does not enable UFW, change SSH/BBR, or reboot.')"
 echo "$(L '升级可能更改内核、SSH 等软件包；建议先做 VPS 快照并在云控制台保留救援入口。' 'Updates may change the kernel or SSH packages; create a VPS snapshot and keep console access.')"
 confirm "$(L '确认执行新服务器初始化？' 'Initialize this server (including system upgrade)?')" || { echo "$(L '已取消' Cancelled)"; return 0; }
 local -a packages=(curl wget nano vim unzip zip tar openssl ca-certificates ufw chrony iproute2 iputils-ping dnsutils traceroute mtr-tiny net-tools netcat-openbsd jq git socat lsof htop python3 bc util-linux nftables)
 echo "$(L '更新软件索引...' 'Updating package indexes...')"
 apt-get update || { err "$(L '软件索引更新失败' 'Package index update failed')"; return 1; }
 echo "$(L '升级已安装软件（不会自动执行 full-upgrade）...' 'Upgrading packages (not full-upgrade)...')"
 DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || { err "$(L '系统升级失败；请检查 apt/dpkg 状态' 'Upgrade failed; check apt/dpkg status')"; return 1; }
 echo "$(L '安装基础工具...' 'Installing essential tools...')"
 DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || { err "$(L '工具安装失败' 'Tool installation failed')"; return 1; }
 echo "$(L '检测时间同步服务...' 'Checking time synchronization...')"
 if command -v timedatectl >/dev/null 2>&1; then timedatectl status --no-pager 2>/dev/null || :; fi
 # Do not forcibly disable an existing time-sync daemon.
 if systemctl is-active --quiet chrony 2>/dev/null; then
  echo "$(L 'chrony 已运行。' 'chrony is running.')"
 elif systemctl is-active --quiet systemd-timesyncd 2>/dev/null || systemctl is-active --quiet ntp 2>/dev/null || systemctl is-active --quiet ntpsec 2>/dev/null; then
  echo "$(L '其他时间同步服务正在运行，不会强制切换到 chrony。' 'Another time synchronization service is running; not switching.')"
 else
  echo "$(L '尝试启用 chrony 时间同步...' 'Trying to enable chrony...')"
  systemctl enable --now chrony 2>/dev/null || echo "$(L '提醒：chrony 未启动，请人工检查。' 'Warning: chrony did not start; check manually.')"
 fi
 echo "$(L '========== 只读检查 ==========' '========== Read-only checks ==========')"
 echo 'DNS github.com:'
 getent ahostsv4 github.com | head -3 || echo "$(L 'DNS 解析失败' 'DNS resolution failed')"
 echo "$(L 'GitHub HTTPS:' 'GitHub HTTPS:')"
 curl -4sS -I -L --connect-timeout 8 --max-time 18 -o /dev/null -w 'HTTP %{http_code}\n' https://github.com || echo 'HTTPS 无法连接'
 echo "$(L 'SSH 监听端口（仅查看）：' 'SSH listening ports (read-only):')"
 ss -ltnp | grep -E 'sshd|:22[[:space:]]' || echo "$(L '未识别 sshd 监听，请自行核实实际 SSH 端口' 'Could not identify sshd; verify actual SSH port')"
 echo "$(L 'UFW 状态（没有自动开启）：' 'UFW status (not enabled automatically):')"
 ufw status verbose || :
 echo "$(L '系统内核：' Kernel:)"
 uname -r
 echo "$(L '如内核或关键服务已升级，请在维护窗口确认后自行决定是否重启。' 'If kernel or essential services were upgraded, plan a manual reboot if necessary.')"
 echo "$(L '新服务器初始化结束。' 'Server initialization complete.')"
}

# UFW safety: never assume SSH port 22, and never bypass cloud firewall checks.
firewall(){
 need_root
 echo "$(L '1 安装 UFW  2 开启  3 关闭  4 查看状态  5 放行端口  6 删除规则  0 返回' '1 Install UFW  2 Enable  3 Disable  4 Status  5 Allow port  6 Delete rule  0 Back')"
 local choice port proto
 read -r -p '> ' choice || return
 case "$choice" in
 1) confirm "$(L '安装 UFW？' 'Install UFW?')" && apt-get update && apt-get install -y ufw ;;
 2)
   require_cmd ufw || return
   echo "$(L '当前 SSH 监听信息（必须人工核实）：' 'SSH listener information (VERIFY manually):')"
   ss -lntp | grep -E 'sshd|ssh' || true
   read -r -p "$(L '输入当前 SSH TCP 端口（请核实云控制台/sshd 设置）：' 'Enter verified SSH TCP port: ')" port
   valid_port "$port" || { err 'Invalid SSH port'; return 1; }
   warn "$(L '如果 SSH 端口判断错误，开启 UFW 可能导致远程连接断开！请保留 VPS 控制台访问。' 'Wrong SSH port may lock you out. Keep VPS console access.')"
   echo "$(L '将放行 SSH 端口与当前部署节点的 443 端口。' 'Will allow SSH and relevant deployed 443 ports.')"
   confirm "$(L '确认开启 UFW 防火墙？' 'Enable UFW now?')" || return
   ufw allow "$port/tcp" || return
   if [[ -f $META ]]; then
    case "$(state mode)" in 1) ufw allow 443/tcp;; 2) ufw allow 443/udp;; 3) ufw allow 443/tcp; ufw allow 443/udp;; esac
   fi
   ufw default deny incoming; ufw default allow outgoing; ufw --force enable
   warn "$(L '如有 HY2 跳跃或云防火墙，需另外确认规则。' 'Check HY2 hopping and provider firewall rules separately.')" ;;
 3) require_cmd ufw && confirm "$(L '关闭 UFW 会降低保护，确定？' 'Disable UFW and reduce protection?')" && ufw --force disable ;;
 4) require_cmd ufw && ufw status verbose ;;
 5) require_cmd ufw || return
    read -r -p 'Port: ' port; valid_port "$port" || return 1
    read -r -p 'Protocol (tcp/udp): ' proto; [[ $proto == tcp || $proto == udp ]] || return 1
    confirm "Allow $port/$proto?" && ufw allow "$port/$proto" ;;
 6) require_cmd ufw || return; ufw status numbered
    read -r -p 'Rule number: ' port; [[ $port =~ ^[0-9]+$ ]] || return 1
    confirm "$(L '删除指定规则？确认不会影响 SSH！' 'Delete rule? Ensure SSH stays reachable!')" && ufw --force delete "$port" ;;
 0) return;; *) err 'Invalid choice';;
 esac
}
service_manager(){
 echo "$(L '1 状态  2 启动  3 重启  4 停止  5 开机自启  6 配置检查  0 返回' '1 Status  2 Start  3 Restart  4 Stop  5 Enable at boot  6 Config check  0 Back')"
 local x; read -r -p '> ' x || return
 case "$x" in
 1) status;; 2) check_owned && confirm 'Start sing-box?' && systemctl start sing-box;;
 3) check_owned && confirm 'Restart sing-box?' && "$BIN" check -c "$CONF" && systemctl restart sing-box;;
 4) check_owned && warn 'All nodes will disconnect' && confirm 'Stop sing-box?' && systemctl stop sing-box;;
 5) check_owned && confirm 'Enable sing-box at boot?' && systemctl enable sing-box;;
 6) check_owned && "$BIN" check -c "$CONF";; 0) return;; *) err 'Invalid choice';; esac
}
traffic(){
 echo "$(L 'vnStat 统计 VPS 网卡流量，不能区分 Reality/HY2；历史数据从安装后开始。' 'vnStat tracks VPS interface traffic, NOT Reality/HY2 separately. History starts when installed.')"
 echo "$(L '1 安装 vnStat  2 今日  3 本月  4 实时网速  5 历史汇总  0 返回' '1 Install vnStat  2 Today  3 Monthly  4 Live  5 History  0 Back')"
 local x; read -r -p '> ' x || return
 case "$x" in
 1) confirm 'Install vnStat?' && apt-get update && apt-get install -y vnstat && systemctl enable --now vnstat;;
 2) require_cmd vnstat && vnstat -d;; 3) require_cmd vnstat && vnstat -m;;
 4) require_cmd vnstat && vnstat -l;; 5) require_cmd vnstat && vnstat;; 0) return;; *) err 'Invalid choice';; esac
}
subscription(){
 check_owned || return
 warn "$(L '仅生成本地订阅文件；不会开启公开的 HTTP/HTTPS 订阅服务。' 'Local subscription files only; no public HTTP/HTTPS service will be started.')"
 exports
 echo "$(L '通用 URI/base64 仅适用于支持该格式和 HY2 证书验证的客户端。Mihomo YAML 为代理片段，sing-box JSON 为出站片段。' 'URIs/base64 require client support and HY2 cert trust. Mihomo YAML and sing-box JSON are fragments.')"
}

main(){ need_root; require_cmd flock
 while :; do
  printf '%s' "$CYAN"
  printf '\n==============================================\n'
  printf '               SKYBYTE V2.1\n'
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
  case "$x" in
   1|2|3) require_cmd python3 && require_cmd ss && install "$x";;
   4) exports;; 5) subscription;; 6) firewall;; 7) command -v ufw >/dev/null && ufw status verbose || warn 'UFW not installed';;
   8) service_manager;; 9) traffic;; 10) bbr;; 11) hop;; 12) update;; 13) configure_auto;;
   14) backup;; 15) restore;; 16) ipcheck;; 17) netcheck;; 18) journalctl -u sing-box -n 80 --no-pager;;
   19) notice;; 20) initialize_server;; 21) select_language;; 0) exit 0;; *) err "$(L '无效选项' 'Invalid choice')";;
  esac
 done
}

case "${1:-}" in --auto-update) need_root; update_auto;; --notice) notice;; *) main;; esac
