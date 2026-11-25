## ADDED Requirements

### Requirement: Report verified pickup progress
骑士 SHALL 按实际执行阶段回报美团自提任务。小布 SHALL 播报已经核对的结果，骑士控屏 SHALL 显示同一结果。

#### Scenario: Cart opens but checkout has not been verified
- **WHEN** iPhone 核实已加购但未取得结算页
- **THEN** 回执报告加购与未到结算，续办不会重复加购，系统不会以购物车价格作为核实结算实付

#### Scenario: A verified checkout is available
- **WHEN** iPhone 已核对同一门店及自提结算信息
- **THEN** 回执包含真实分店、品项规格、金额、取餐地址及待付款状态

### Requirement: Start and confirm GPS navigation
骑士 SHALL 使用高德骑行 SDK 开启已核实分店的 GPS 导航，并反馈启动结果。

#### Scenario: Navigation is requested with permissions granted
- **WHEN** 用户听完回执并明确说「开始导航」，且分店、路线和定位均已核对
- **THEN** 骑士启动 GPS 骑行导航，等待 SDK 回调，再更新语音回执及车载屏导航状态

#### Scenario: Navigation cannot start
- **WHEN** GPS 导航未启动或当前路线未核实
- **THEN** 骑士反馈实际阻塞阶段，并保留已核对的订单状态
