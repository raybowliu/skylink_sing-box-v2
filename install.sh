#!/usr/bin/env bash
set -Eeuo pipefail
if (( EUID != 0 )); then echo 'Please run as root / 请使用 root'; exit 1; fi
URL='https://raw.githubusercontent.com/skylink9119/sing-box-v2/main/singbox-v2.sh'
command -v curl >/dev/null || { echo 'curl required / 需要 curl'; exit 1; }
mkdir -p /usr/local/lib/singbox-v2
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$URL" -o "$TMP"
bash -n "$TMP"
install -m 700 "$TMP" /usr/local/lib/singbox-v2/singbox-v2.sh
exec bash /usr/local/lib/singbox-v2/singbox-v2.sh
