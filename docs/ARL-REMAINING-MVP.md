# ARL 剩余需求对照（2026-10-11）

这是当前源、正式 ARL30/Mio18、实际验收的分层清单。NAS 接入最高优先；不因为此前宿主执行延期而遗漏 NAS。原需求保持，源码存在不等于安装/真实验收。

| 需求 | 消费者/源码 | 已安装与实际证据 | 余项/顺序 |
| --- | --- | --- | --- |
| NAS配置/凭据/授权目录/读写/恢复 | build31候选已接原生purpose/controller、私有管道、成对manager、内置SMB及原生journal/新文件测试 | 正式ARL30未更换；最终构建/合成链通过，真实NAS/Keychain未验 | P0：复核签名候选与确切范围，安全录入后只读及明确新文件验收；见 NAS-PRODUCTION-ACCESS |
| 提醒事项 | v3原生服务及UI | 16:45UTC现有 helper 无提示状态调用 dyld -6，拒载 Core dylib；不能推断TCC缺失 | P1：修现有加载链，保持已批准身份与日志；不扩 helper/权限owner；真实对象写待明确验收 |
| 日历 | Mio EventKit宿主、状态入口、原生确认/一次执行 | Mio18状态CLI成功，not_determined，zero prompts/data；当前status pins已配Mio18 | P1：授权与明确事件验收待用户；不自动弹窗 |
| 备忘录 | 既有Notes权限/动作源码；Control入口 | 正式Notes helper/control.json均缺失；当前UI仅权限流程，不是通用读写 | P1：先闭合当前owner/接线；不恢复危险富文本append，不建第二套owner |
| 高德/飞猪统一凭据与能力 | 迁移UI、验证后原子提交、typed DTO、Mio owner route已进源码/构建 | 历史旧入口真实可查；原生曾configuration_required；迁移明确仍待确认 | P1：用户确认原来源→既有用途slot后验证；不因本次调序读取/复制秘密 |
| iMessage | v2 Store/View、精确群/成员/全文复核、native pin检查 | ARL30 admission默认nil；正式helper/control缺失 | P2：闭合负责进程及composition/路由；权限、个人/群/附件/后台各自验收，无自动发送 |
| 模型优先级握手/协商/未来App | priority.negotiate v1/v2、route绑定、单worker公平性、typed SDK | 历史隔离Codex文本/中断通过；生产route producer/grant与各App版本绑定不能由源码推定 | P2：逐已注册App闭合真实consumer；不下载模型、不启通用推理或付费路线 |
| Codex/Laya连接与刷新 | RuntimeStore已有失败保留最近成功状态、时间戳与显式断线区分 | 现有管理面已安装；需复核真实consumer/状态稳定性，不能把catalog存在等同可执行 | P2：窄重现后修复，不重复全套；Laya独立段落能力保持未验证 |
| Mio发现与工具适配 | 同一隧道、typed travel/music、分离权限/状态 | Mio18正式新上下文23工具；音乐原UUID恢复与独立回读通过 | 保持成功链；具体新工具须逐项consumer/安装/真实验收 |
| 网易云内置与凭据 | bundled Node/官方CLI、ARL owner、受控恢复 | ARL30/Mio18；创建/精确加歌/完整回读/用户可见完成；播放未验证 | 已完成指定范围，不重复或扩功能 |
| 日志/诊断/正式包/单入口 | logs.v3、分页/导出、固定错误；build.sh/Build.command同入口；recipe+offline resources | 当前签名正式ARL30/Mio18，内置音乐运行链已真实成功 | 保持源/包绑定、依赖与license边界；长运行/睡眠/权限持久性按实际补验 |
| Tisra/Friday消费及未来App | typed research/selected材料/priority/NAS seams | 独立源码/合成链不能证明生产App登记、模型或NAS连通 | 保留边界；NAS现在只做接入，不为Friday设计整理策略 |
| 一键服务部署/宿主executor | 保留候选 | 明确延期 | 不恢复大项目、Docker/K8s或通用执行 |
| 淘宝 | 既有能力保留 | 当前用户Hold | 停止新增开发、测试、部署 |
| 联系人 | 无需 | 不请求权限 | 不纳入待办 |

统一验收规则：先区分代码、安装、真实授权与具体效果。夜间仅离线实现、合成回归和无提示状态；需要用户的权限/凭据/精确测试对象集中一次说明，不能把优先级调整当授权。Camera原名保留、下载文件命名等属于后续NAS整理策略，本轮不实现。

Git：正式 main 已建立本地 checkpoint 7b88656ad7f40b393ca53176d320fac7d82f4975，687条明确源码/测试/活动文档/构建输入；未 push。排除了build、vendor二进制、历史大包/证据、本机设置和运行状态。保留的历史文件未删除，也不把收据归档替代源码纳入。后续完成的窄改动另行提交。

证据：build/remaining-arl-20261011/INITIAL-REAL-STATUS.json；CHECKPOINT-SCOPE.json；CHECKPOINT-RESULT.json。较旧 README/acceptance 中的版本和“未安装/未合入”文字是历史快照，当前状态以此对照和具体成功收据为准。

## 17:28 UTC 独立功能采用审计增补

审计确认仍有主仓功能源码闭包缺口，不能宣称历史功能已全部合入。Notes 富文本 create/append/附件图片的最终安全 admission 修复版尚未正式闭环，当前 UI 多为权限检查；iMessage V2 UI 已接，但 22 个 Python backend 模块缺主仓源码闭包。这不证明已安装包一定没有后端。后续保留当前 identity/V2 lifecycle，局部组合最终安全版本及 Host 资源构建输入，不回放旧危险 append 试验。

后续审计已将 213 个历史版本有限归并为 21 个功能组，其中 ARL 为 5 组；未新确认缺失包，Notes/iMessage 两项源闭包缺口保持。无需重新历史枚举，也不把 archive 当采用。新增依据 DOCUMENTS-FUNCTIONAL-WRITER-GROUPS-ROUND2.md 与 DOCUMENTS-FUNCTIONAL-DISPOSITION-ROUND2-20261011.json。NAS 仍最高优先，本轮不切换到 Notes/消息实际写入或系统授权。依据 build/audit/codex-trash-cleanup-20261011T060428Z/DOCUMENTS-FUNCTIONAL-ADOPTION-20261011.json 与 DOCUMENTS-FUNCTIONAL-WRITER-HANDOFF.md。
