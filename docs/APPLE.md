# Apple 能力调查与接口状态

Calendar / Reminders有支持的EventKit API。macOS14+应区分fullAccess / writeOnly以及calendar/reminders各自的usage description。ARL写了独立可编译 `apple/EventKitHelper.swift`，授权状态操作不创建EKEventStore、不调用requestAccess；列表操作只有已存在fullAccess时创建store，Calendar范围≤31天、最多100条，Reminders只取未来31天到期未完成、最多100条。调用通过固定host配置的binary stdin JSON，没有任意AppleScript、路径或命令接口。helper的权限身份、签名/打包以及用户同意flow尚未接入。

本机编译与 `apple.authorization` 实测：calendar=not_determined，reminders=not_determined，prompts_requested=false。因此只证明helper可运行且能查询授权，不证明真实Apple能力已接通；没有读取真实Calendar/Reminders内容。测试double验证needs_permission、needs_unlock、resume和私有结果身份gate。

本机Notes.sdef实读：body可写HTML text，plaintext只读，附件id / content identifier / URL等元数据只读，未找到原子append。不能由body可写推导富文本、检查单、表格、附件、协作和并发iCloud更新可保真。当前没有Notes修改工具，不执行UI/Apple event、不触碰待收尾笔记。无数据库直写。后续原生Shortcuts文本追加候选仍须明确批准与独立对象保真验收，不能把文档的Allow Running When Locked当成本机实测。

Core的needs_unlock是能力级状态，不是全局暂停。adapter timeout只是unavailable，不能推断锁屏；缺少权限是needs_permission，用户解决后新任务或明确恢复。非幂等写在执行中遇到不确定性只能needs_review，不自动重放。

依据：

- [Apple EventKit](https://developer.apple.com/documentation/eventkit)
- [requestFullAccessToReminders](https://developer.apple.com/documentation/EventKit/EKEventStore/requestFullAccessToReminders(completion:))：权限请求会提示用户，ARL不自动调用。
- [TN3152 Calendar访问级别](https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels)
- [NSAppleScript](https://developer.apple.com/documentation/foundation/nsapplescript)
- 本机 `/System/Applications/Notes.app/Contents/Resources/Notes.sdef`，仅字典仅读。
- 父任务运行调查 `/Users/<user>/Documents/Codex/2026-09-30/task-5/mac-lock-runtime-investigation.md`：锁屏/电源/FileVault边界及Shortcuts官方资料；ARL未重复改设置。
