# 日历仅添加请求诊断

日历修复 `2ee3627` 与提醒兼容 `8533a1f` 已通过独立审查，合并为正式81完成事务更新和版本/签名回读。80未单独安装。以下保留79的原故障及修复依据；系统提示与用户决定另按81实际请求回读。

## 已确认原因

79签名严格验证通过，只有 Apple Events entitlement，写入用途描述完整。实际请求由正式 ARL 本体执行；MainActor入口调用 `requestWriteOnlyAccessToEvents()`，没有转向旧服务或其他进程。

请求时刻的系统日志依次记录：EventKit请求仅写入事件；TCC对同一ARL进程指出 Hardened Runtime 缺少 `com.apple.security.personal-information.calendars`，明确禁止提示；EventKit随后以 NO、error=0 调用完成回调。权限仍未决定。此前不是用户拒绝，也不是没有进入请求方法；应用忽略了Bool结果并显示笼统完成文案。

[Apple的Calendar entitlement说明](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.calendars)明确将该声明用于 App Sandbox 或 Hardened Runtime。此声明是系统能力门，最终数据范围仍取决于用途描述、请求方法和用户的系统决定。

## 最小修复与边界

- 正式签名、运行时身份核验和最终签名检查器精确要求 Apple Events 与 Calendar 两个 Bool true entitlement。缺项、整数代替Bool、额外调试或放宽声明继续拒绝。
- 仅保留写入用途键和仅添加请求API；最终发行及运行时入口拒绝全量和旧版用途键。Main源码未增加日程读取、事件创建或远端授权。
- 保存实际completion Bool，区分未决定、拒绝、限制及抛错。高级详情仅展示有限状态、系统错误码和已知错误域；未知域归类，不输出异常正文或私人值。
- 更新签名检查器源码pin；本地私有recipe只更新这一摘要，其余字段保持。现装79未被就地重签或修改，TCC数据库未读取或修改。

## 验证与剩余工作

生产controller的合成验证覆盖false且状态不变、真实拒绝状态、抛错、前台/身份门和严格entitlement类型。发行与Finder相关定向验证通过。81实际签名检查证实两个声明均为Bool true，写入用途键存在，全量及旧版用途键不存在；临时App已收起。

这仍不能代替系统提示实测。新生产改动审过、正式安装后，才由正式入口验证仅添加提示，系统按钮由用户点击；不得用重复点击或其他授权主体替代定位。诊断期间没有再次请求权限、读取日程或创建事件。提醒历史状态亦须在正式更新后只读验收，unknown继续暂停保存。

## 正式81结果

独立审查后已完成正式事务更新，签名与用途键实包回读通过。前台仅添加请求执行一次后，页面回读“允许写入”及“已允许添加事件”，仅写权限已取得。没有代点系统允许/拒绝按钮，没有读取或创建事件。最初AX提示文本识别不完整，不能据此否定后续明确的writeOnly状态及完成回读；原失败和观察均保留。

因此79缺失签名声明导致无法提示的问题已完成真实权限路径复验。日历业务写入和远端创建未在本轮验收，远端链路仍未接入；不能把获得权限等同于功能已全部可用。
