relay_verify(){
 local address
 address=$(warp_engine relay_probe "$1") || { err "$(L '落地节点连接验证失败；未应用中转。请检查地址、凭据、证书和中转到落地的链路。' 'Landing connection failed; relay not applied. Check address, credentials, trust and the entry-to-exit link.')";return 1; }
 ok "$(L '落地 TCP / HTTPS 出口验证通过：' 'Landing TCP / HTTPS egress verified: ')$address"
 say 'UDP 可达性和实际速度需另行实测；检测不代表住宅 IP 属性或平台解锁。' 'UDP reachability and speed need separate measurement; this test does not establish residential IP classification or platform access.'
}
relay_switch(){
 local mode=$1 profile=$2 domains=${3:-example.com} snap admin=false argo=false users=false
 check_owned && warp_guard && users_guard && argo_guard || return 1
 if [[ $mode != direct ]];then relay_verify "$profile" || return 1;fi
 snap=$(backup) || return 1
 if systemctl is-active --quiet sing-box.service;then admin=true;fi
 if [[ -f $BASE/argo-state.json ]] && systemctl is-active --quiet skybyte-argo-node.service;then argo=true;fi
 if [[ -f $BASE/users.json ]] && systemctl is-active --quiet skybyte-users.service;then users=true;users_stop || return 1;fi
 if ! warp_engine relay_switch "$mode" "$profile" "$domains";then warp_resume "$admin" "$argo" "$users" || :;return 1;fi
 if ! warp_resume "$admin" "$argo" "$users";then
  if [[ $users == true ]];then users_stop || :;fi
  warp_engine restore "$snap" || return 1
  warp_resume "$admin" "$argo" "$users" || :
  err "$(L '中转重启失败，已回滚原出站配置。' 'Relay restart failed; previous routing restored.')";return 1
 fi
 ok "$(L '中转出站模式已应用：' 'Relay routing applied: ')$mode"
 say "备份：$snap" "Backup: $snap"
}
relay_import_menu() (
 local choice source link trust stage mode domains rc=0
 stage=$(mktemp -d "$BASE/relay-import.XXXXXX") || return 1
 trap 'rm -rf -- "$stage"' EXIT
 prompt_options '1 粘贴节点链接（隐藏输入）  2 导入本地节点 / sing-box JSON 文件  0 返回' '1 Paste node URI (hidden input)  2 Local node / sing-box JSON file  0 Back'
 prompt_read '> ' choice || { rm -rf "$stage";return 0; }
 case $choice in
  1)
   prompt_read "$(L '落地 Reality/Vision 或 HY2 链接（隐藏）：' 'Landing Reality/Vision or HY2 URI (hidden): ')" link secret || { rm -rf "$stage";return 0; };echo
   printf '%s\n' "$link" > "$stage/source";unset link;source=$stage/source;;
  2) prompt_read "$(L '私密节点文件路径（仅一个落地节点）：' 'Private node file path (exactly one landing node): ')" source || { rm -rf "$stage";return 0; };;
  0) rm -rf "$stage";return 0;; *) rm -rf "$stage";return 1;;
 esac
 say 'HY2 自签名：从落地 VPS 经可信 SSH/SFTP 获取公开证书并核对指纹，不要提供私钥。受信任 CA 证书可回车跳过。' 'Self-signed HY2: retrieve the public certificate over trusted SSH/SFTP and verify its fingerprint. Never supply a private key. Press Enter for a trusted CA certificate.'
 prompt_read "$(L 'HY2 公开信任证书路径（可选）：' 'HY2 public trust certificate path (optional): ')" trust || { rm -rf "$stage";return 0; }
 if ! warp_engine relay_prepare "$source" "$stage/profile.json" "$trust";then rm -rf "$stage";return 1;fi
 prompt_options '1 全部节点流量走落地（默认）  2 仅指定域名走落地，其余直连  0 取消' '1 All node traffic through landing (default)  2 Selected domains; others direct  0 Cancel'
 prompt_read '> ' choice || { rm -rf "$stage";return 0; };choice=${choice:-1};domains=example.com
 case $choice in
  1) mode=global;;
  2) mode=restricted;prompt_read "$(L '域名后缀，空格分隔：' 'Domain suffixes, space-separated: ')" domains || { rm -rf "$stage";return 0; };;
  0) rm -rf "$stage";return 0;; *) rm -rf "$stage";return 1;;
 esac
 warn "$(L '此操作替换当前 WARP / 中转出站策略，并短暂重启运行中的管理员、用户和 Argo 节点。客户端仍连接本 VPS；落地凭据不会导出给用户。' 'This replaces current WARP / relay routing and briefly restarts active admin, account and Argo nodes. Clients still connect to this VPS; landing credentials are not exported.')"
 if confirm "$(L '验证落地并启用中转？' 'Verify the landing node and enable relay?')";then relay_switch "$mode" "$stage/profile.json" "$domains" || rc=$?;fi
 rm -rf "$stage";return "$rc"
)
relay_menu() (
 check_owned && warp_guard || return 1
 local choice stage rc=0
 printf '%s' "$YELLOW";warp_engine relay_status "${LANGUAGE_CHOICE:-zh_CN}";printf '%s' "$RESET"
 say '路径：客户端 → 本 VPS → 落地 VPS → 网站。落地失败不自动改用本机出口。' 'Path: client → this VPS → landing VPS → destination. Landing failure does not automatically use this VPS as the exit.'
 prompt_options '1 导入 / 更换落地节点  2 测试落地连接  3 全局中转  4 恢复直连  5 删除已保存的落地凭据  0 返回' '1 Import / replace landing  2 Test landing  3 Global relay  4 Restore direct  5 Remove saved landing credentials  0 Back'
 prompt_read '> ' choice || return 0
 if [[ $choice == 1 ]];then relay_import_menu;return $?;fi
 [[ $choice != 0 ]] || return 0
 stage=$(mktemp -d "$BASE/relay-action.XXXXXX") || return 1
 trap 'rm -rf -- "$stage"' EXIT
 if ! warp_engine relay_export "$stage/profile.json";then rm -rf "$stage";return 1;fi
 case $choice in
  2) relay_verify "$stage/profile.json" || rc=$?;;
  3) confirm "$(L '验证并切换所有节点到住宅落地出口？当前 WARP / 中转分流将被替换。' 'Verify and route all nodes through the landing exit? Current WARP / relay routing will be replaced.')" && relay_switch global "$stage/profile.json" || rc=$?;;
  4) confirm "$(L '恢复原始直连路由？网站将看到本 VPS 出口 IP。' 'Restore original direct routing? Destinations will see this VPS egress IP.')" && relay_switch direct "$stage/profile.json" || rc=$?;;
  5) confirm "$(L '删除保存的落地凭据？已启用中转时须先恢复直连或切换 WARP。' 'Remove saved landing credentials? First restore direct routing or switch to WARP if relay is active.')" && warp_engine relay_forget || rc=$?;;
  *) rc=1;;
 esac
 rm -rf "$stage";return "$rc"
)
