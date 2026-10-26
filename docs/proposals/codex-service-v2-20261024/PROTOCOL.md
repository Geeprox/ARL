# ARL 暴露 Codex 服务：协议 v2 设计

日期：2026-10-24（Asia/Shanghai）。状态：协议提案及机器可校验示例；不是完整 v2 服务已上线的声明。现有 NAS 两应用的真实执行证据仍见 ../arl-adapter/。

## 1. 要解决的问题

NAS 接入使用了旧的 `codex.text.plan.v1` 固定模型接口，另设 32 次累计受理上限。它实际一直使用现有 Codex 账号；“剩余 25 次”只是 32−7，不是账户剩余次数。Codex 账户窗口不能换算为固定调用次数。

ARL 已有 AppConnections、ApplicationModels 五档套餐、模型/强度校验、持久任务与终态回执。v2 在这些契约上扩展，不另建身份协议或推理调度器；不改 Tisra 现有 v1 字段含义。

## 2. 用户在 ARL 配置五档套餐

稳定 ID 保持现有 low / medium / high / very_high / highest，显示名默认低 / 中 / 高 / 极高 / 最高。**每档都是用户可独立配置的模型＋思考强度组合**，不再把五档等同于写死的 low→max effort 映射。模型和强度下拉来自当前客户端/账号实际公布的模型目录，再与应用允许范围和文本执行策略取交集。允许不同套餐配成同一组合，界面如实显示，不虚构五档一定能力递增。

ARL 设置页：五行，每行「套餐名称｜模型选择｜该模型支持的思考强度」。模型改变后，原强度不支持时标为待选择，不能静默改档。保存对五行做原子校验，并使用 `base_revision` 乐观锁；配置冲突返回 package_config_conflict，不覆盖他人修改。显示当前目录时间、不可用原因；目录暂不可用时保留已保存配置，新任务停止受理，不自行换模型。

配置是 host-only 设置：消费应用只有使用套餐的权限，不能修改全局套餐或登记未知模型。所谓“自定义模型”是选择当前账号可用的模型标识，不能由客户端指定 API endpoint、OAuth 凭据、执行文件、工具或任意第三方服务。未来自定义 provider 另设独立接入权限。

套餐配置变更生成不可变 revision。任务**受理时**冻结实际模型、强度、套餐 revision 和策略；配置修改只影响后来受理的任务。已受理的排队/执行任务沿用原组合；权限撤销和模型实际失效仍独立检查。

## 3. 两种选择方式

### 显式选择

`selector={"kind":"model","model":"<catalog ID>","reasoning_effort":"<supported ID>"}`。

强度可省略，ARL 在解析阶段取该模型的目录默认值，并在回执中固定。未知模型、不支持的强度直接拒绝。不把某个模型的 high 强行解释为另一个模型的同等质量，也不硬编码全局 effort 枚举。

### 只指定套餐

`selector={"kind":"package","package_id":"medium"}`。

应用无需知道模型或强度，也不负责将套餐映射成这些参数。模型盲客户端收到套餐 ID、配置 revision 和执行绑定摘要即可完成任务相关性校验；有诊断权限的客户端可额外看到解析结果。ARL 的所有者审计始终保存实际模型、强度及上游确认信息。

两种 selector 严格互斥。v2 不允许“套餐＋偷偷附带一个模型/强度覆盖”；需要覆盖时使用显式模式。旧 v1 已有的显式覆盖语义保持原样。

## 4. 必须分开的四个维度

1. **套餐**：ARL 用户保存的模型与思考强度组合。
2. **账户订阅与配额**：现有 Codex 账户及其真实服务端窗口。
3. **本地排队优先级**：background / explicit / interactive，取决于应用授权。
4. **上游 service tier**：default / fast；Fast 的支持和使用授权单独校验。

最高套餐不自动取得 Fast、队列抢占、工具调用或多代理权限。即使目录公布 ultra，若当前文本执行策略不允许其要求的多代理能力，也应明确不可用，不能放开工具来凑兼容。

## 5. 握手、目录与请求流程

传输继续使用 `arl/1`，复用 connection.open → challenge/nonce → connection.confirm 和续期。身份来自真实对端/已登记进程或经核验的 NAS 应用委托，不能相信请求体里自报的 app。

