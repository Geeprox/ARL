# 备忘录主应用接线

本功能由正式 ARL 主进程执行固定 Apple Events。保留现有稳定 CD85/Team designated requirement 与 hardened runtime，只添加 `com.apple.security.automation.apple-events=true`；签包检查器拒绝多余、缺失、非布尔或关闭值，检查固定 usage 文案。源码候选、演示和隔离启动均不可访问系统服务。

## 用户操作

首次需要系统权限时，用户点击“允许连接备忘录”进入系统 Automation 授权，不叠加应用确认框。已有权限使用 ask=false 检查。系统备忘录需要已运行，目标固定为系统包及其真实 PID、启动代和 Apple 签名；失效即停止，不启动脚本或寻找替代服务。

“选择文件夹”仅列账户及顶层非共享文件夹。点击“使用此文件夹”完成明确范围选择，不再追问一次。保存的仅为显示偏好（精确账户/文件夹 ID 与名称），不是后台/RPC grant；每次在显示此目标的页面点击业务按钮时重新核验固定 ID、名称、container 和 shared 状态。账户/文件夹名存在歧义时不猜测。选择在切换页面及重新打开 ARL 后保留；操作期限只约束本次调用，不要求周期性重授权。

搜索仅标题，最多扫描200条、返回50条，页面显示实际覆盖数量；先取得ID，再读取稳定ID的标题。共享、加密对象跳过。读取只能来自当前结果集中被用户点选的行，检查修订与 folder，显示纯文本（最多64KiB），不取 HTML、附件或其他文件夹内容。

新建目标、标题和全文直接显示在正常编辑界面。按一次“新建笔记”冻结该精确意图并执行，不追加“确定吗”弹窗。纯文本转义为固定HTML，仅一次make，随后仅核对新对象的范围、标题与纯文本；未确认云端同步。无追加、改写、删除、附件、Mio/RPC入口。

## 一次执行及取消

RuntimeStore拥有单个后台串行队列。描述符只在该队列创建、发送、释放，跨队列仅传DTO。普通事件ask=false、no-interact、do-not-record、no-prompt，单事件≤5秒且共用20秒预算；首次系统授权API可能等待用户，取消不会声称已撤回系统弹窗。

创建前持久保存opaque operation UUID与完整目标/内容摘要，O_EXCL并fsync文件/目录，再唯一一次make。任何claim部分失败、发送/回读超时或崩溃都保留consumed/unknown，不换ID自动重试。独立`apple-direct-once-v1`目录及anchor核对inode，缺失/替换后不自动重建；未知记录阻止后续新建，读取仍可用。无自动删除/重置旧v2或新记录。成功记录与claim摘要必须匹配。用户可在页面复制操作ID，内容和收件人不写入journal。

## 验证边界

本次源码新增不等于系统接通。需要新冻结树编译、合成fixture、独立review、签包/安装后再核真实ARL→Notes权限。真实业务仅在用户选择范围和按业务按钮之后执行。ARL48仍是此前Reminders修复安装，不含本候选。

针对性fixture在`tests/NotesDirectTests.swift`，仅合成descriptor、注入状态机与owned目录日志；无真实Apple Event、TCC、备忘录、Contacts或聊天数据库调用。正常release Python测试覆盖精确entitlement和Info/checker联动。native尚需fresh串行槽。
