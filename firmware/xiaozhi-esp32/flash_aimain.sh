#!/usr/bin/env bash
# 烧录自定义唤醒词固件（会覆盖 bootloader/分区表/app/model；不动 NVS 里的 Wi-Fi 配置）
set -euo pipefail
cd "$(dirname "$0")"

IDF_PATH="${IDF_PATH:-$HOME/esp-idf-v5.4.4}"
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" >/dev/null

PORT="${1:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true)}"
if [ -z "$PORT" ]; then echo "没找到串口 /dev/cu.usbmodem*"; exit 1; fi
echo "== flash -> $PORT =="
idf.py -p "$PORT" flash
echo
echo "== 监视串口（Ctrl-] 退出）=="
idf.py -p "$PORT" monitor
