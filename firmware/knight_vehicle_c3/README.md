# PANBOPO ESP32-C3 车载导航屏

适用于本次核对的 PANBOPO ESP32-C3 16 MiB 版本。出厂板型源码标识为 `PANBOPO/lichuang_c3_dev_board.cc`，使用 360×360 SPI LCD。屏幕引脚由出厂固件和运行时 GPIO 矩阵共同核对。

| 信号 | GPIO |
| --- | --- |
| SPI SCK | 1 |
| SPI MOSI | 2 |
| DC | 0 |
| CS | 21 |
| 背光 | 20，高电平点亮 |
| LCD 复位 | 软件复位 |

蓝牙名称为 `ROADLINK-VEHICLE`，复用骑士的 NUS 服务。车载屏支持转向、距离、路线轮廓、当前位置、终点和推荐信息。导航期间订单卡短暂覆盖路线，约 3 秒后恢复指引。

| 命令 | 作用 |
| --- | --- |
| `D:方向\|距离` | 更新转向及距离 |
| `R:<路线ID>\|<折线>` | 更新路线轮廓，处理后通知 `A:R<路线ID>` |
| `L:<路线ID>\|<位置>\|<剩余米数>` | 更新当前位置及剩余距离 |
| `K:<路线ID>` / `C:<路线ID>` | 保持 / 清除当前路线 |
| `O:<事件ID>\|<标题>\|<主行>\|<副行>` | 显示门店推荐或点单信息 |
| `PING` | 查询连接状态，返回 `PONG` |

完整消息按 NUS 写入分片重组。订单卡支持 UTF‑8 中文及重复事件去重。查看 [协议文档](../../docs/hud/ai-hud-protocol.md) 和 [路线变更说明](../../docs/changes/add-wireless-cycling-route/design.md)。

构建环境为 Arduino ESP32 Core 3.3.12、Adafruit GFX Library、Adafruit BusIO 与 U8g2_for_Adafruit_GFX。

```sh
arduino-cli compile \
  --fqbn 'esp32:esp32:esp32c3:CDCOnBoot=cdc,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB' \
  --output-dir /tmp/knight-vehicle-c3 firmware/knight_vehicle_c3
```

本机烧录验证使用出厂分区表的 `ota_0` 应用槽 0x100000。应先读出备份并核对目标设备与活动槽，再仅写入编译产出的应用 bin。不同板型或出厂分区布局不得复用该地址。现有 ESP32-S3 固件继续由其各自目录构建。
