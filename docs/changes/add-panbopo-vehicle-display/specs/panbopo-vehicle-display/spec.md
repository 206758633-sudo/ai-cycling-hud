## ADDED Requirements

### Requirement: Show Knight cycling navigation on the PANBOPO display
PANBOPO 车载固件 SHALL 接收骑士现有 BLE 导航报文，在 GC9A01 显示下一指引。

#### Scenario: A complete direction is received
- **WHEN** 手机发送同一条完整、有序的导航报文
- **THEN** 显示方向和距离

#### Scenario: A route message is lost or expires
- **WHEN** 分片缺失、重复且序号异常、蓝牙断开或上一条指引过期
- **THEN** 不使用残缺指引，并在连接或有效期失效时清除旧方向
