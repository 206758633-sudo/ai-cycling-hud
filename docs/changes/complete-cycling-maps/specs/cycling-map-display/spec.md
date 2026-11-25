## ADDED Requirements

### Requirement: Navigate to a verified destination
骑士 SHALL 在普通骑行和美团自提入口中共享高德骑行路线会话。地图 SHALL 显示选定地点、实际路线与骑行距离。

#### Scenario: Search returns multiple places
- **WHEN** 目的地关键词有多个匹配地点
- **THEN** 使用区县或地址区分结果，等待用户选定对应地点后再规划

#### Scenario: A route is accepted
- **WHEN** 高德返回路线且用户确认开始
- **THEN** 手机显示真实导航，并向车载屏同步同一会话的当前指引

#### Scenario: Planning is unavailable
- **WHEN** 定位权限、网络或高德算路发生错误
- **THEN** 地图显示失败原因和重试入口，车载屏停止显示该路线的旧指引

### Requirement: Draw recorded rides and check-in locations
骑士 SHALL 在自由骑行期间记录有效位置，并在个人记录和打卡地图显示可核实的数据。

#### Scenario: Free riding starts or ends
- **WHEN** 用户开始或结束自由骑行
- **THEN** 开始记录并显示真实轨迹，结束后保存本次轨迹与统计，车载屏显示自由骑行状态或结束

#### Scenario: A previous record contains no coordinates
- **WHEN** 用户打开无坐标的旧记录
- **THEN** 显示该记录的可用信息及轨迹缺失状态

#### Scenario: A rider views a check-in point
- **WHEN** 用户查看已选择的可核实地点
- **THEN** 地图显示该地点的图钉，并按真实位置与用户确认更新打卡状态

### Requirement: Keep the vehicle display in sync
车载屏 SHALL 显示骑士当前真实导航会话的转向、距离及有效状态。

#### Scenario: The link is interrupted and restored
- **WHEN** 蓝牙断开后重新连接
- **THEN** 断开时清除指引，连接后同步仍有效的最新状态

#### Scenario: Navigation reroutes or ends
- **WHEN** 偏航重算、指引超时、用户结束或到达目的地
- **THEN** 以当前状态替换先前的转向与距离

#### Scenario: Demo data exists in the App
- **WHEN** 骑士展示演示地图或储存的示例数据
- **THEN** 演示数据不会发为真实车载导航指引
