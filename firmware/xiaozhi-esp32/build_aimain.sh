#!/usr/bin/env bash
# 编译「艾尔赛 ESP32S3-AI-MAIN（303ESP32AI7）」小智固件：
#   唤醒词：你好小布（MultiNet 自定义唤醒词，ni hao xiao bu）
# 依赖：$HOME/esp-idf-v5.4.4（已安装）
set -euo pipefail
cd "$(dirname "$0")"

IDF_PATH="${IDF_PATH:-$HOME/esp-idf-v5.4.4}"
if [ ! -f "$IDF_PATH/export.sh" ]; then
  echo "没找到 ESP-IDF：$IDF_PATH（先装 ESP-IDF 5.4.x）"; exit 1
fi
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" >/dev/null

export SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.esp32s3;sdkconfig.defaults.custom"

if [ ! -f sdkconfig ]; then
  echo "== set-target esp32s3 =="
  idf.py set-target esp32s3
fi

echo "== build =="
idf.py build
echo
echo "产物：build/bootloader/bootloader.bin  build/partition_table/partition-table.bin  build/xiaozhi.bin"
echo "烧录：bash flash_aimain.sh [串口]"
