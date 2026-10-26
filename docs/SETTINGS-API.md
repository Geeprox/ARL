# Settings 只读 API（arl/1 增量）

独立 app ID 为 `settings`。默认方法白名单仅 `health`、`ready`、`overview`；tools/providers 为空，提交/待办/输出预算为 0。不能 submit/get/cancel/resume/wake/poll_wakes/stop，也不能直接 providers/capabilities。即使部署未安装 peer verifier，该方法白名单仍生效。其他 app 的已有 arl/1 方法与返回结构保持兼容；overview 仅为 settings 开放。

请求是一条换行结尾 JSON，走现有私有 Unix socket：

```json
{"protocol":"arl/1","app":"settings","method":"overview","params":{}}
```

成功：`{"protocol":"arl/1","ok":true,"result":<overview>}`；失败保持 `{"protocol":"arl/1","ok":false,"error":{"code":"..."}}`。params 必须为空；不存在 owner/filter/path 参数。精确 result schema 见 [settings-overview.schema.json](settings-overview.schema.json)。schema_version=1 与数据库 v2 分开版本。

overview 在 live 但尚未 ready 时可读。health.live/ready 指当前运行进程；没有 OS 锁屏判定。queue.available=false 表示尚无打开的 store，此时 counts 全 0，不能解释为历史队列为空。counts 是所有 app 的七类状态总计，不按 owner 分组，没有 ID、标题、tool、args、result、error、时间或审计行。budgets 只包含固定策略上限，不包含每 app 使用量或任务内容；max_calls 为持久累计新任务上限，去重不再扣。

providers 只展示筛选过的名称、模型标识、availability、paid、inference_policy 和固定 allowed_apps；没有 endpoint、路径、环境、异常 reason 或 Key。模型列表来自已有本地只读 health/tags，不下载模型、不推理。`explicit_route_only` 仍必须通过 caller 的 app/tool/provider 白名单与预算；不是 UI 可调用模型的授权。availability 与 inference_policy 独立，禁用的本地 provider 也可显示只读发现结果。Codex/Jev paid route 始终 disabled。

capabilities 仅给名称、availability、identity_gate、authorization_gate；无参数 schema/对象列表。`adapter` 仅表示 transport 已配置，`authorization_not_checked` 明确未宣称 OS 授权。`permission_required` 表示默认 Apple bridge 未启用；overview 不触发 TCC、不读 Apple 数据、不做自动配置。`identity_verifier_configured` 也不等于该客户端已验证。

默认 read permission 是显式的同 UID 公共元数据例外：socket peer UID 仍须与运行用户一致；服务端仅当 owner=settings、policy.public_metadata=true、method 属于上述三项且 verified_app=None 时，允许未验证读取。它不是身份凭据，也不给私有工具授权。若 verifier 已把连接验证为别的 app，则不能声明 settings。host 可关闭 settings 的 public_metadata（无 RPC 修改入口）；public_metadata 不能豁免其他 app 或任何写/对象方法。未验证声明 tisra/friday 仍按原严格 verifier 拒绝。默认开发无 verifier 时，原 app ID 仍是逻辑分区，生产私有能力继续要求真实 transport 验证。

UI 应被动连接固定安装 home，使用 health/overview；缺少服务或 disabled 时显示相应状态。不要用 UI 自报 tisra、安装 launchd、修改 disabled、调用 RuntimeLauncher 或自动启权限。UI 的启动/停用/配置编辑均不在本 API 范围。接入 Swift SDK：`ARLClient(home: ..., app: "settings")` 的 rpc 方法；具体 SDK 类型签名以 examples/ARLClient.swift 为准。

回归在 tests/test_settings.py：严格 verifier 下未验证 settings 读取、所有对象/写方法拒绝、伪造 app/owner、撤销公共读取、flag 不能豁免写、启动未 ready 与输出字段脱敏。
