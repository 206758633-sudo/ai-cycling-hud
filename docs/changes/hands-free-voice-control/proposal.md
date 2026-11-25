## Why

骑士控屏页展示手填订单、点按确认和演示动作。用户确认控屏应由小布对话驱动，手机用于展示进度和结果。

## What Changes

- 骑士 iOS 控屏页自动显示语音自提任务、追问和回执。
- 小布按已明确的语音意图发起自提。遇到已识别的缺失规格，播报实际可选项，接受明确口头回复后继续。
- 到结算时播报已核对信息和付款状态。付款沿用美团结算流程。

## Capabilities

### New Capabilities

- `voice-control`：免手发起、语音补充规格和只读控屏。

### Modified Capabilities

## Impact

骑士内嵌页面、iPhone 自提回执、现有订单 API 和小布 MCP 工具。
