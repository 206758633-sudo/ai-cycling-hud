# 小智 AI-MAIN（303ESP32AI7）自定义唤醒词固件说明

当前唤醒词为「你好小布」（`ni hao xiao bu`）。下方 11 月 24 日的「你好胶布」串口记录是历史验证。

> 板子：艾尔赛 **ESP32S3-AI-MAIN**（PCB V1.1 / 产品编号 303ESP32AI7，ESP32-S3 N16R8）
> 原厂固件：小智 1.9.1，唤醒词「你好小智」（WakeNet 模型 `wn9_nihaoxiaozhi_tts`）
> 现固件：xiaozhi-esp32 v1.9.1 源码 + 板级配置 + **MultiNet7 自定义唤醒词**（`ni hao jiao bu`）
> 验证日期：2026-11-24

---

## 1. 结论

| 项 | 状态 | 证据（串口 115200） |
|---|---|---|
| 唤醒词「你好胶布」 | ✅ 真机可用 | `CustomWakeWord: Custom wake word detected: command_id=1, string= ni hao jiao bu, prob=0.104165` → `Application: Wake word detected: 你好胶布` |
| 旧唤醒词「你好小智」 | ✅ 不再触发 | 播放「你好小智」TTS 后无唤醒记录，状态保持 `idle` |
| 唤醒后对话 | ✅ | `STATE: connecting → listening → speaking`，服务端 TTS 回答正常 |
| Wi-Fi / 设备绑定 | ✅ 保留 | NVS 未擦除，仍连原 Wi-Fi、MQTT 正常（`api.tenclass.net`） |
| 屏幕 / 麦克风 / 喇叭 | ✅ | 日志：`ST7789` 初始化、`LcdDisplay: Turning display on`、`ES8311` 双工 24 kHz、`AudioCodec started` |
| 助手自称「小智」 | ⚠️ 非固件问题 | 这是小智**云端智能体的「助手昵称/角色介绍」**，需在小智控制台改（见 §6） |

---

## 2. 源码与配置在哪

```
firmware/xiaozhi-esp32/                 # 源码（v1.9.1 + 本板配置）
├── main/boards/esp32s3-ai-main/       # 新增板级配置（本板）
│   ├── config.h                       # 引脚：ES8311 / ST7789 / 按键 / LED
│   ├── config.json
│   └── esp32s3_ai_main.cc             # 板级初始化
├── main/Kconfig.projbuild             # 增加 BOARD_TYPE_ESP32S3_AI_MAIN
├── main/CMakeLists.txt                # 增加板型映射
├── sdkconfig.defaults.custom          # 自定义唤醒词构建配置
├── build_aimain.sh                    # 编译
└── flash_aimain.sh                    # 烧录
```

板级引脚（从原理图 `hardware/vendor/原理图/ESP32S3-AI-MAIN_V1.1(303ESP32AI7).pdf` 与上游同款
`lc-s3-wifi-1.54tft` 交叉确认）：

| 功能 | GPIO |
|---|---|
| ES8311 MCLK / WS / BCLK | 5 / 2 / 4 |
| ES8311 DIN（ESP 收）/ DOUT（ESP 发） | 3 / 1 |
| ES8311 I2C SDA / SCL | 7 / 6 |
| 功放 NS4150B 使能（CTRL） | 8 |
| TFT DC / CS / CLK / MOSI / RST / BL | 10 / 13 / 14 / 15 / 16 / 21 |
| BOOT / 音量+ / 音量- | 0 / 40 / 39 |
| RGB LED | 46 |

自定义唤醒词关键配置（`sdkconfig.defaults.custom`）：

```
CONFIG_BOARD_TYPE_ESP32S3_AI_MAIN=y
CONFIG_USE_AFE_WAKE_WORD=n
CONFIG_USE_CUSTOM_WAKE_WORD=y
CONFIG_CUSTOM_WAKE_WORD="ni hao xiao bu"     # 拼音，空格分开，小写
CONFIG_CUSTOM_WAKE_WORD_DISPLAY="你好小布"
CONFIG_CUSTOM_WAKE_WORD_THRESHOLD=8           # 灵敏度 %（越小越灵敏；实测 8~10 可用）
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions/v1/16m_custom_wakeword.csv"
CONFIG_SR_MN_CN_MULTINET7_QUANT=y
CONFIG_SR_WN_WN9_NIHAOXIAOZHI_TTS=n
```

> 原理：WakeNet 是「固定关键词声学模型」，没有「你好胶布」模型；小智固件的自定义唤醒词走
> **MultiNet 命令词识别**（中文 MultiNet7 模型 + 运行时 FST），所以必须重编固件并换 model 分区。
> 官方文档：<https://docs.xiaozhi.me/zh/development/wake-words.html>

---

## 3. 编译与烧录

