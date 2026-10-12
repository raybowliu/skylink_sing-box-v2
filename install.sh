#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -t 2 && -z ${NO_COLOR:-} ]]; then RED=$'\033[1;31m'; RESET=$'\033[0m'; else RED=''; RESET=''; fi
err(){ printf '%s%s%s\n' "$RED" "$*" "$RESET" >&2; }
if (( EUID != 0 )); then err 'Please run as root / 请使用 root'; exit 1; fi
URL='https://raw.githubusercontent.com/skylink9119/sing-box-v2/main/singbox-v2.sh'
command -v curl >/dev/null || { err 'curl required / 需要 curl'; exit 1; }
mkdir -p /usr/local/lib/singbox-v2
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$URL" -o "$TMP"
bash -n "$TMP"
install -m 700 "$TMP" /usr/local/lib/singbox-v2/singbox-v2.sh
exec bash /usr/local/lib/singbox-v2/singbox-v2.sh
