# 网易云效果失败诊断与恢复状态

仅 effect/provider_rejected 可输出经清洗的 provider_code、provider_message、provider_msg；message 和 msg 各自保留来源，允许未知正常说明，不以类别枚举替代正文。code 字符串最多64 UTF-8字节，两个说明各512字节；先对完整有界输入脱敏，再按Unicode标量限长。超过64 KiB的单字段只留固定oversize标记。

清洗移除已注册秘密及其编码形式、当前请求值、PEM、URL、敏感头/签名/账号赋值、邮件/长标识/控制与格式字符，再执行现有秘密检查。只保留这三个顶层说明字段，不收集data、原响应、认证或stderr。Swift解码和公共日志均检查同一字段范围、字节限长及危险文本模式。错误说明用于诊断，不能证明成功、未发送或允许重放。

reconcile 顶层 effect_disposition 优先展示最后一次恢复尝试。有预留但 disposition 尚缺失时展示 outcome_unknown，禁止回退原始 not_dispatched；尚无恢复尝试则保留原始分类。账本与 recovery.reason 的历史含义不变，automatic_replay/new_submission_allowed 仍false，实际准入条件不变。

主仓已组合数组兼容：仅声明为数组的 playlist_append POST songIdList 转为单首数组；普通字符串与 GET 参数保持原处理。使用 Commander14.0.3 的公开 Option.argParser，保留唯一命令／路由、原参数处理、认证／签名、精确目标检查，并在 finally 恢复 parser。不修改 vendor，不新增 --body。query 描述不意味着 URL 查询层。合成回归验证最终 bizContent 与错歌／多歌拒绝，不证明供应方实际接受或历史 400 的原因。

数组类型差异与歌曲版权/API权限限制必须分别考虑。[官方仓库issue6](https://github.com/NetEase/skills/issues/6)是CLI0.1.1用户报告，[issue3](https://github.com/NetEase/skills/issues/3)同样描述visible:false原唱无法加入；它们不是本次400的维护者结论。保留所选原录音、原UUID与未知效果，不换曲、不重试采日志。

必须同步发布新Swift解码器和bridge；旧ARL28不认识新增字段，不能单换资源。主仓源码验证与安装分别记录；此次迁移不签包、不安装、不发业务请求。本次原始供应方正文未留存，需要既有供应方请求日志或准确接口说明进一步定位；新的脱敏测试文字不是真实失败证据。

## 2026-10-11 已完成恢复后的字段说明

约 16:10 UTC，正式 Mio 新执行上下文对原 UUID `9180f0e6-149d-4d7b-9913-c290913118b9` 完成一次明确恢复，独立 describe/reconcile 均确认成功：`state=verified`、`effect_disposition=submitted`、`readback_verified=true`；第3次尝试成功，前2次历史保留。正式歌单完整、稳定回读含原录音陈奕迅《十年》（黑白灰，66842）。用户随后明确确认“歌曲可见了”。本 writer 另一次只读 describe 也确认 complete=true、total/items=1、目标完全一致。完整收据见 [SUCCESS-RECEIPT.json](../build/music-append-success-20261011/SUCCESS-RECEIPT.json)。这条成功证据不回填原失败的供应方原因。

[当前 v3 歌单歌曲列表合同](https://developer.music.163.com/st/developer/document?docId=1d0537d7facc4c398834810d2955123c)将 `visible` 定义为“是否有版权（true，false）”；[歌曲信息合同](https://developer.music.163.com/st/developer/document?docId=b8bdaa8e40b946ecbc1d08978f3f12b0)另外定义 `playFlag` 为是否可以播放。当前适配器原样保留 `visible=false`，只应说明“本次开放 API 的版权标志为 false”。不得映射成“App 不显示”“本用户无法播放”或“加歌失败”，也不得据此阻断加歌或替换录音。App 可见已由用户确认，实际播放未验证；未查看的截图不标为像素验收。

`recovery.reason=notDispatched` 是首次建立恢复记录的历史准入原因，保存后保持不变；它不是最近一次发送状态。当前结果看顶层 `state/effect_disposition/readback_verified`，最近恢复尝试看 `recovery.effect_disposition`。展示时应把 reason 标为“初始恢复原因（历史）”，与“当前结果：已提交并回读确认”分开。保留字段及旧审计，不为文案一致覆盖历史，也不改传输协议或安装程序。
