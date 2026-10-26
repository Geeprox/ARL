# NAS 接入当前合同与接线差距

更新：2026-10-11。当前目标是 ARL 管理 NAS 接入基础；文件整理策略尚未确定。本文不授予连接、凭据迁移、目录扫描或文件修改权限。网易云已完成链路保持不变，淘宝 MVP Hold。

## 当前真实边界

| 层 | 主仓情况 | 正式产品/缺口 |
| --- | --- | --- |
| 配置 UI | NASSettings 的面板、模型、缓存和手动动作已进入 Control 构建 | RuntimeStore 默认 nasControllerPort=nil；composition 的 credentialConsumer=nil；实际生产控制端未接入 |
| 连接/凭据 | arl_nas_credential 的 scope、broker、单次私有租借、失效/撤权检查；与 Friday manager 成对装配的 factory | 没有生产原生 NAS purpose/provider。不得把普通凭据 reference 或已存 API key 当 NAS 凭据 |
| 原生私有载体 | NASSettingsPrivateCarrier.swift 与 settings_channel.py 是保留源码 | 未进入当前 Control recipe；Python 引用的 .gateway 模块缺失，Swift 支撑类型也未在该叶子内闭合。不能直接当可启动宿主 |
| 读接口 | 现有 ScopedTransport 仅 health/list/stat/read；manager 的 source/epoch、opaque object_ref、revision、单次 cursor 约束 | homeplane 是宿主提供的依赖，不在 ARL 的标准库安装清单内。实际管理器、已授权 native provider、签名/登记与发布仍需组合 |
| 有界目录读取 | 新 BoundedInventory 消费已有成对连接，单目录、最多8页/512项/30秒，默认2页/128项/10秒 | 定向合成链已通过；尚未装配为生产 RPC/UI。没有真实 NAS 读取 |
| 新文件上传 | arl/nas_upload_consumer.py、核心5模块、Runtime/Store completion_fence 已在主仓；R2 完成栅栏可复用 | 不是“尚未合入”；但无默认注册/启用、生产 native journal FD/许可装配或 SMB 写入 medium。不能宣称通用写已可用 |
| 移动/重命名/删除/覆盖 | 不属于 upload_new 合同 | 没有正式接口，不用上传+删除模拟；整理策略和真实写入另行确认 |

当前配置面、Python桥和原生载体仍明确拒绝 live 动作。不能仅删除 LIVE_DEPENDENCY_REVIEW_PENDING 或改布尔值冒充接通，也不能用截图/UI勾选授予实际权限。未借用 Friday 的私人配置或 credentials 文件；此轮只核对其公开源码合同，没有修改 Friday 源码。

本机挂载表另已只读确认有 **1 个 SMB 挂载、0 个 NFS 挂载**；未输出或保存地址/用户名/路径，未访问远端目录，也不证明网络当前可达。可在用户确认授权目录时优先评估复用现有系统连接；它不等于 ARL 已拥有该凭据或获得该共享目录访问许可，不能自动拿来扫描。

## 现有私有会话对接（未来跨 App 消费的基础）

生产组合必须通过 make_scoped_nas_manager 同时配对 resolver 和 ScopedTransport，不能把 opaque ticket resolver 单独装到普通 WorkerTransport。scope 含 source_ref、credential_ref、credential_generation、config_fingerprint、root_descriptor_digest、config_generation。credential_ref 是不透明引用，不是秘密；scope 描述也不是授权。

原生 owner 必须提供 HostAuthorizer.verify、PrivateProvider.use 和实时 credential generation。verify 在 reserve、lease、connect、请求及回复边界重验真实调用者/代码/登记/epoch；PrivateProvider 仅在受控回调内使用用途绑定凭据，finally 清理。不得新增公开 return-secret RPC。缺 purpose/provider、scope 改变、撤权或过期都拒绝，不能退回旧明文配置或匿名模式。

复用的 manager 只读接口：

- list_page(source_ref, cursor=None, limit<=128, directory_ref=None)：directory_ref 是已返回目录的 opaque object_ref；没有绝对路径/任意 URL 参数。
- stat(source_ref, object_ref, expected_revision)：元数据，revision 改变必须拒绝依赖旧版本的操作。
- read_range(source_ref, object_ref, expected_revision, offset, length<=1MiB)：已授权范围内的有界字节读取；此轮没有调用。
- 连接恢复必须由宿主重新取得有限准入，验证当前 configuration/credential generation；新 epoch 使旧对象引用和 cursor 失效。无盲目无限重连。

### Friday 当前回调兼容性（新鲜审计纠正）

Friday 已支持 private resolver 注入，Steward 已启用；不能再把旧的“resolver 恒为 None”当当前实现事实。正式 serve() 仍未注入真实 resolver。此处只核对接入合同，不启用 Friday 扫描/整理路由，也不更改 Friday。

