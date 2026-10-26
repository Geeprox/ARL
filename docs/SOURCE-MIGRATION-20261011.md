# 2026-10-11 主仓源码迁移

今后仅在 /Users/<user>/Repository/ARL 修改源码、测试和文档；产物与精简回执仅在已忽略的 build/。历史目录只读取证。本次未创建新 worktree、未复制整棵源码、未制作审查 ZIP、未批量 git add。原 main 仍 unborn，HEAD/index/config 保留。

## 已迁入与验证

| 范围 | 本次采用 | 验证与边界 |
| --- | --- | --- |
| 网易云 | r2 诊断／恢复投影 7 文件、数组兼容两处 hunk；修正为仅转换声明为数组的 POST 参数 | 7 组脱敏、固定官方 CLI 27 例、原生 4 组通过；无真实供应方请求。不是原型整文件覆盖，不改变原请求未知状态或自动重放门。 |
| Messages | Store/View、Host 最终收件人确认与有效 pin、ContractTests 及合成 wire | Host typecheck、60 项 Control 契约通过。RuntimeStore/admission 不变；未安装 helper、未申请权限、未读 DB、未发送。 |
| 选中材料 | 5 新模块与 service/priority_host 两处受审改动；原始 transport 合同与 2 个合成测试 | 12 项真实 SDK/Runtime/SQLite/MemorySession 离线链通过。无模型、账号、真实 RPC；可信审阅和跨进程 Ledger 提交／撤销尚未闭合。 |
| 中文说明与图 | 更新 README、原字节 architecture.svg/screenshot.jpg | 截图为 2026-09-30 历史界面，图为 2026-10-01 边界示意；不是本次实机验收。 |
| 一键构建 | 默认候选 build29；输出限定 build/；共享 ModuleCache；验证后移除本次重复资源 staging | 3 项定向构建测试和 build-only 前置检查通过；未全量链接、签名或安装 build29。 |
| Mio | 原生产 26 个 Swift 输入逐项与当前主仓相同；相对路径清单移入 script/mio_native_recipe.json | 没有重复迁入旧源码或重编 Mio；此输入清单不是签包/安装方案。 |

复验入口：script/verify_source_migration.py；原生加 --native，仅重验构建加 --build-checks。选中材料：tests/test_selected_integration.py。全部测试材料和运行输入来自主仓；工具链仍使用本机 Xcode。

## 其余工作树处置

- 旅行工作树 18 路径中 16 路径与主仓完全相同；另外两项是主仓后续音乐／路由／recipe 的新增能力，保留主仓版本。真实凭据迁移仍未执行。
- stable-reminders-pairing 的 11 项已相同，3 项已由主仓升级复核与新 Control 身份绑定取代，不回覆盖。
- apple-authorized-business 的独立 helper 扩张与 disabled Notes 候选维持既有 HOLD；不把可编译候选变成安装或权限入口。
- Messages 原 helper-delivery-plan、旧身份 pin／封装／安装计划未迁为有效执行入口；本次只合入仍有效源码和合成输入。
- 恢复的 7 个旧作者 worktree 均无 tracked 修改或未跟踪源码；它们是历史快照，不整体覆盖当前源码。build-entrypoint-r1 是独立历史仓，当前入口以本仓为准。
- Portal/executor、SC1、模型下载/推理等延期或取消项未采用。新审计覆盖指定有效差异，不把历史线程索引等同“全部产品已验收”。

## 保留边界与收尾

当前安装仍为 ARL 0.1.2 build28、Mio build17。新增 bridge 与 Swift 解码器必须配套发布；不能单换已安装资源。本次没有签名、安装、重启、真实 Keychain/权限/供应方/模型动作。

原 append 9180f0e6-149d-4d7b-9913-c290913118b9 仍是 unknown；真实歌单与所选录音保留，不清 journal、不换 UUID、不重试采日志。

初次数组标量回归、只读 staging 删除和旧 native 夹具漏依赖三项失败与修正记录保留在 build/source-migration-20261011；只重跑受影响检查。此目录保留精简结果和输入哈希，编译缓存复用。历史包、原仓生成物和其他工作树本轮不删除。下一次正式制作包仍需完整生产链接、签名身份核验和安装验收。

旧 script/build_future_control.py、Notes 候选 builder 和历史 deployment 脚本的外部路径仅属保留历史入口；当前 build.sh 的输入检查不依赖这些路径。

## 同日收尾补充

38 路径静态独立审查 GO 已落仓。后续构建 build29 的 151 个输入、6 个生产阶段与4个签名/核验/归档阶段通过；外层拒绝读取 Documents/Codex 且禁止联网。首轮 Swift 插件重复施加沙箱失败已留证，重验只对编译器增加跳过内层沙箱参数，产品源码与正式 builder 未改。SECOND 已释放。成功包见 build/releases/ARL-0.1.2-29-codex-retirement-r2。

旧冻结 SDK API、Oct3 构建/契约测试、Notes 旧 builder 与两条旧 UI 准备入口均已明确退役，先退出再接触旧目录。精确 38 路径归档白名单与9项额外退役/路径修订白名单、5946 个未跟踪条目分类、41 项工作树去向以及删除范围见 build/audit/codex-retirement-20261011/CLOSEOUT.md；这些文件未暂存或提交。

安装仍为 ARL28/Mio17。build29 包的公开 authority 模板前像与当前 ARL28 不同，仅 executableSHA256 字段变化；当前签名身份、权限和共享 owner 资源一致。精确 INSTALL-TRANSITION-REVIEW.json 已记录实际前像，未绕过安装前像门。原音乐 unknown 不变。此收尾不替主会话宣布整个 Codex 目录中其他任务成果均可删除。
