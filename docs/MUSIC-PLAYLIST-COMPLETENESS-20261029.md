# 歌单完整快照与分帧传输

2026-10-29 修复：公开歌单读取仍沿用旧单帧时代的 98,304 字节汇总限制。加入完整 provider_record 与兼容元数据之后，32 首普通歌曲可能只返回前 30 首。返回值正确标为 budget_exhausted，但写前完整性检查和自动消费流程会持续停在 incomplete_read，无法继续维护歌单。手工拼接续页也不能建立两遍一致的完整快照。

当前运行时已经支持 SHA-256 绑定、顺序校验的私有结果分帧；原生侧可重组最多 32 MiB。因此汇总使用 24 MiB 条目预算，为外层结果、歌单元数据及序列化保留空间，避免把旧单帧展示预算误用作整个歌单的读取预算。每个传输帧仍受原有上限约束，原始业务字段全部保留。两个从零开始的完整读取、顺序一致、总数匹配和读取前后的歌单身份检查全部保留；超时、真正达到汇总预算、漂移及重复 ID 仍不能标记完整。显式从非零 offset 读取的续页仍为 continuation_end / complete=false。

验证：

- `node tests/MusicVerificationPagingTests.cjs`：32 首与 252 首富元数据、显式小预算、1,101 首成员核验、顺序漂移和重复 ID。
- `node tests/NetEasePlaylistContinuationTests.cjs <ServiceRuntime> <output>`：运行实际固定 CLI 与桥接器，100 首富元数据通过分帧完整交付；单独续页不冒充完整快照。
- 同一命令加 `--large-envelope-only`：较大合成凭据封装不再挤掉业务条目，保持帧尺寸和摘要验证。
- `BusinessGuardRegressionTests.swift`：实际 Swift DTO 接受完整富元数据快照，拒绝伪造完整续页与错误 offset。
- `MusicReadFailureTests.swift`、`MusicWriteRecoveryTests.swift`、`MusicPlaylistBatchTests.swift`：错误归因、同一 UUID 恢复、历史未知结果不重放及批量操作检查。

访达构建检查另修正了一处测试反例：范围外的同名前缀路径应为 `/fixture-home-other/project`，原测试误把允许范围内的 `/fixture-home/project` 当成拒绝对象；未修改访达生产范围检查。
