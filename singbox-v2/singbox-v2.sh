#!/usr/bin/env bash
# sing-box V2.0 community manager; review before running, Debian/Ubuntu only
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
err(){ echo "错误：$*" >&2; }
need_root(){ [[ $EUID == 0 ]] || { err "$(L '需要 root 权限' 'Root privileges required')"; exit 1; }; }
confirm(){ local answer; read -r -p "$1 $(L '[输入 YES 确认]' '[Type YES to confirm]'): " answer; [[ $answer == YES ]]; }
notice(){ if [[ "$LANGUAGE_CHOICE" == en_US ]]; then cat <<'EOF_EN'
[LEGAL & PRIVACY NOTICE] Use only for lawful networking education and server administration. You must comply with applicable law and service terms. Updating software or changing firewall/network settings may interrupt service or cause data loss; make backups first. Provided as-is to the extent permitted by law. Third-party components retain their licenses.
Installation and updates can contact sing-box.app, github.com, api.github.com and GitHub release CDNs; these services can see your source IP. Installation queries api.ipify.org for your public IPv4. The optional IP report queries ipinfo.io, which may retain your IP and request metadata; reports are stored locally in /etc/singbox-v2/reports and deleted after 30 days. No developer telemetry and no intentional upload of node credentials. Auto-update is opt-in. HY2 requires a domain and valid TLS certificate; TLS verification is not bypassed by default.
EOF_EN
else cat <<'EOF'
【法律与隐私披露】此工具仅供合法网络技术学习和服务器管理；使用者应遵守适用法律和服务条款。更改防火墙、网络参数及更新软件可能导致中断或损失，请提前备份。软件按现状提供，不排除依法不得排除的责任。第三方软件遵循其许可证。
安装/更新可能连接：sing-box.app、github.com、api.github.com、GitHub 发布文件 CDN，访问服务会暴露请求来源 IP。安装时 api.ipify.org 用于识别出口 IP。可选 IP 检测使用 ipinfo.io，报告保存在本地 /etc/singbox-v2/reports，默认保留 30 天；第三方可能记录来源 IP、查询目标和请求时间。无开发者遥测或上传节点密钥；请勿公开包含凭据的配置和导出文件。自动更新默认关闭。HY2 需自有域名及有效 TLS 证书；不会默认跳过证书校验。
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
 need_root; notice; confirm "$(L '同意声明并安装双协议？' 'Accept notice and install both protocols?')" || return 0
 [[ ! -e $CONF && ! -e $META ]] || { err '发现已有配置，拒绝覆盖'; return 1; }
 if systemctl list-unit-files sing-box.service --no-legend 2>/dev/null | grep -q sing-box; then err '已有 sing-box 服务，拒绝覆盖'; return 1; fi
 for x in sing-box xray nginx; do :; done
 if ss -H -ltn '( sport = :443 )' | grep -q . || ss -H -lun '( sport = :443 )' | grep -q .; then err 'TCP 或 UDP 443 已被占用'; return 1; fi
 read -r -p "$(L 'HY2 域名（需已有有效证书）：' 'HY2 domain (valid TLS certificate required): ')" domain
 [[ $domain =~ ^[a-zA-Z0-9.-]+$ && $domain == *.* ]] || { err '域名格式不正确'; return 1; }
 read -r -p "$(L 'TLS 完整证书路径（PEM）：' 'Full TLS certificate path (PEM): ')" cert
 read -r -p "$(L 'TLS 私钥路径（PEM）：' 'TLS private key path (PEM): ')" key
 [[ -f $cert && -f $key ]] || { err '证书或私钥文件不存在'; return 1; }
 read -r -p "$(L 'Reality 握手域名 [addons.mozilla.org]：' 'Reality handshake domain [addons.mozilla.org]: ')" sni; sni=${sni:-addons.mozilla.org}
 [[ $sni =~ ^[a-zA-Z0-9.-]+$ ]] || { err 'SNI 格式错误'; return 1; }
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
 python3 - "$CONF" "$META" "$domain" "$cert" "$key" "$sni" "$uuid" "$priv" "$pub" "$sid" "$passwd" "$ip" <<'PY'
import json,sys
conf,meta,domain,cert,key,sni,uuid,priv,pub,sid,password,ip=sys.argv[1:]
d={'log':{'level':'info','timestamp':True},'inbounds':[{'type':'vless','tag':'reality','listen':'0.0.0.0','listen_port':443,'users':[{'name':'user1','uuid':uuid,'flow':'xtls-rprx-vision'}],'tls':{'enabled':True,'server_name':sni,'reality':{'enabled':True,'handshake':{'server':sni,'server_port':443},'private_key':priv,'short_id':[sid]}}},{'type':'hysteria2','tag':'hy2','listen':'0.0.0.0','listen_port':443,'users':[{'name':'user1','password':password}],'tls':{'enabled':True,'server_name':domain,'certificate_path':cert,'key_path':key}}],'outbounds':[{'type':'direct','tag':'direct'}],'route':{'final':'direct'}}
with open(conf,'w') as f:json.dump(d,f,indent=2)
with open(meta,'w') as f:json.dump({'ip':ip,'domain':domain,'sni':sni,'uuid':uuid,'public_key':pub,'sid':sid,'hy2_password':password,'hop':False,'hop_start':20000,'hop_end':30000},f,indent=2)
PY
 chmod 600 "$CONF" "$META"
 "$BIN" check -c "$CONF" || { err '配置检查失败'; return 1; }
 # Official installation's service may have been installed by installer. Keep its unit if present.
 setup_service
 if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow 443/tcp; ufw allow 443/udp; fi
 systemctl daemon-reload; systemctl enable --now sing-box; systemctl restart sing-box
 sleep 2; systemctl is-active --quiet sing-box || { err '服务启动失败，请查看 journalctl -u sing-box'; return 1; }
 echo '部署完成。确认云防火墙已放行 TCP/UDP 443。'; exports
}
exports(){ check_owned || return; python3 - "$META" "$BASE" <<'PY'
import json,sys,urllib.parse,os
s=json.load(open(sys.argv[1]));ip=s['ip'];u=s['uuid'];sid=s['sid'];pk=s['public_key'];p=s['hy2_password'];d=s['domain'];sni=s['sni']
v=f'vless://{u}@{ip}:443?'+urllib.parse.urlencode({'encryption':'none','flow':'xtls-rprx-vision','security':'reality','sni':sni,'fp':'chrome','pbk':pk,'sid':sid,'type':'tcp'})+'#Reality'
h=f'hysteria2://{p}@{ip}:443?'+urllib.parse.urlencode({'sni':d})+'#HY2'
path=os.path.join(sys.argv[2],'nodes.txt')
with open(path,'w') as f:f.write(v+'\n'+h+'\n')
os.chmod(path,0o600)
print('节点文件：'+path+'（包含敏感登录信息）')
print('Reality:\n'+v+'\nHY2:\n'+h)
if s.get('hop'): print('端口跳跃：',s['hop_start'], '-',s['hop_end'],'；HY2 通用 URI 不包含跳跃设置，请使用 sing-box JSON 配置。')
# Export outbound fragment (not a complete client configuration)
out=[{'type':'vless','tag':'Reality','server':ip,'server_port':443,'uuid':u,'flow':'xtls-rprx-vision','tls':{'enabled':True,'server_name':sni,'utls':{'enabled':True,'fingerprint':'chrome'},'reality':{'enabled':True,'public_key':pk,'short_id':sid}}},{'type':'hysteria2','tag':'HY2','server':ip,'server_port':443,'password':p,'tls':{'enabled':True,'server_name':d}}]
if s.get('hop'):out[1].update({'server_ports':[f"{s['hop_start']}:{s['hop_end']}"],'hop_interval':'30s'})
with open(os.path.join(sys.argv[2],'outbounds.json'),'w') as f:json.dump(out,f,ensure_ascii=False,indent=2)
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
hop(){ check_owned || return; require_cmd nft; echo "$(L '端口跳跃仅支持 IPv4，规则通过专属 systemd 服务持久化。请同步修改云防火墙。' 'Port hopping is IPv4 only and uses a dedicated systemd service. Also configure your provider firewall.')"; echo "$(L '1 开启  2 关闭' '1 Enable  2 Disable')"; read -r -p '> ' choice
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
main(){ need_root; require_cmd flock
 while :; do
 if [[ "$LANGUAGE_CHOICE" == en_US ]]; then
 cat <<'MENU_EN'
================ sing-box V2.0 ================
 1 Install dual protocols  2 View/export nodes
 3 Service & firewall     4 Enable BBR + FQ
 5 HY2 port hopping       6 Check/update sing-box
 7 Weekly auto-update     8 Backup config
 9 Restore config        10 IP information
11 Network checks        12 Recent logs
13 Legal/privacy notice  14 Initialize server
15 Change language
 0 Exit
================================================
MENU_EN
 else
 cat <<'MENU_ZH'
================ sing-box V2.0 ================
 1 安装双协议       2 查看/导出节点
 3 服务/防火墙状态  4 开启 BBR + FQ
 5 HY2 端口跳跃     6 手动检查更新
 7 每周自动更新     8 备份配置
 9 恢复配置        10 IP 信息检测
11 基础网络检测    12 查看最近日志
13 法律隐私声明    14 新服务器初始化
15 切换语言
 0 退出
================================================
MENU_ZH
 fi
 read -r -p "$(L '选择：' 'Choose: ')" x
 case "$x" in
 14) initialize_server;; 15) select_language;;
 1) require_cmd python3 && require_cmd ss && install;; 2) require_cmd python3 && exports;; 3) require_cmd ss && status;; 4) bbr;; 5) hop;; 6) update;; 7) configure_auto;; 8) backup;; 9) restore;; 10) ipcheck;; 11) netcheck;; 12) journalctl -u sing-box -n 80 --no-pager;; 13) notice;; 0) exit 0;; *) echo "$(L '无效选项' 'Invalid option')";; esac
 done
}
case "${1:-}" in --auto-update) need_root; update_auto;; --notice) notice;; *) main;; esac
