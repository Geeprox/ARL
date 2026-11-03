# 删除提醒的原生回执

v3 产品记录用 `task.state=saved_local` 表示本机结果已持久化。删除的业务回执另用 `code=deleted_local`、`persistence=deleted_local` 及精确的 `deletion` 字段证明原对象的本机删除；它不声称云端同步完成。

136 的首次删除虽然已在 helper 成功并保存原结果，Control 的 `admitProductReply` 却把所有 `saved_local` outcome 的 persistence 都要求为 `saved_local`，因此正确的删除回执被拒为 `invalid_response`。原任务的后续 status 与精确对象 get 已分别证明冻结删除回执存在、原对象返回 `reminder_not_found`；没有重放删除。

Control 现在对首次 submit 与随后 status 的成功任务使用同一验证：根据冻结请求及原 submit frame 判定删除，核对原 operation ID、list/reminder/revision、target、请求摘要与两个 `deleted_local` code。删除只接受 `deleted_local` persistence 和删除证明，不接受伪造的存活 reminder；create 等保存操作仍要求 `saved_local`。

先前 Owner delete-flow fixture 的 send 直接返回已解码 DTO，绕过了真实 native admission；它现在也将 encoded reply 送入 `admitProductReply`。`RemindersProductBoundaryTests` 另用真实 helper 和合成 repository，覆盖首次删除、原 status、错误 persistence/code/ID/list/revision/target/摘要、不同原请求及原 create 的回归。它不读取正式提醒，不执行 EventKit 或申请权限。

```sh
python3 -B script/check_apple_direct_execution.py \
  --native-build build/your-current-verified-native-sdk \
  --suite RemindersProductBoundaryTests \
  --suite AppleOwnerDeleteFlowTests \
  --suite AppleOwnerStatusFlowTests \
  --suite AppleOwnerDefaultFlowTests
```

本次生产改动只涉及 `RemindersNativeClient.swift`；SDK、Mio、helper 与公开 schema 均不改变。