建议能力拆分为读取套餐、读取模型明细、文本执行、读取自身任务；账户整体使用量和套餐写入为所有者能力。`discovery` 不产生模型推理，目录刷新为显式元数据操作。

| 方法/工具 | 行为 |
| --- | --- |
| application.models.discover.v2 | 返回应用范围内的套餐、允许的选择模式、可选模型明细、目录版本、限制及能力；不是执行许可 |
| application.models.request.v2 | 根据 selector 和内容哈希解析参数，返回 30 秒 resolution lease；不是排队成功 |
| submit，tool=codex.text.generate.v2 | 校验并原子绑定 resolution、原始内容、现有应用权限和持久任务；返回 job_id |
| codex.requests.lookup.v2 | 用当前认证应用＋request_id 找回受理结果；不重新推理 |
| get / cancel / heartbeat | 复用现有方法；取消请求、上游中断确认、终态分别记录 |
| codex.account.usage.v2 | 有权限时读取当前账户使用窗口和观察时间，不触发充值或重置 |

请求使用统一 request_id、content_sha256、task_kind、selector、队列与执行超时、输出字节上限。内容哈希为确定性 UTF-8 编码 `{"messages":[...]}` 的 SHA-256（Unicode 不做隐式归一化；重复 JSON 键、NaN 和非文本 part 拒绝）。SDK统一实现编码，避免各消费端自行猜测。

`catalog_version` 为应用可见模型能力、套餐 revision 及执行策略的规范哈希，不含每秒变化的时间戳或账户使用百分比。目录和套餐版本改变应更新该哈希；配额观察值有独立时间与快照版本。

新增解析必须使用当前目录；旧 lease 过期或目录变更时，未受理请求需要重新解析。**任务一旦已受理，重复请求先查原任务，不因当前目录变化重新选型或创建新推理。** resolution 在受理事务中单次绑定 job；排队时间超过 30 秒不会使已绑定 job 失去选型。

请求示例与 JSON Schema 见本目录。模型目录代表客户端/账号公布的能力，不保证某次上游请求一定有额度或容量；实际受理、模型/强度确认与执行完成分开返回。

## 6. 配额：默认直接沿用现有账户

默认 `quota.policy=inherit_account`，`local_lifetime_call_limit=null`，`local_remaining_calls=null`。ARL 的累计受理计数继续保留作审计，不能再拿累计 32 次作为默认服务寿命。不伪造大整数来表示无限次数。

如果用户主动为某应用设置每日或累计限额，UI 和协议明确标注 **ARL 本地限额**、作用域、时间窗口和重置时间。该限额与上游窗口单独返回。本地并发数、活跃队列长度、请求大小、单次推理超时仍是资源保护，不叫账户额度。

账户使用量来自官方 `account/rateLimits/read`/updated；优先多桶 `rateLimitsByLimitId`，保留 usedPercent、windowDurationMins、resetsAt、服务端限额状态及观察时间。缺失为 unknown/null，不是 0，不换算“还能调用 N 次”。套餐与调用可以共用一个上游桶，不能虚构每套餐独立余额。

上游配额耗尽时返回 upstream_quota_exhausted（仅当服务端明确分类）；普通 429/容量拥堵返回相应限流/容量错误，不能全部标成额度用完。不给客户端自动换账号、改用付费 API、购买 credits 或消耗重置券的权限。额度状态只是快照；最终准入仍以上游响应为准。

## 7. 执行、回执与恢复

