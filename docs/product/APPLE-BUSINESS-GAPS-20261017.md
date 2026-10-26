# Apple 业务路径与剩余缺口

日期：2026-10-17。当前正式安装为0.1.2 build84，功能保持82-r2；图标更新不增加业务验收结论。本页区分实际生产路径、范围选择和最近实机证据；系统授权、元数据可读和业务成功分别验收。

后续提醒本机新任务已独立审查并正式安装82，只读入口和旧记录保留已验；真实范围确认与保存待验，见[新任务方案与验收边界](REMINDERS-TASKS.md)。提醒段已补上82实际状态，其他功能继续标明各自最近实机证据。

| 功能 | 现有真实路径 | 缺代码 | 缺用户选择 | 缺业务验收 |
| --- | --- | --- | --- | --- |
| 提醒 | 82本机单条提交、原生范围确认和独立记录；旧测试unknown保持 | 远端、日期及其他操作尚未接入 | 用户确认当前默认列表及本条内容 | 82只读入口通过；未请求提醒读写授权或实际保存 |
| 备忘 | 本机前台选择目录后，可搜索标题、读取或新建；写入有目标复核及持久记录 | 远端/Mio 调用未接入；追加未开放 | 用户选择精确账户和文件夹；全文在创建前确认 | 77只通过11项目录元数据；搜索、正文及创建未验 |
| 信息 | 本机前台选账户 → 核对单个邮箱 → 展示全文 → 发送；有目标复核及持久记录 | 远端/Mio 调用未接入；手机号、群聊、附件及历史未开放 | 明确选账户、收件邮箱及待发送全文 | 79只通过1个可选 iMessage 账户，另5个错误保留；未查收件人或发送 |
| 日历 | ARL 本体已获 writeOnly；当前控制器只负责授权与状态 | 真实远端请求到 ARL 本体的认证通道、创建执行者、确认范围及结果记录未接入 | 后续每次创建的目标、内容、时间及有限授权方式 | 81只通过仅添加授权；未读取或创建事件 |

## 提醒：旧验收暂停与新任务独立

[原验收协议](../../macOS/ARLControl/Models/RemindersFirstSlice.swift)的schema1仍只承接原检查、授权、来源与测试动作。旧 `select_source`、`run_smoke` 保持拒绝 unknown，不更换run、不释放两次预算或续期。

82新增schema2本机任务：填写内容、原生确认范围、一次性提交、取消和分页回读。调用方不能指定来源、列表、预算或grant；[正式Host](../../integrations/reminders_v3/RemindersFirstHost.swift)取得当前可写默认列表并展示完整内容，确认后核对目标和digest，签发绑定当前代码、helper会话及双时钟的五分钟单条范围。[独立记录](../../integrations/reminders_v3/RemindersTaskStore.swift)在任何可能保存前持久标记attempting；已尝试、已存、未知或取消都不可重新保存，但另一条新意图可另行确认。

生产 `callReviewedOperation` 现在有两个独立消费者：原 `RemindersTwoSaveRunner` 仍只执行原run的两次合成验收；新 `RemindersTaskRunner.create` 只在已确认的现有列表创建一条内容。请求和operation journal位于独立 `tasks-v1`，不借用原目录或预算。旧 [v1适配器](../../arl/reminders_write.py)仍不是当前正式通用远端任务入口。

新入口在正式82只读核验通过；原16项历史核对项和旧请求集合未变，旧unknown仍需人工核对。尚未输入新内容、申请提醒读写权限、确认范围或保存。当前仅支持标题，时间、远端发布与其他操作未开放，详见[新任务验收边界](REMINDERS-TASKS.md)。

## 备忘：写入代码已有，范围尚未选

[前台控制器](../../macOS/ARLControl/Services/NotesDirectController.swift)的 `select` 只接受刚枚举的目录，再核对原始账户/文件夹 ID、名称及共享状态。选定目录作为显示偏好保存；恢复显示不代表后台授权。每次用户前台点击搜索、读取或创建，仍绑定当前页面代次和精确目录，并重新验证目标。

