#!/usr/bin/env bash
# 编译 / 烧录 knight_hud 固件（ESP32-S3-WROOM-1 N16R8 + SSD1306 128x64）
# 用法：
#   bash firmware/knight_hud/build.sh          # 只编译
#   bash firmware/knight_hud/build.sh flash    # 编译 + 烧录（自动找 /dev/cu.usbmodem*）
set -euo pipefail
cd "$(dirname "$0")/../.."

FQBN="esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,PartitionScheme=app3M_fat9M_16MB,USBMode=hwcdc"

echo "== compile =="
arduino-cli compile -b "$FQBN" firmware/knight_hud

if [ "${1:-}" = "flash" ]; then
  PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true)
  if [ -z "$PORT" ]; then
    echo "没找到 /dev/cu.usbmodem*：检查 USB 线，或按一下板子 BOOT+RESET 进下载模式"
    exit 1
  fi
  echo "== upload -> $PORT =="
  arduino-cli upload -p "$PORT" -b "$FQBN" firmware/knight_hud
  echo "== serial (115200) =="
  echo "arduino-cli monitor -p $PORT -c baudrate=115200"
fi