- 用现有单队列和授予的执行范围受理，不因 discovery/resolve 成功而绕过权限；资源 admission 与账户 snapshot 各自独立。
- 文本生成保持临时空工作目录、只读线程、禁用继承指令及工具。推理服务的联网不等于模型有网络/文件访问能力。
- 受理回执包含 request/job/resolution ID、内容哈希、套餐 revision、实际执行配置摘要、队列和超时策略、选型来源；所有者详细回执另含实际 model/effort/tier。
- 发布前核对上游确认的 model、reasoning effort、service tier、thread/turn 终态和输出哈希。请求参数、解析结果、上游确认、完成回执必须一致；不一致 withheld/failed，不能按请求值假填“实际使用”。
- 输出与原文属于应用私有数据；普通诊断只保留 ID、有限错误码、时间和哈希，不记录原文、推理过程或认证信息。
- 一个产品任务（一本 PDF/一段视频）可以含多个有稳定 child_request_id 的模型调用；调用次数与产品任务数分开统计。取消父任务停止继续分块并取消当前调用，不承诺已发生使用量退回。
- 同一应用＋request_id＋相同意图返回同一个任务；相同 ID 改内容或 selector 返回 request_conflict。受理状态未知时 lookup，不创建替代调用；needs_review 不自动重放。
- 已完成请求从活跃队列归档，保留可找回的回执/幂等记录；容量限制只统计活跃任务，不能让“队列最多 128 项”变成另一个累计调用上限。若按用户留存策略删除了内容，保留最小幂等墓碑，旧 ID 返回 result_expired，而不是重新收费执行。

## 8. NAS 应用兼容

继续走现有内网传输和应用独立令牌。Mac ARL host 派生并核验 pdf2zh / bilinote 两个消费范围，不能用一个 bridge 身份让客户端自行声明别的应用。OAuth/账号凭据留在 Mac。

OpenAI 兼容层由同一个 resolver 处理：

- `/v1/models` 返回允许展示的真实模型，以及五个稳定虚拟模型 ID `arl/package/<package_id>`。
- 支持 reasoning_effort 的客户端可直接发送真实 model＋effort。
- 只有 model 一个选择框的客户端，可选 host 登记的 `arl/option/<opaque-id>`，它绑定不可变的模型＋强度组合；不在客户端字符串里随意拼接 endpoint 或参数。
- PDF/BiliNote 默认可以选 `arl/package/medium`；修改 ARL 中该档组合后，新任务自然使用新配置。显式选择也从同一目录获得，不维护第二份硬编码清单。
- 缺少 model 的请求只有在消费配置已明确指定默认套餐时才可接受，不能偷偷猜模型。
- `/v1/models` 和 transport health 用于连接检测，不执行付费模型请求。请求带当前上游无法落实的 token/cost 硬上限时，必须返回 unsupported_limit，不能忽略 max_tokens 后称成功。BiliNote 连接测试需要改为元数据探活；真实生成走新执行协议。

## 9. 兼容与实施顺序

v1 与 v2 共存，新请求必须协商支持 v2；不能把 v2 不支持的模型/强度/套餐字段静默剥离退回旧接口。

1. 移除 NAS host 的本地累计次数门槛，保留计数与安全边界，并让成功回执离开活跃队列；不改动 ARL 主程序其它消费者。
2. 把 ApplicationModels 的套餐组合配置、revision/CAS 和两种 selector 落到正式 ARL host/settings；服务端沿用 canonical catalog validator。
3. 将解析与现有任务受理原子绑定；补账户窗口投影、查找和完成校验。
4. NAS OpenAI 兼容层改为调用该协议，补模型/套餐选择列表和元数据连接测试。
5. 用“修改套餐后旧任务不变、新任务变更”、显式 model/effort、未知模型、旧目录、共享配额、断线重复受理与取消做跨端验收，再分别跑真实 PDF/BiliNote。

本轮协议文件和示例通过离线检查，不代表第 2–5 步已经在 ARL 设置页或 NAS 模型选择器上线。

## 10. 来源与边界

- 本地已有实现：ARL/arl/application_models.py、codex_execution_options.py、codex_execution_contract.py、codex_server.py、storage.py、docs/TISRA-APPLICATION-MODELS.md。
- [官方 App Server 协议](https://learn.chatgpt.com/docs/app-server)：model/list、supportedReasoningEfforts、account/rateLimits/read、实际 thread/turn 回执。
- [官方模型与思考强度说明](https://learn.chatgpt.com/docs/models)：参数支持需按实际模型目录处理，较高思考强度会增加时间与 token 使用。

本文的 ARL v2 方法名、套餐设置、配额策略及迁移步骤是本项目设计，不是官方 OpenAI API 已提供的方法。模型套餐不承诺质量、时延或独立账户额度。
