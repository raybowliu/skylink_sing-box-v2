#!/usr/bin/env bash
set -Eeuo pipefail

REPO="skylink9119/sing-box-v2"
BRANCH="main"

URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/singbox-v2.sh"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限运行 / Please run as root."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "缺少 curl，请先安装 / curl is required."
    exit 1
fi

INSTALL_DIR="/usr/local/lib/singbox-v2"
INSTALL_FILE="$INSTALL_DIR/singbox-v2.sh"

mkdir -p "$INSTALL_DIR"

echo "正在下载 sing-box V2.0 / Downloading..."

curl -fL \
    --retry 3 \
    --connect-timeout 10 \
    --max-time 120 \
    "$URL" \
    -o "$INSTALL_FILE"

bash -n "$INSTALL_FILE"

chmod 700 "$INSTALL_FILE"

echo "下载完成 / Download completed."

exec bash "$INSTALL_FILE"
