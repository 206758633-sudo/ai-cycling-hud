# AI骑行头显设备

骑士 iOS App、ESP32-S3 头显固件和小智语音固件。骑士在手机上用高德骑行 SDK 规划路线，经蓝牙将下一步转向和距离发给头显。Mac 上的订单服务可选，用于手机与小智协作准备美团自提，付款由用户在美团完成。

## 目录

| 路径 | 内容 |
| --- | --- |
| [app/骑士Knight-iOS](app/骑士Knight-iOS) | Xcode 工程、App 页面、高德骑行导航、Core Bluetooth |
| [firmware/knight_hud](firmware/knight_hud) | ESP32-S3 蓝牙头显与 SSD1306 OLED 固件 |
| [firmware/xiaozhi-esp32](firmware/xiaozhi-esp32) | 小智语音固件、AI-MAIN 板型和自提回执 |
| [server](server) | 可选的局域网订单服务、回归测试与头显调试工具 |
| [docs/hud/ai-hud-protocol.md](docs/hud/ai-hud-protocol.md) | 蓝牙 UUID、UTF-8 分片和头显命令 |

## 构建 iPhone App

用 Xcode 打开 `app/骑士Knight-iOS/KnightApp.xcodeproj`，选择 `KnightApp`。真机安装前在 Signing & Capabilities 选择自己的开发团队和 Bundle ID，部署目标为 iOS 15 及以上。

如需骑士内导航，在仓库根目录执行下列命令，再将自己申请的高德 iOS Key 写入 `app/骑士Knight-iOS/.tmp/AMapKey.local.xcconfig` 的 `KNIGHT_AMAP_IOS_KEY`。Key 要与实际 Bundle ID 匹配。使用真机 Debug 构建。App 会在开始算路前请求高德隐私同意和系统定位许可。 [高德开放平台](https://lbs.amap.com/)

```sh
bash 'app/骑士Knight-iOS/install_amap_sdk.sh'
```

## 构建头显和小智固件

头显使用 ESP32-S3-WROOM-1 N16R8 与 SSD1306 128×64 I²C OLED。SCL 接 GPIO9，SDA 接 GPIO8，OLED 使用 3.3 V 供电并与开发板共地。有源蜂鸣器信号接 GPIO17，确认键用板载 BOOT。烧录前请核对板型和串口。

```sh
arduino-cli core install esp32:esp32@3.3.12
arduino-cli lib install U8g2@2.36.19
bash firmware/knight_hud/build.sh
```

ESP32-S3 AI-MAIN 小智固件使用 ESP-IDF 5.4.4。环境安装和自定义唤醒词配置见 [小智构建说明](firmware/xiaozhi-esp32/README-自定义唤醒词.md)。

```sh
bash firmware/xiaozhi-esp32/build_aimain.sh
```

## 可选的局域网订单服务

用项目自己的服务配置生成手机和小智的独立凭据。界面中的美团「本机执行」依赖 iPhone 调试授权。订单服务仅在可信局域网使用。

```sh
python3 server/knight_orders.py --configure "$(scutil --get LocalHostName).local"
python3 server/knight_orders.py --interface en0
```

在 Mac 上用 `networksetup -listallhardwareports` 确认实际网卡，按需替换 `en0`。iOS 构建传入 `-xcconfig ~/.local/share/knight-orders/iPhone.xcconfig`。AI-MAIN 固件构建会读取同目录的 `knight_order_build.h`，也可在 ESP-IDF 中用 `KNIGHT_ORDERS_CONFIG_DIR` 指定配置目录。配置、密钥和订单数据库保存在本机。

## 验证状态

iPhone 静默实测到库迪黄村新天地店的实时指引「67 米后右转」与蓝牙测试接收器一致。实体头显显示与实际骑行中的连续更新待验收。

```sh
python3 -m unittest discover -s server
```

## 许可证

项目自有原创代码采用 [Apache-2.0](LICENSE)。小智上游源码保留 [MIT](firmware/xiaozhi-esp32/LICENSE)，Poki 组件保留 [AGPL-3.0-only](app/骑士Knight-iOS/KnightApp/PokiNative/LICENSE)。分发链接 Poki 的 iOS 调试版时，需遵守 AGPL 对组合程序的要求。高德 SDK 由官方按其许可提供。详见 [NOTICE](NOTICE)。
