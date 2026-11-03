# 提醒产品原任务状态

`mio_reminders_product_operation_status` 只查询原 `task_id`，不会恢复一次效果、调用 EventKit 或生成替代 UUID。它使用 v3 产品记录的实际有限状态：`pending`、`saved_local`、`rejected`、`unknown`；旧任务 DTO 的 `draft`、`attempting` 不扩充到这个合同中。

缺记录曾由 helper 返回 `action=status`、`outcome=refreshed`、`code=operation_missing`，却被公开成功回执验证覆盖为 `invalid_arguments`。Control 现在将这类精确观测投影为 `state=operation_missing`。Mio 只在原 task ID、schema/capability、当前 status 响应、有限 code、有效业务日志及无 task/result 元数据均一致时保留它，并返回 `isError=true`。它不表示保存成功，也不授予自动重放许可。

已有记录在通用错误状态处理之前核对原 `task_id`、冻结请求 JSON/SHA、派生 operation ID、helper/policy 绑定及 state/code 一致性。合法 `pending`、`unknown`、`rejected` 保留原记录、原 code 与 `isError=true`；错误 task/hash/state 不作为恢复证据。`saved_local` 仍需通过原有完整效果回执验证，才能返回成功。

通过现有合成原生执行入口可单独验证真实 Helper → Controller → Owner 的观测，再把同一回执交给真实 Mio adapter，覆盖缺记录、四种有效状态、错误 ID/摘要/状态/日志、损坏的私有合成 journal 和零自动重放：

```sh
python3 -B script/check_apple_direct_execution.py \
  --native-build build/your-current-verified-native-sdk \
  --suite AppleOwnerStatusFlowTests
```

该入口要求原 SDK 构建收据及当前源码 SHA 一致；`--suite` 只缩小合成验收范围，不改变生产输入或省略其身份校验。默认完整入口也包含这组。测试材料属于独立临时目录，不读取正式提醒或改写原用户任务记录。