依赖：macOS + **ESP-IDF v5.4.4**（`~/esp-idf-v5.4.4`，含 xtensa 工具链、cmake、ninja）。
首次安装一次即可：

```bash
git clone -b v5.4.4 --depth 1 --recursive https://github.com/espressif/esp-idf.git ~/esp-idf-v5.4.4
cd ~/esp-idf-v5.4.4 && ./install.sh esp32s3
python3 tools/idf_tools.py install cmake ninja   # 可选工具，install.sh 默认不装
```

编译 + 烧录：

```bash
cd firmware/xiaozhi-esp32
bash build_aimain.sh          # 首次会拉组件、生成 sdkconfig，约 5–10 分钟；之后增量 1–2 分钟
bash flash_aimain.sh          # 自动找 /dev/cu.usbmodem*，整片写入 bootloader/分区表/model/app
```

只改 app（例如调唤醒阈值）时更快：

```bash
. ~/esp-idf-v5.4.4/export.sh
export SDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.esp32s3;sdkconfig.defaults.custom"
idf.py -p /dev/cu.usbmodem1101 app-flash
```

> 首次构建为了适配公共组件仓库，改了 `main/idf_component.yml` 里
> `espressif2022/image_player` 的版本约束（`==1.1.0~1` → `~1.1.0`），否则组件解析失败。

---

## 4. 串口验收

```bash
# 抓串口（115200），然后对板子说「你好小布」
python3 - <<'PY'
import serial,glob,time
s=serial.Serial(glob.glob('/dev/cu.usbmodem*')[0],115200,timeout=0.2)
t=time.time()
while time.time()-t < 30:
    d=s.read(512)
    if d: print(d.decode('utf-8','replace'), end='')
PY
```

11 月 24 日的旧版本示例：

```
I (7520) CustomWakeWord: multinet: mn7_cn
set det threshold to 0.080000
Command 1: ni hao jiao bu
I (593060) CustomWakeWord: Custom wake word detected: command_id=1, string= ni hao jiao bu, prob=0.104165
I (593070) Application: STATE: connecting
I (593360) Application: Wake word detected: 你好胶布
I (593440) Application: STATE: listening
I (593590) Application: >> 你好胶布
I (593620) Application: STATE: speaking
I (594740) Application: << 哈哈，又叫我胶布啦……
```

### 灵敏度调整

- 漏唤醒（说了没反应）：把 `CONFIG_CUSTOM_WAKE_WORD_THRESHOLD` 从 8 降到 6/5，重新 `idf.py build` + `app-flash`。
- 误唤醒（没人叫也触发）：升到 12~15。
- 实测用户真声命中概率约 0.10（阈值 20 时**会漏**，这就是最初「说了没反应」的原因）。

---

## 5. 备份与恢复原厂固件

烧录前已整片备份（16 MiB）：

```
firmware/backup/aiman-stock-before-wakeword-16m-20261124-005040.bin
```

恢复（会覆盖 bootloader/分区表/固件/model/NVS，恢复成原厂 1.9.1）：

```bash
python3 -m esptool --chip esp32s3 -p /dev/cu.usbmodem1101 -b 460800 \
  write_flash 0x0 firmware/backup/aiman-stock-before-wakeword-16m-20261124-005040.bin
```

> 只恢复 app 不恢复分区表会导致型号/布局不匹配；请整片恢复。

---

## 6. 助手昵称「小智」怎么改成「胶布」

唤醒词和助手昵称是**两件不同的事**：前者在固件里（已改好），后者在小智云端智能体配置里。
官方文档：<https://docs.xiaozhi.me/zh/console/>

1. 打开 <https://xiaozhi.me/console>，用绑定这台设备的账号登录；
2. 找到该设备所属的**智能体**，点「配置」；
3. 「角色与声音」里把**助手昵称**改成 `胶布`；需要的话打开「自定义角色介绍」，写明“你是胶布……”；
4. 保存，让设备开始一轮新对话验证（不要只看试听）。

> 官方文档明确写了：**助手昵称是对话角色名称，不会改变设备的离线唤醒词**。所以之前出现的
> “我说你好胶布它自称小智”并不是唤醒词没改，而是昵称还是小智。

---

## 7. 注意

- 设备固件版本号仍是 `1.9.1`，当前 OTA 检查显示「已是最新」；如果以后官方推送新版本并自动 OTA，
  **自定义唤醒词会被覆盖**，需要重新烧录本固件（或先关闭自动更新）。
- 本固件只改了唤醒方案（WakeNet→MultiNet），其余小智功能（配网、绑定、对话、MCP、屏幕表情）保持原样。
- 唤醒词识别是离线的 MultiNet，抗噪不如原厂 WakeNet，建议在安静环境先验收，再按 §4 调阈值。
```
