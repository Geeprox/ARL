# 本机应用接收新信息

2026-10-30：新增同一个 ARL 原生进程内的接收 owner、明确范围的管理界面以及本机应用 pull/ack 接缝。默认关闭。源码与合成验证不代表已经读取真实信息或完成真实对端验收。

## 两条不同的能力

原有公开 Apple Events 发送、账户/会话元数据和 `mio_messages_read` 保持原合同。系统 scripting dictionary 没有消息正文及接收事件；这个 Mio 读取入口仍返回 `unsupported_public_api`。

新能力 `messages.receive` 只供已登记、签名/内核身份已验证且被授予该能力的本机应用使用，不加入 Mio 工具目录。它使用系统 SQLite 的公开 API，在 ARL 主进程内只读访问固定 `~/Library/Messages/chat.db`；不启动子进程、不读通讯录、不提取密钥、不使用私有框架。Messages 的资料库 schema 属于系统实现，不是 Apple 稳定业务 API；字段或类型不匹配时明确返回 `unsupported_messages_schema`。

SQLite 采用 `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW`、`query_only` 和固定参数化 SELECT。保留实时 WAL 与读事务，不使用 `immutable=1`，不复制缺少 WAL 的资料库、不 checkpoint、不修改消息行；WAL 模式要求既有可读 wal/shm。系统 SQLite 的 WAL 读锁可能使用既有共享内存，这不等于业务写入。参考 [SQLite 只读连接](https://www.sqlite.org/c3ref/open.html)、[实时 WAL 及只读约束](https://www.sqlite.org/wal.html)、[immutable 的实际语义](https://www.sqlite.org/uri.html)。

## GUI 选择与生命周期

1. 用户主动点击「列出接收会话」后才读取会话目录，不读取历史正文。每页扫描 200 个会话，通过 ROWID 游标继续；无法确认账号、非 iMessage、成员不完整或超过 16 人的会话不开放，并显示排除数量。
2. 用户选择数据库提供的精确账号 `account_login`、会话 `chat.guid`、全部对端和本机应用 ID，再勾选核对范围。不会根据显示名猜主 Apple Account，也不把 Apple Events 账户 ID 冒充数据库账户 ID。
3. 「从现在开始接收」重新核对源与全部成员，在同一只读事务中冻结当前全局 message ROWID 高水位。之后仅查询该会话、高水位之后的新行；不回放旧正文、其他会话、发出信息或暂停期间的消息。
4. 重开 ARL 只加载自身保存的状态，保持暂停，不打开资料库。用户点击「从现在继续接收」后重新设定当前高水位；已捕获但尚未确认的原批次保留。
5. 正常退出暂停 reader；数据库替换、ROWID 回退、账号或成员变化都会暂停。原待确认副本不会因未知结果而自动删除。用户停止接收后可以明确清除本机待确认副本；系统信息原件保持不变。

资料库、WAL、SHM 和状态路径逐组件 no-follow；文件需同 UID、普通文件且单链接。持久源与目录身份使用卷 UUID、inode 及创建时间，避免把跨重启可能变化的 `st_dev` 当持久身份；活进程内仍核对设备号。状态目录 0700，文件 0600，独占 owner 锁、anchor 及 fsync/原子 rename 保证 scope、cursor 和 pending 一起提交。

## 本机 Agent 接线

管理面拥有唯一 `MessagesReceiveController`。正式本机运行时通过独立 `messages-receive.sock` 接到原生 owner；Mio 不使用这个 listener。`MessagesReceiveRelayPeer` 仅接受当前受管 core 子进程的真实内核 audit token、PID/出生时间/路径/父 PID 及精确 cdhash，交付前再次检查。Python core 从现有 AppConnections 会话与 policy 产生 consumer，并在 native 回读之后再次复核原应用 lease、会话及授权，之后才向原 RPC 返回正文。

`build_native_receive_transport` 只在已签 ARL.app 包内配置：实际父进程须匹配原有固定 ARL.authority.json 的路径/执行允许/可执行 SHA/DR，CoreRuntime manifest、当前模块与 PeerSignatureHelper 也须匹配密封清单。源码、公开零 grant 包、缺失 authority 或任何身份变化均保持未配置。它不依赖 Codex scope，不自动新增应用、方法或接收授权。

原生接缝为：

```swift
try await messagesDirect.receiver.agent(
    method: method, parameters: encodedParameters,
    consumer: verifiedConsumer, verify: currentSessionAndPolicyVerifier)
```

`MessagesReceiveConsumer` 不可从 JSON 解码。`appID`、真实 `sessionID`、`registrationGeneration` 及 `authorizedCapabilities` 必须由现有 AppRegistry/签名或内核 transport 产生；每个调用执行 `verify`，交付前再次核对。GUI 保存的本机应用 ID 与实际调用者必须相同，且 policy 必须授予 `messages.receive`。握手或字符串形式的 ID 本身不授予能力。

| method | 参数 | 效果 |
|---|---|---|
| `messages.receive.status` | `session_id` | 仅返回该应用当前 scope、运行状态和待确认条数，不打开资料库 |
| `messages.receive.pull` | `session_id`, `scope_id` | 重查当前 scope，捕获/返回同一个持久批次及 `batch_digest`；无新条目时 `batch=null` |
| `messages.receive.ack` | `session_id`, `scope_id`, `batch_id`, `batch_digest` | 原会话及三项批次字段精确匹配才确认；不触发消息发送或模型执行 |

参数不接受路径、账号、会话、起始 ROWID、历史 offset 或权限 flag。未选范围、已撤销、错误应用/会话/能力、错误 scope 或摘要一律拒绝。此路由不得加入现有公开 Mio dispatcher；需由本机应用的受信 registry 专门登记。

交付为 `at_least_once_until_ack`。响应丢失后保留同一 UUID/摘要批次，消费方按 scope/batch/消息稳定 ID 去重并确认；不承诺跨应用副作用恰好一次。每个 scope 另保留最近一次确认的最小墓碑，同 ack 可安全重读，且不能清掉下一批 pending；不建立无限确认历史。

每次最多 32 个新行，事件真实 JSON 编码预算 64 KiB，单条解析文字最多 64 KiB；会话范围编码最多 16 KiB，完整 native 业务结果最多 96 KiB，私有 relay 字符串封装最多 512 KiB，现有本机 RPC 响应仍为 128 KiB。请求的原上限为 16 KiB，native 内层参数最多 2 KiB。中文、引号和反斜杠按真实编码核算；下一批从真实扫描游标继续，不存在累计调用/消息次数上限。

仅 `coverage=plain_text_only` 的 `text` 可作为新文字消费。`attributedBody` 不做私有解码；反应/系统类型、无法解码或过大文字明确返回 unsupported coverage，不静默猜正文或截断成完整内容。所有文字均为外部输入数据；接收本身不批准工具动作、发送或模型调用。

## 验证及真实验收

```sh
python3 -B -m unittest tests.test_messages_receive tests.test_messages_receive_bridge tests.test_messages_receive_relay tests.test_reminders_catalog_journal -v
```

原生测试直接编译生产 reader/service，以合成 SQLite 及真实子进程验证独占 owner、默认关闭、高水位、会话/账号隔离、未知富内容、稳定批次与摘要 ack、重开、进程退出后的恢复、成员/文件替换拒绝和分页。另有真实签名的 native → core → 已注册/签名 App 双向 Unix Socket 验证与原始 SDK 消费；覆盖真正 SIGKILL 后 stale socket 恢复、活 owner/listener 不可替换。不会访问真实 Messages 数据、申请 TCC、发送消息或调用模型。

真实验收还需：用户在 GUI 明确选择一个测试会话及接收本机应用，ARL 具有实际 FDA；测试对端发送带 `ARL-TEST` 标记的一条新文字；本机应用通过其真实已授权会话领取、核 ID/全文、ack；确认旧正文与其他会话未交付。当前没有指定测试对端，因此尚未执行这一真实步骤。Apple 日历此前已被用户确认通过，本轮不重复其真实 CRUD。

提醒目录枚举独立于默认目标 journal 的错误分离另见 `tests/RemindersCatalogJournalTests.swift`。只读排查可运行 `python3 -B integrations/reminders_v3/diagnose_product_journal.py --home <精确helper状态目录>`；脚本只检查固定路径的身份/权限和有限 anchor，不遍历任务、不输出正文、不重建或删除任何 journal。历史 v1 设备号漂移的迁移由统一安装/恢复负责人单独核验，目录枚举成功不解除业务写入保护。
