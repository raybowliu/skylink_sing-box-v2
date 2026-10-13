media_check(){
 require_cmd curl && require_cmd python3 || return 1
 local selection paths port=''
 say '检测匿名服务页面和地区提示；没有登录或实际播放验证。HTTP 200 不代表已解锁。' 'Checks anonymous pages/region hints, without login or playback verification. HTTP 200 does not mean unlocked.'
 prompt_options '1 直连 IPv4  2 直连 IPv6  3 两者  4 WARP  5 IPv4 与 WARP 对比  0 返回' '1 Direct IPv4  2 Direct IPv6  3 Both  4 WARP  5 IPv4/WARP comparison  0 Back'
 prompt_read '> ' selection || return 0
 case $selection in 1) paths=4;; 2) paths=6;; 3) paths=4,6;; 4) paths=warp;; 5) paths=4,warp;; 0) return 0;; *) return 1;; esac
 if [[ $paths == *warp* ]]; then port=$(warp_engine port) && warp_verify "$port" || return 1; fi
 python3 - "$paths" "$REPORT" "$port" "${LANGUAGE_CHOICE:-zh_CN}" <<'PY_MEDIA'
# @include media.py
PY_MEDIA
}
