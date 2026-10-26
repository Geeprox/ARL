# NAS 生产接入候选（ARL 0.1.2 build 31）

2026-10-11：主仓已实现并编译实际接线。正式安装仍是 ARL30/Mio18；候选未签名、未安装、未启动。源码/合成通过不等于真实 NAS 或产品验收通过。

## 当前完整调用链

原生 NAS 面板 → NASProductionController → 与现有登录仓库共用的 NASCredentialService → 原生独占子进程/匿名管道 → 内置 Python + 已固定 SMB 依赖 → 成对 CredentialBroker/ScopedTransport/manager。每次私有授权核对本机部署、凭据代次、完整 scope 和当前进程。账号/密码不进入 argv、环境变量或 JSON 状态文件，没有公开 return-secret 接口。

配置及引用可保存；保存登录、连接、受限目录元数据测试、手动重连、停止各为显式操作。空 PATH 运行不依赖用户安装 Python/SMB 包。依赖锁、官方 SHA、19 份 Python 许可证与依赖自身许可证随资源包封存。

会话沿用既有 120 秒单次授权预算；每 15 秒在原生等待响应时复核远端健康。失败/过期/代次变化关闭会话，不自动重试。恢复入口是明确重新连接，不能宣称长期无人值守连接已经验收。

## 一次新文件测试

用户先填写范围内已存在的专用测试子目录，再在原生对话框核对设备、端口、共享、范围、确切新文件名和完整短文本。提案是 owner 内的同一对象，不能反序列化或重放。实现复用原 ConsumptionJournal 五参数消费及现有 UploadNewStorage/UploadJournal/SealedSource；原 Apple journal 文件字节不变，并在 recipe 中独立固定 SHA。

SMB3 介质持有无删除/写共享的祖先句柄，独占 FILE_CREATE staging，write-through、文件 FLUSH、NO-REPLACE rename、父目录 FLUSH、强对象标识及关闭后只读回读。不支持目录 FLUSH 时在 staging 前停止；发布后失去确认保留 uncertain，不重试、不删远端文件、不释放目标预约。协议依据：[FileRenameInformation](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/52aa0b70-8094-4971-862d-79793f41e6a8)、[SMB2 FLUSH](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-smb2/026984f6-38af-4408-8200-50557eb0a286)。

本轮产品入口仅创建经全文确认的短测试文件；不开放任意文件上传、目录整理、覆盖、删除、Mio 管理 RPC 或外部 write API。通用 write 状态仍不宣称具备。真实服务器的 SMB3、目录 flush/访问掩码兼容性尚未验证。

## 证据

- build/nas-access-20261011/access-candidate-build31-r3：最终六步生产构建通过（SDK37/HostCore/完整Control/PackageInspector），185 个冻结输入；未签名。
- pipe-native-r2/RESULT.json：真实原生私有管道、生产 Python factory、原生 journal、上传算法和 SMB 编码介质的 6 项端到端合成检查通过；只有凭据仓库及 SMB 服务器 I/O 使用替身。
- LIGHT-FINAL-RESULT.json：最终源码的装配/断连 6 项及 SMB 介质 6 项通过。介质祖先权限收窄在此轮验证；早先端到端包保留原输入绑定。
- provider-native：原 provider 的 7 项合成证据保留，不重复旧大套。早先编译/断言失败记录也保留。

## 真实接入所需的最小信息

设备主机/IP与端口、共享名、共享内允许目录；账号/密码只由用户在原生安全输入中填写，不经聊天。另需一个既有专用测试子目录及对对话框所列确切文件/全文的确认。真实连接、凭据创建、写入之前仍须按原 review/freshguard 流程完成候选签名资源及最终身份核验；不迁移旧 Keychain/ACL，不自动安装或重启。

Notes/iMessage 的历史源码闭包缺口仍是独立待办；Friday/Tisra、淘宝、网易云实际业务均未因此扩展。