Friday 的 local settings 回调是 async resolver(credential_ref, *, purpose="friday.nas.read-only.v1") -> NASCredentials | None；ARL 当前的受信入口是 arl_nas_credential.friday_bridge.make_scoped_nas_manager(state_path, *, scope, caller, admission, authorizer, provider, transport_factory, current_credential_generation)，返回 ScopedNASConnection。两者不是可直接互换的回调：ARL 工厂内部 resolver 只向配套 ScopedTransport 返回 secret-free ticket，不能把它单独装进使用普通 WorkerTransport 的 local settings resolver，也不能为适配接口新增返回用户名/密码的公开 SDK。

已有工厂的接法是向支持 manager 注入的宿主交 connection.manager，并保留 connection.credentials 以执行取消/撤权；还需生产 owner 和宿主生命周期装配。配置/已存引用发现可用 connection.snapshot() 的非秘密 DTO，不触发凭据解析；该 snapshot 仅在受信 factory 已正确装配后成立，不代表当前正式 serve() 已可用。轮换/配置变化由 current_credential_generation 与完整 scope 重验使旧准入失效，断开并重建连接须重新获准；不能用常量 generation 或旧 ticket 续期。

本次依据 Friday 的 CURRENT-SOURCE-AUDIT.json（SHA256 928b07b7905476569f810e68f165e4b05980a1ecb89c5c34a6fb03da194b3157）及 ARL 当前工厂源码。Friday 业务扫描、预览和整理策略不属于本轮接入实现。

## 本轮可运行的有界目录消费者

宿主在已获准、已连接的 ScopedNASConnection 上构造 connection.bounded_inventory(bounds=..., directory_ref=...) 并 await run()。该入口是宿主内部 Python API，没有新 listener、公开 RPC、账号或持久状态。

它借用且固定当前 manager/broker/scope，前后复核 native authorizer 和当前 connection epoch。只调 list_page；不 connect/reconnect，不解析凭据，不 stat/read_range，不递归，不写入。操作单次使用；页数、条目数、时限有界；预算耗尽返回明确 partial，撤权/断线/配置漂移/取消/超时/重复页或注入字段不发布成功结果。

返回值仅保留既有 NASConnectionEntry 的 object_ref/kind/revision/size/modified_ns/media_kind/closed/revision_basis；没有 filename、路径、正文或账号。enumeration_complete 仅表示该目录在这次有界分页中读到结尾；snapshot_consistent 始终 false，不保证原子快照、不代表整个共享目录或 NAS 已扫描完成。该层不负责文件命名/分类/去重策略。

测试：python3 -B -m unittest tests.test_nas_inventory -v。使用真实 ARL CredentialBroker 与可撤权 authorizer 双替身、合成分页；没有 Homeplane 生产实例、SMB/SFTP、真实凭据或真实文件。不能以此替代 native provider、真实 IPC 或安装验收。

## 写入合同的独立门

nas.upload_new.v1 的公开 submit 仅 operation_id 与 plan_hash。源/目标、sealed source FD、journal FD、subject/epoch/native budget、写权限均由宿主私有装配，不能由 DTO 自报。它只新增文件。Runtime/Store 在持久提交结果时重验取消、期限、peer/policy/credential 绑定；已经产生效果但完成授权失效时保留 effect 事实并 needs_review，不回滚或自动重试。

真实读权限不能自动升级为写准入；没有 native write medium 就保持 unavailable。后续最小写验收应是专门允许的测试目录内一个指定新文件及字节/大小回读，禁止覆盖现有文件。移除该测试文件也需原验收范围明确包含清理。

## 下一最小接线与用户待办

1. 保留既有 UI/manager/broker，先完成原生 NAS purpose 的私有租借与 scope generation，再组合一个受信宿主的 controller port；不要新增第二套凭据库。
2. 封装并验证 SMB 运行依赖，连接状态、定向 list/stat/range 与取消/断线/撤权沿用上述合同。当前缺口不是文件整理策略。
3. 另配 upload_new 的真实 medium 与 journal/授权边界；读和写逐项验收。
4. 先由主会话协调可复用的现有非秘密配置，只收集协议、NAS地址/端口、share、允许的根目录和 opaque reference 是否存在，不读取旧密码文件。若缺失，一次确认这些配置、ARL内安全录入凭据的方式，以及只读/新文件写入测试目录；不在聊天中索取密码。
5. 真实验证只在明确允许的范围进行；今晚不主动弹授权窗口、不连接未知目标、不扫全库、不改名/移动/删除。

Apple、模型调度、Codex/Laya、Mio、日志与打包等保留项见 ARL-REMAINING-MVP.md。
