# 管理面 v2 开发增量

完整产品标题仍为 Agent Runtime Layer；本地 Agent、云端 Bot 能力、管理与高级三类入口保持不变。此增量只改 UI、Swift 只读客户端与专项测试，不自动部署。

服务契约以 ../../docs/CONTROL-API.md 为准：settings.snapshot / settings.logs / settings.logs_export。未知方法退回旧 overview，新增状态明确未提供；格式、枚举或数值错误不会显示为就绪。注册、连接、身份核验、工具授权独立显示。目录发现不代表模型已加载；系统 CPU 0–100，进程 CPU 可超过 100，首次 CPU null，RSS 非独占内存；共享进程不在界面再次汇总。

日志只显示有限事件与代码。搜索当前已载入记录，载入更多手动触发，more=true 时 cursor 必须前进。筛选导出与服务端最近日志导出分开，最多 500 条、UTF-8 64 KiB，文件选择由用户明确触发；不读本机日志文件或任意进程输出。旧主机未提供此 API 时导出不可用。

凭据只显示服务用途与引用状态，不显示引用 ID，更不读/写系统 Keychain。只有 --demo 可以打开 SecureField 内存替身流程，且只接受 demo- 开头的虚拟值；真实 Keychain 工作流等待具体服务用途与用户交互另行接通。移除本地引用与供应方撤销明确区分。此版本不执行供应方撤销。

Apple 每个应用/操作分别展示实现、权限、锁定、host 授权与原始核验时间，不自动触发 TCC，不读任何内容。Friday 仅提供其家庭适配器证据与声明，不复制 HA/NAS 配置。

构建 `script/build_and_run.sh --build-only` 不启动/关闭任何 app；`--dev-build-only` 创建独立 local.arl.control.dev / ARLControlDev.app。开发 bundle 无明确 --runtime-home 或 --demo 时拒绝连接默认生产 home。原安装包与已安装 app/service 不变。

回归：`ARL_TEST_PYTHON=/opt/homebrew/bin/python3.13 script/test_control.sh` 保留原 52 场景；`script/test_control_metadata.sh` 执行 v2 严格 schema、导出、内存凭据与独立 source/旧 immutable 包端到端场景。可用 ARL_TEST_OLD_PACKAGE 指向被审查旧 metadata-only 包（包含 code/），测试仅在临时 home 启该包的 --isolated-test host。Swift macro/socket 测试可能需要执行环境批准；无需真实 Keychain/TCC。

真实生产未提供 v2、真实凭据保存、Apple 授权与家庭设备接入均不由编译、fixture 或隔离进程测试证明。截图必须带开发/演示预览标记。
