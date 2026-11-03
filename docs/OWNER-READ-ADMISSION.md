# Owner IPC 握手预算

2026-10-30 的一次精确合成提醒回读在本机 2,480 ms 后返回 `owner_deadline`。同一窄时间窗内，成功创建有 gateway/owner 的完整 request/finished 元数据；回读只有 Mio 的 received/finished，没有读取 hello 后才产生的 gateway `owner_request`。这把故障限制在业务提交前的本机 owner admission，不能归因于 EventKit 查询回调。

`get` 实际使用 `calendarItem(withIdentifier:)`、`refresh()` 和精确列表核对；`fetchReminders` 的 5 秒回调预算只用于 `query`。提醒 native 读取仍为 15 秒、helper 业务范围仍为 120 秒，owner 工具预算也保持原值。

完整已签包验证、对端真实内核身份以及串行 accept 可能超过原 2 秒 hello 窗口。现在客户端从首次 authority 校验前、服务端从 accept 后分别使用一个固定 10 秒 admission 总 deadline，并钳在原工具总 deadline 内。所有完整签名、封装资源、audit token、PID/出生身份和取消检查保持有效；每次同步验签前后均检查剩余预算，过期不得发出业务请求。

等待 accept、hello 及对方验签使用同一个 admission deadline。首字节到达后，完整帧的 header 和 body 共用原 2 秒传输期限；后续碎片不续期。连接和发送也保持原短期限。业务阶段继续消耗原工具总预算，不因握手成功而获得一个新预算。

`tests.test_owner_read_handshake` 编译真实 Wire、Authority、Transport 和 ConnectionLog，使用临时签名可执行、真实内核 Unix socket 和动态/静态 Security 校验，覆盖两段超过 2 秒的慢验签成功、整体预算到期不发送请求、碎帧超时、错误签名及取消。只有未使用的 catalog membership 使用合成定义；测试不加载正式 authority，不读用户数据、不执行真实服务。

这个改动不会建立并行 owner 或无限等待队列。已有业务占用串行 owner 超过 admission 总窗时，后续调用仍会有界拒绝。正式包重编安装后，还需在 owner 空闲时，以原测试对象 ID 做一次精确回读；创建成功和合成握手验证都不能代替这项真实回读结果。