`create` 冻结可见目录、标题及全文，生成有限期提案；先通过 [持久记录与目标复核](../../macOS/ARLControl/Services/NotesDirectBackend.swift)再执行一次 `crel`，只回读本次新建笔记核对结果。创建进入待核状态后不自动重试。无须读取既有私人正文来证明这段代码存在。

当前业务入口是 [备忘界面](../../macOS/ARLControl/Views/NotesDirectView.swift)，不是远端工具。下一次实际验收需要用户指定测试文件夹和非私人测试全文，分别核对本地结果及云端同步；不能从目录枚举成功推导创建可用。

## 信息：可用账户需显式选定

[信息界面](../../macOS/ARLControl/Views/MessagesDirectView.swift)在真实完整账户列表中提供“选用账户”。[控制器](../../macOS/ARLControl/Services/MessagesDirectController.swift)不自动选择唯一账户，离开页面即清除账户和收件目标；重新检查连接也清除旧选择。切换账户或编辑邮箱都会使旧收件目标失效。

“核对邮箱”在所选账户下精确过滤单个用户输入的邮箱，要求唯一 participant，再复核账户完整属性、participant ID、handle 和所属账户；不读取通讯录或消息历史。[发送后端](../../macOS/ARLControl/Services/MessagesDirectBackend.swift)在目标及全文提案核验、一次性持久记录之后，只投递一次 `icht/send`。系统接受不等于已送达，结果未知不重发。

现阶段无需为本机前台发送另补入口代码。实际缺口是用户的明确账户、收件地址和测试全文，以及完整发送验收。5个失败账户须保留错误继续诊断，不能推断它们的服务类型。远端调用是独立待开发项，不能复用前台 ticket 冒充远端授权。

## 日历：缺口在执行主体与远端授权接合

1. [ARL 本体权限控制器](../../macOS/ARLControl/Services/CalendarPermissionController.swift)只调用状态读取与 `requestWriteOnlyAccessToEvents`，没有事件创建或远端消息处理。
2. [当前界面](../../macOS/ARLControl/Views/CapabilitiesView.swift)明确显示“远端创建：尚未接入”，不会把 writeOnly 当作业务成功。
3. 现存 [MioCalendarConsumer](../../integrations/mio_apple/Consumer.swift)只在旧 helper 的有效 `NativeSession`/policy 中发布与执行日历工具；[Host](../../integrations/mio_apple/Host.swift)从自己的控制 socket 建立会话，[Setup](../../integrations/mio_apple/Setup.swift)也在该 helper 身份下处理权限和默认日历。它没有调用 ARL 本体的执行入口，不能继承本体 TCC 授权。音乐与其他 Mio 路径保持原状。
4. [Python 一次性写入适配](../../arl/calendar_write.py)由独立 [review runner](../../arl/calendar_review.py)组合，不是正式 ARL 本体与当前远端会话之间的连接；`service.py` 能识别工具名也不代表已注册执行 transport。

可分阶段实现的代码接缝：先定义精确调用主体与会话绑定、单次提案/操作 ID、期限、撤销及未知结果规则；再在正式 ARL 本体加入仅写入执行者和有限认证 IPC；最后将实际 Mio 消费者接到该入口并按实际协商发布工具。测试应覆盖旧会话、目标变化、重复请求、取消及提交后不明结果，再单独验收远端新建。开发阶段保持入口未激活，不自动确定日历范围、不沿用旧 helper grant，也不创建事件。

这不是切换一个启用标志即可补齐的纯代码小修；执行范围和远端主体必须进入明确的产品确认流程。

## 四份旧 pending 安装计划

已按81重新读取目标74、59、57、58的4份计划。它们仍为 `prepared/pending`，无已发布操作；目标包内容逐项匹配各自封存清单。当前 App 的完整库存均不匹配计划安装前像，正式事务会在 `install_preimage_changed` 停止；计划记录的旧进程代次均已退出，未发现 worker 回执文件。

其中74为曾扣留的 r1 候选，不能再次应用。其余也不是现装81的可执行升级计划。计划、journal、候选包和原有位置全部保留，未创建 operator 锁、取消、搬移或删除原像；共享锁 inode 保持。当前不可应用与可以删除是不同结论，后续清理需走明确的终态处置流程，不改未知事实。
