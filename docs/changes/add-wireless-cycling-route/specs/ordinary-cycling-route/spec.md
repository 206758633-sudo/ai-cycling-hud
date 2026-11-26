# 普通骑行导航

## ADDED Requirements

### Requirement: 后台下发普通骑行目的地

骑士 SHALL 通过 Wi-Fi 领取普通骑行任务，使用高德骑行 SDK 规划路线并回传实际启动状态。

#### Scenario: 验证黄村地铁站 B 口

- **WHEN** 后台下发广州天河区黄村地铁站 B 口，iPhone 空闲且地点唯一核验
- **THEN** 骑士规划并启动 GPS 骑行，后台显示 GPS 启动回执

### Requirement: 车载屏路线同步

骑士 SHALL 向目标车载屏同步当前路线轮廓、位置和下一条转向。

#### Scenario: 开始骑行并重新连接

- **WHEN** 骑行路线启动或车载屏重新连接
- **THEN** 屏幕显示当前路线和指引，路线结束或连接丢失时清除旧提示
