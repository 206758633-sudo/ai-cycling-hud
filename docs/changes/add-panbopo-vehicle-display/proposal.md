## Why

已确认将新接入的 PANBOPO ESP32-C3 用作车载显示屏。骑士已有的 SSD1306 固件针对 ESP32-S3 和 I²C OLED。新板需要匹配其 SPI GC9A01 显示硬件的构建目标。

## What Changes

- 增加独立 ESP32-C3 车载屏固件，复用骑士现有 BLE 导航 UUID 和 `D:方向|距离`。
- 分片检查顺序、长度和有效期。连接断开或指引过期时清除旧方向。
- 读取并保留新板的出厂闪存映像，再对指定新板烧录和验证。

## Capabilities

### New Capabilities

- `panbopo-vehicle-display`：兼容现有骑士 App 的 ESP32-C3 车载显示。

### Modified Capabilities

## Impact

新增独立固件目录。原 ESP32-S3 小布、iPhone 和订单服务继续使用原流程。
