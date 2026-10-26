# 网易云登录诊断（候选）

`provider_unconfirmed` 是 ARL 的兜底分类，不是网易云错误码。build 5 的这一面板文本来自退出码为0且完整回包状态为 provider_unconfirmed；成功、明确过期、非0退出、原生超时分别走其他分支。桥接只保留 success/status，不能从旧记录判断本次实际官方失败原因。官方 CLI 的账号 profile 检查可以在扫码授权后失败，因此二维码生成或扫码状态成功均不等于最终账号可访问。

## 最小诊断合同

固定阶段：owner、initialize、qr_create、qr_poll、account_read、token_store、bridge、provider、complete。每次用户操作分配独立UUID，贯穿 owner、显式传递的 detached task、桥接和持久化；每条有耗时。HTTP status、code/subCode、扫码状态只保留有限范围整数，字符串码严格转换，其余置空；已知秘密反射值也置空。未知官方message不原样转发，只映射固定类型。一次桥接最多128条，同状态去重。

官方解码源码佐证：QR创建读取顶层 code/message 与 data.qrCodeUrl/uniKey；轮询读取顶层 code/message 与 data.status；profile读取顶层 code/message。账号访问拒绝不能被二维码生成或 token 写入覆盖。bridge 的 token_store 事件仅表示官方 CLI 写入虚拟内存存储，owner 后续 token_store 始终还要执行实际 commitLease；在 commitLease 成功前不宣称本地持久化完成。

唯一日志出口是 `MusicDiagnostics.log`，将封闭类型编码为JSON，再写 macOS unified logging：subsystem `local.arl.control`、category `netease-diagnostic`、固定前缀 `netease_diagnostic_v1`。不打开原始 stdout/stderr，不保存请求URL、消息正文、AppID/PrivateKey、二维码、token、cookie、账号信息或错误对象。UI只显示固定阶段/建议、整数错误码和诊断UUID。系统日志留存/轮转由macOS管理；本热修不宣称完整ARL日志/导出体系已验收。

## 验证与真实复现

定向测试直接调用实际桥接诊断投影、原生解码、MusicRuntimeClient、面板状态及 CredentialOnboarding.commitLease 失败路径。包括秘密反射/任意字段/错误类型/顺序/所有权清理等负例。合成测试不证明真实登录成功。

独立review、freshguard、正式build/sign/install后，由用户点击当前正式“扫码登录”按钮一次；代理不代扫码、不自动创建第二张二维码。按诊断UUID收集有限阶段链，先判断 QRcreate、poll、profile或本地保存，再修对应业务问题。失败证据缺失时禁止把兜底文案当官方拒绝或要求用户猜测更换凭据。

全项目 provider/credential/任务/隧道/IPC/模型队列、日志轮转与安全导出审计已记录为后续独立范围，不混入当前补丁。
