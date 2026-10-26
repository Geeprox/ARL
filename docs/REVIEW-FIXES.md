# 独立审查修复 · 2026-09-30

审查报告 `/Users/<user>/Documents/Codex/2026-09-30/task-7/ARL-quality-review.md` 提出1项条件P1、4项P2。全部已作代码修复与专项回归；默认无Apple/旅行私有transport，从未发生真实私有数据泄露。修复版本0.1.1，RPC保持arl/1，存储schema升级v2。

| 确认问题 | 根因与代码修复 | 回归 |
|---|---|---|
| P1 历史私有结果在descriptor删除/降级后失去gate | jobs持久化requires_identity、permissions、tool_contract及提交时identity_authorized；查询取历史与当前要求的保守组合，unknown descriptor也要求验证；重复submit读旧结果同样校验。v1无分类记录保守视为private/unverified | private_result_survives_descriptor_removal_and_security_downgrade、legacy_migration_treats_unclassified_results_as_private，覆盖get/cancel/resume、重复key及重启 |
| P2 revoke/re-register竞态 | 登记拥有唯一generation；process身份查验后在同锁内确认还是原登记对象，revoke后不能返回旧授权，旧查验也不能删除新登记 | verifier_revoke_and_reenroll_are_linearized（阻塞查验→revoke→重登记→释放，旧结果None，新记录保留） |
| P2 非幂等副作用后异常failed | 明确started边界；handler开始后的所有非幂等Fault、结果编码/超限和未知异常均needs_review；只有preflight无副作用故障可以failed | effect_then_any_fault_is_needs_review，模拟副作用+超大结果/ transient均仅一次、needs_review，无新key重试 |
| P2 升级契约/幂等漂移 | Tool显式version；摘要包含name/version/schema/permissions/security/idempotency；恢复检查queued/running/needs_unlock持久摘要，变化或未知转needs_review；执行与重试同时要求原/当前幂等且摘要一致 | upgrade_contract_and_idempotency_changes_do_not_execute，覆盖幂等变写、版本改变、权限变化，没有执行新handler |
| P2 HTTP非整体deadline / shutdown释放活跃资源 | local_json经固定短命arl.http_worker执行，parent monotonic deadline到期kill+wait，慢速headers/body无法无限续时；嵌入Runtime若grace后worker仍活，继续持DB/socket/instance lock直到真正退出；RPC读取整体5秒、32连接cap、close等待handlers后才关DB | http_slow_drip_has_absolute_deadline、shutdown_keeps_resources_until_worker_exits，验证超时、closed=false/锁busy/DB仍开，以及退出后才能重新获锁 |

实际执行：`PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=. python3 -m unittest tests.test_review_regressions tests.test_runtime tests.test_identity tests.test_providers tests.test_native -v`；**35 tests / 10.689s / OK / 无skip**。此前28测试通过是历史覆盖证据，不涵盖这轮新边界。测试只有synthetic数据、临时Unix socket、HTTP double、编译helper授权状态，无推理/Apple数据/生产服务访问。

### 授权的生命周期

Peer验证是在RPC授权点线性化：撤销阻止其后的新RPC与私有结果查询，不追溯撤销已经完成授权的请求。成功提交的任务拥有持久的、仅针对原owner/tool/args/key的scoped授权；允许调用方退出后后台执行。它不是“verifier对象存在就自动授权”：敏感任务还须持久identity_authorized=true、当前verifier已配置、当前app白名单及契约不变。v1无此证据的任务不会自动补授权。

撤销进程登记本身不等于取消已提交工作；host应另发取消请求，或者移除app/tool policy阻止未开始执行。真实写入取消仍不宣称undo，in-flight不确定性仍needs_review。部署前必须明确此语义，不能把易失PID登记当长期全权限凭据。

默认CLI继续禁用敏感transport。v1迁移保守保留原数据，旧任务可能needs_review、旧结果可能因未验证而不可读；没有自动降级、自动删除或静默重放。需要显式可信host核对，不能通过客户端自报身份迁移授权。

每个HTTP请求的绝对deadline包括启动、请求、headers/body读取及结果回收；provider前置health/tag发现另有1秒deadline，本地推理请求30秒。超时关闭的是HTTP helper连接，不保证远端服务已停止推理或撤销外部操作，因此非幂等完成任务仍needs_review。自定义adapter可能无限阻塞时，runtime保持资源而不假装closed；可信supervisor可结束它掌握的进程，不能任意kill其他进程。
