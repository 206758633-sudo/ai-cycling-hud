## ADDED Requirements

### Requirement: Display voice-triggered operations
骑士 SHALL 在控屏页展示实际语音自提任务的状态和回执。

#### Scenario: Voice intent is accepted
- **WHEN** 小布通过语音提交自提任务
- **THEN** 控屏自动显示待处理、执行中或实际结果，流程无需手填或点按确认

### Requirement: Continue an explicitly clarified pickup
系统 SHALL 仅在加购前且用户明确同意已核实的替代糖度时续办该笔任务。

#### Scenario: A verified shop only offers no added sugar
- **WHEN** 用户要求无糖且门店只提供不额外加糖、半糖和全糖
- **THEN** 小布播报可用糖度并追问，骑士等待语音答复

#### Scenario: The rider accepts the offered option
- **WHEN** 用户明确接受不额外加糖且任务仍在等待该答复
- **THEN** 骑士继续准备原请求并保留其他已确认字段

#### Scenario: Checkout is ready
- **WHEN** 骑士核对完结算页
- **THEN** 小布播报门店、商品规格、金额和待付款状态
