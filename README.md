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

## 双 ESP32 显示方案

小智 ESP32-S3 负责语音与头盔 HUD，另一块 ESP32 驱动车载屏。骑士 App 统一算路并分别发送导航指引。方案已整理，双板联调和实体 HUD 验收待完成。[查看技术方案](docs/architecture/technical-architecture.md)

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

- 骑士内置高德地图覆盖导航、自提、自由骑行、个人轨迹与打卡。车队位置共享待接入。骑行实测曾用蓝牙测试接收器核对「67 米后右转」，实体双屏和实骑轨迹待验收。
- 语音控屏显示小布自提任务的进展。核实结算后，小布播报门店、规格、价格和待付款状态。用户说「开始导航」后，骑士请求高德 GPS 骑行导航，并在 SDK 确认启动后更新回执。
- 24 项订单测试及静默接口验证通过。结算弹窗修复已回放验证。新版小布固件的烧录、真实语音往返及这一版语音启动导航的真机联调待验收。
- 车载屏能重组正常导航分片。异常分片序号校验待完善。

[骑行地图](docs/changes/complete-cycling-maps/proposal.md) · [语音控屏](docs/changes/hands-free-voice-control/proposal.md) · [自提结算及语音启动导航](docs/changes/verify-voice-pickup-navigation/proposal.md)

```sh
python3 -m unittest discover -s server
```

## 许可证

项目自有原创代码采用 [Apache-2.0](LICENSE)。小智上游源码保留 [MIT](firmware/xiaozhi-esp32/LICENSE)，Poki 组件保留 [AGPL-3.0-only](app/骑士Knight-iOS/KnightApp/PokiNative/LICENSE)。分发链接 Poki 的 iOS 调试版时，需遵守 AGPL 对组合程序的要求。高德 SDK 由官方按其许可提供。详见 [NOTICE](NOTICE)。
