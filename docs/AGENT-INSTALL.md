# Agent 安装与排错

此文从干净机器/克隆开始。当前核心路径可自动验证；完整原生发行资产尚未公开，不能宣称干净克隆已能一键安装正式包。

## 给 Agent 的任务

> 在当前 ARL checkout 中检查依赖，运行 `script/bootstrap.py --check` 和 `--prepare --smoke`。只用隔离状态，不复用现有生产 home。缺少依赖时先列明确缺项，再从官方来源准备；账号登录、密钥和系统权限交给用户可见交互。不要创建账户、发布公网隧道或扩大持久授权。原生构建资源未公开时报告缺项，不拼装作者的历史目录或已安装主程序。

## 必需与可选

| 范围 | 要求 | 安装/检测 |
| --- | --- | --- |
| 核心 | Python 3.9+、Git；标准库即可 | Python 官方 macOS 安装器；`python3 --version` |
| 原生源码 | Apple Silicon、macOS 14+、Swift 6 / Xcode | 官方 Xcode；`xcrun swiftc --version` |
| 原生发行包 | 经核验的签名、资源、manifest | 维护者发布独立可校验包后安装 |
| 模型 | Codex 原生/CLI 及用户自己的登录 | 官方 Codex 安装说明；本机 `codex --version` |
| 音乐/NAS | 正式包内固定组件 | 无需另外 npm 或 pip 安装 |
| 远端工具 | Mio 本机网关与用户自己的 Secure MCP Tunnel | 可选；本机健康、远端回程、工具发布分别检测 |
| 系统应用 | 各 owner 的系统权限 | 在相应功能页按需申请，拒绝后到系统设置 |

官方来源：[Python](https://www.python.org/downloads/macos/)、[Apple 工具链](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)、[Codex](https://developers.openai.com/codex/cli/)、[Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)。具体下载版本由 Agent 当次核对，不能从项目历史 pin 推断最新版。

## 检查与隔离准备

```sh
python3 -B script/bootstrap.py --check
python3 -B script/bootstrap.py --prepare --smoke
python3 -B script/bootstrap.py --check --native
```

`--check` 默认只检查；`--prepare` 幂等创建仓内私有开发状态，遇到不安全目录拒绝；`--smoke` 在新合成目录跑真实 Socket RPC，然后停止并清理，不执行任务。失败退出非零，可补齐输入后重跑同一命令。它不会安装应用、修改启动项或读取作者状态。

`--native` 还检查平台、Swift 与离线资源。干净克隆缺 `vendor/release/`、NAS interpreter/cache 或签名配置时，必须报告“公开构建资源缺失”。当前 recipe 是维护者本机发布链，不能当通用安装配置。发布前需提供带哈希、来源、license 与版本清单的公开资源下载/准备脚本，并通过无作者环境的构建验收。

## 构建依赖准备

```sh
python3 -B script/install_tunnel.py --check
python3 -B script/install_tunnel.py --install
python3 -B script/prepare_nas_dependencies.py --check
python3 -B script/prepare_nas_dependencies.py --install
```

前两个命令只准备官方 tunnel-client 依赖缓存：核 GitHub 官方发布清单与 SHA256，拒绝越界/链接解包；不会启动客户端、创建配置/账号/隧道、安装插件或改现有 Mio。现有产品使用固定客户端；准备最新版不等于升级生产运行时。NAS 准备器按 lock 下载解释器/轮子与许可，无需用户 pip/npm；许可解压需要 `zstd`。检查和下载失败可重跑；未知已有缓存拒绝覆盖，已核准备中断可恢复。

运行时一律归正式 ARL.app 管理，依赖脚本不会成为长期服务。完整原生干净机器准备仍受以下缺项阻断：公开资源壳/音乐 runtime 的来源与许可、通用原生签名/authority、Mio 新用户原生配置/账号交互、App 内迁移安装/回滚事务和无作者环境验收。

## Mio 配置边界

公开模板：[mio-setup.example.json](../examples/mio-setup.example.json)。它是给 Agent 的安装计划输入，**不是当前网关的可执行配置**；其中没有 token、组织、域名或作者路径。Agent 必须先检查使用者已有客户端与平台的可用隧道工具，再按其真实配置协议转换，不猜 CLI 参数或复制现有人的 grant。

1. 使用 ARL 包内受控网关与固定客户端，核验健康与 ready，不能用进程存在代替。不要在外部仓库启动辅助网关。
2. 使用者在自己的平台交互中登录、选择组织与本机服务器；平台返回的隧道标识和 token 仅保存于私有状态。
3. 明确实际调用方、工具、读写范围与期限，再批准隧道连接。不要默认公网端口、任意文件或 shell 工具。
4. 从真实远端上下文调用常量 ping；分别核对工具列表和业务 owner。ping 成功不证明音乐账号、Apple 权限或写入授权。
5. 测试失败保留现有音乐链路，先检查客户端健康、工具发布与 owner 的错误码，不创建第二套网关或盲重发业务写入。

当前有依赖准备器，尚无闭合的新用户原生 Mio 配置/账号交互；完整干净机器流程待验收。本轮未实际创建或修改隧道。

## 登录与真实检测

在连接页选择账户，使用原生密钥输入/扫码界面。NAS 按服务器登录 → 验证 → 共享 → 目录范围授权继续。系统应用已有权限直接下一步，拒绝后用系统设置恢复，不循环申请。各连接结果不能代替真实业务验收。

| 状态 | 下一步 |
| --- | --- |
| 依赖/离线资源缺失 | 官方补齐固定输入，重跑 check |
| 签名/authority 不匹配 | 停止安装，核对具体发行包与现有授权 |
| 后台未连接 | 检查运行记录、停用标记和安装版本 |
| 应用列表为空 | 调用方完成双向会话；不要添加静态卡片 |
| 权限拒绝 | 到系统设置恢复后重查 |
| 结果未知/清理未完成 | 核对原请求，保留记录，不换 ID 自动重试 |

## 升级与卸载

正式交付单位为同一 ARL.app；核心、Mio、必要系统 helper 与 Finder 扩展均在包内。先核 manifest、签名、版本、authority 和独立审查，再原子更新同一路径与既有代码绑定。详见 [统一应用](product/UNIFIED-APP.md)。公开通用 updater/installer 尚未完成；不要将旧 metadata-only `deployment/manage.py` 套用到新原生包。旧 install/update CLI 已退役；历史打包/管理器只用于标记隔离状态的回归与归属分析，不提供生产安装。

卸载先停用所属运行时，再移除已核对的程序与其受管理启动项；默认保留私有数据库、登录、日志和用户授权记录。清除凭据、业务数据或历史需用户专项选择。不要广泛删除同名目录、Keychain 项或系统权限。
