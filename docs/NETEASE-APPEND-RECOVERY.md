# 网易云同 UUID 一次追加恢复

正常 `mio_netease_playlist_append_song` 的未知结果仍只允许核对。明确要求恢复时，使用 `mio_netease_playlist_recover_append_once`，仅传原 `request_id`。账号和目标应先由用户确认；工具描述不能自行创造授权。

ARL 从原账本读取确切歌单/歌曲/名称，核验当前 credential reference 与 epoch。缺失原记录、创建歌单请求、账号变更均不产生新写入。恢复前完整读取自有歌单，并两次完整读取同一歌单的歌曲集合；目标不符、集合漂移或缺失成员字段均不预留效果。歌曲已在歌单中时仅完成回读。

原 `write-ledger.json` 不改写。恢复账本保留全部旧尝试及未知结果，在同一 fsync/原子替换事务内追加决定和唯一新尝试，记录契约版本及原尝试数。恢复预留即消耗一次额度，包括本地未发出、未知或提交后丢失响应；重启和重复调用均不能重新预留。跨进程锁与旧记录保护共同保证只有一个新尝试。新机制使用 schema 2，使旧程序无法忽略新字段后再次发送。

供应方契约：[批量添加歌曲到歌单](https://developer.music.163.com/st/developer/document?docId=81deeef0f74147dba249531b5e08042d)，官方更新时间 2026-04-14 11:09:26。接口 `/openapi/music/basic/playlist/song/batch/like` 要求自有歌单；`songIdList` 类型为字符串列表。普通成功示例为 `code:200,data:true`，重复添加示例为 `code:200,data:[]`。公开正文及 SHA 位于 build/music-append-recovery-20261011/official-contract/DUPLICATE-ADD-CONTRACT.json。

重复添加契约支持受控恢复，不代替歌曲成员回读，也不证明原失败是参数或版权原因。正式结果需经 ChatGPT/Mio→已签名 ARL→官方适配器验证，捕获有限脱敏 code/message 并回读具体歌曲。不得换 UUID、新建歌单、清除未知历史、切换账号或无限重试。

针对性测试：tests/MusicAppendOnceTests.swift（14组）与 tests/MioMusicAppendOnceToolTests.swift（4组），均使用合成凭据与 transport。生产构建和真实业务结果另见 build/music-append-once-20261011。

## 已安装正式链路验收（2026-10-11）

ARL30/Mio18 的新增目录已在新的正式执行上下文可用。约16:10 UTC，原 UUID `9180f0e6-149d-4d7b-9913-c290913118b9` 的一次明确恢复成功；原2次历史保留，新 attempt_count=3，append_recovery_reserved=true，契约仍为 `netease-batch-like-duplicate-20260414`。独立 describe/reconcile 回读验证了原歌单中的精确原录音，用户又确认“歌曲可见了”。不再处于等待刷新状态。证据、来源区分和未验证播放边界见 [主仓成功收据](../build/music-append-success-20261011/SUCCESS-RECEIPT.json)。

`recovery.reason` 表示恢复记录初建时的历史原因，不能当成最新效果分类；旧值 `notDispatched` 可与新的 `submitted/verified` 同时成立。UI/诊断若显示此字段，应使用“初始恢复原因（历史）”。`visible` 保留官方原值，其版权字段语义与 App 可见、歌单成员存在、实际播放各自分开，详见 [字段说明](NETEASE-PROVIDER-FAILURE-DIAGNOSTICS.md)。
