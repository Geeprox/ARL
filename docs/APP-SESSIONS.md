# 应用会话

宿主先用已有注册/签名身份和 policy 接纳调用方。协议不提供 RPC 自助登记，不修改工具 grant。当前 `connection.*` 仅限已有 heartbeat 方法授权的注册应用；其余接入需独立 host policy 审查。

## 双向交换

`arl/1` 下 `connection.open` 请求包含 `client_nonce`（64 位小写十六进制）、`name`、`icon_ref`（受限 SF Symbol）、`version`（可为 null）和 `capabilities`（去重、有界字符串数组）。服务器返回 schema1、protocol、原 nonce、session_id、challenge、accepted_capabilities 和 30 秒期限。所需能力来自请求，接受能力仅为请求与当前 policy.tools 交集。

客户端核对原 nonce、协议及能力子集，再用 `connection.confirm` 回传同一 session_id 与 challenge。10 秒内身份、注册代次和活性均未变化才成立。仅 open 或普通 RPC 不产生应用卡片。Python `Client.open_app_session` 与 Swift `ARLClient.openAppSession` 是实际消费者；外部产品须自行接入，ARL 不修改其他项目。

`connection.ping` 使用当前 session_id，刷新 30 秒期限；`connection.close` 显式断开。断开失败或效果不明时保留原 ID 先核查。应用继续运行不代表会话仍有效。

## 生命周期与展示

- 内核 PID、出生时间、精确登记 lease 或签名 audit token 绑定会话；不保留短连接 socket。
- 同一身份的新 open 保留旧已确认会话至确认/过期，避免刷新闪现。
- 活跃另一实例拒绝；旧挑战、ping 和 close 不能覆盖新会话。
- 注册换代、撤销、死亡、超时及时钟倒退失效；未完成握手无应用卡片。
- `settings.snapshot` 的 `handshake_session` 是公开会话标识，不是授权 bearer；挑战和身份材料不进入状态/日志。
- 旧 v2 状态可读但缺握手字段不显示应用；能力、登录、系统权限、执行结果仍分别核验。
- 暂时状态读取失败沿用带原时间的证据，显式断连清除；缓存证据仍按时间过期。

图标仅使用协议提供的受限 symbol，缺失身份图像使用通用占位；不根据相同 app ID 查找本机其他应用的图标。
