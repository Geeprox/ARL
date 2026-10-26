# 返回值和错误示例

以下 ID、哈希及模型均为合成值，只说明协议，不是可调用凭据或真实执行证明。

## 套餐解析

```json
{
  "schema_version": 2,
  "request_id": "c65d163b-d81f-48fe-8ab0-997b02e36cda",
  "accepted": true,
  "resolution_only": true,
  "execution_authorized": false,
  "queue_admitted": false,
  "resolution_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "valid_for_ms": 30000,
  "requested": {"kind": "package", "package_id": "medium"},
  "package_revision": 8,
  "execution_binding_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "resolved_details": null,
  "reasons": []
}
```

模型盲应用不需要 resolved_details；显式选择或有诊断权限时，该字段包含 model / reasoning_effort / service_tier。内部解析记录必须始终包含这三项。实际返回还须回显会话、目录及内容哈希，防止串任务。

## 已受理与已完成

受理返回 job_id、request_id、冻结的 execution_binding_sha256、package_revision、accepted_at、state=queued。不能把 accepted 画成“生成完成”。

完成返回同一组绑定字段及 state=succeeded、output_sha256、输出或应用私有内容引用。execution_evidence 表示上游 thread/turn、实际选型/强度确认和终态已由 ARL 核验；owner 详细审计保留原始模型标识。生产 SDK 必须拒绝 simulated=true，不能把合成 fixture 当作实际模型执行。

取消回执分别记录 cancel_requested、upstream_interrupt_ack、terminal_status；不能只收到中断 RPC ACK 就称上游已停。未确认终态为 needs_review，不自动重试。

## 配额投影

```json
{
  "quota_policy": "inherit_account",
  "local_lifetime_call_limit": null,
  "local_remaining_calls": null,
  "admitted_requests_total": 7,
  "upstream_limits": {
    "available": true,
    "source": "account/rateLimits/read",
    "observed_at": "2026-10-24T00:00:00Z",
    "buckets": [{"limit_id": "example-bucket", "used_percent": 1, "window_minutes": 10080, "resets_at": "2026-10-24T00:00:00Z"}]
  }
}
```

这里只是形状示例。账户桶按实际上游原样投影；不可从 admitted_requests_total 推断当前账户使用量。quota.available=false 时 windows 不应被假填为 0%。

## 有限错误分类

| 错误 | 含义与恢复 |
| --- | --- |
| app_identity_unverified / method_not_authorized | 身份或能力不成立；不创建 job |
| catalog_changed / resolution_expired | 仅未受理请求重新 discovery/resolve；已受理任务先 lookup |
| package_config_conflict | 设置基于过期 revision；读最新配置后由所有者重新编辑 |
| package_unavailable / provider_model_unavailable / provider_effort_unavailable | 组合当前不可执行，不静默换型 |
| fast_authorization_required | 支持 Fast 不等于被授权使用 |
| request_conflict / content_hash_mismatch | 原 ID 意图变更或实际内容不符；拒绝 |
| queue_full / deadline_not_authorized / payload_too_large | 本地资源策略；不是账户额度不足 |
| local_policy_limit_reached | 用户主动配置的本地限额，带实际作用域与窗口 |
| upstream_quota_exhausted | 仅依据明确上游分类，返回可获取的窗口信息 |
| upstream_rate_limited / upstream_capacity_busy | 上游限流或拥堵，不擅自解释为余额不足 |
| unsupported_limit | 当前无法落实 token/金额等限制；不忽略该限制执行 |
| provider_preferences_mismatch / completion_unverified | 实际执行证据不匹配，不发布“成功”结果 |
| result_expired | 只剩幂等墓碑，不能把旧 ID 当新任务重新计费 |

错误响应保留 request/job 相关性和 finite code；面向客户端不返回原始上游 stderr、提示词或认证信息。
