# 淘宝连接状态与安全诊断

`protocol_ready` 只表示本机官方端点和协议已核验。淘宝 `connection_status` 正常返回该状态时，Mio 将其作为成功的状态查询返回；`ready=false`、`login=not_checked` 保持不变。此例外不适用于搜索或其他业务工具，也不改变网易云状态映射。

业务失败保留本次已核验的端点与已发现能力。后续端点检查确实变化时，`endpoint_verified=false`、能力列表清空，并通过 `phase=endpoint_recheck` 标明原因。能力已发现不代表已登录或业务成功；所有失败仍 `ready=false`，不返回部分商品结果。

隐私拦截仍使用原 `privacy_held` 错误类型和原校验规则。响应新增固定的 `phase`、`reason_code` 和随机 `diagnostic_id`。每次操作隔离一个诊断上下文，失败时仅输出一条封闭事件到 macOS unified logging：subsystem `local.arl.control`、category `taobao-diagnostic`、前缀 `taobao_diagnostic_v1`。

日志仅含 schema、随机 call_id、固定 phase 和固定 reason_code；不接收实际字段值、页面正文、商品标题、账号、URL、关键词、token、cookie、原始响应或错误描述。回复封装、公共页面范围、分页完整性、首张标题、标题一致性、商品投影/清理和本地 journal 的隐私拒绝分支均记录固定原因。原始响应不落盘。

新增诊断不能追溯旧版丢失的错误分支。2026-10-09 02:23 UTC 的旧 `privacy_held` 仍不能据此确定原因。外层连接器的 `INVALID_ARGUMENT` 映射不在本修复范围内。

定向验证使用实际 TaobaoRuntime、MioReadOwnerAdapter 和 TaobaoConnectionState consumer；传输为合成 fixture，不调用真实淘宝、桌面或账号。通过源码测试不等于已安装链路或真实搜索验收。
