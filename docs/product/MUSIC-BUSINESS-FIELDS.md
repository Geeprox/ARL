# 音乐业务信息

本轮透明适配及兼容语义见[网易云透明适配](NETEASE-TRANSPARENT-SEARCH.md)。`provider_record.fields` 保留原始业务 JSON；下列 business_info 是兼容视图，不替代原始记录。

歌曲读取保留旧 `song_id/name/url/visible/metadata`，新增 `metadata.business_info`（schema_version=1）。公共搜索、歌单歌曲和云盘使用同一只读投影；聚合的每个 source_record 保留自己的业务块。写入授权、精确 ID、确认、幂等和未知结果恢复策略不变。

| 信息 | 表达 |
| --- | --- |
| 艺人、专辑 | ID、原始 ID 类型、名称及来源字段；缺失/空值/非法类型分别说明 |
| 时长 | 原始整数与 `duration_source_field`；合同未确认单位，`duration_unit=null` |
| 原唱分类 | `origin_cover_type` 和 `origin_cover_category`；旧 `recording_version` 保留作原唱/翻唱兼容别名 |
| 录音版次 | `recording_edition=null`、not_requested；原唱标签不证明年份、现场、重制或 Take |
| 可用性 | 类型验证过的供应方标志；不等于 App 实际播放或允许写入 |
| 未知原因 | not_in_response、upstream_null、empty_value、invalid_shape、local_limit、not_requested、unit_unconfirmed、not_mapped |

旧 business_info 只投影业务白名单；新增 provider_record 保留原始业务字段，认证材料单独剔除并注明类型。算法、账户偏好、任意错误正文、签名 URL、凭据及会话材料不进入新业务块。未审的 qualities/songTag/emotionTag 明确记录空值或未映射，不能伪称供应方没有。

`code=200/subCode=10007/data=null` 按已读合同归类为资源不存在，保留 provider_status 的安全 code/sub_code；不会变成数组/格式异常，也不会要求重新登录。Mio 音乐只读结果的 text 与 structuredContent 返回同一投影。

响应预算按包含凭据的私有帧与原生 owner 边界检查。歌曲业务字段完整保留；超限时只把整首歌曲移到下一页，`search_page.next_offset` 按实际返回数量推进，`coverage=budget_exhausted` 且 `complete=false`。供应方不支持偏移或已达本地偏移上限时，返回 `coverage=local_limit`、空 next_offset；不能据此认定全库已查完。旧的未超限页面合同保持兼容。

验证包括官方 33 字段文档样例、值中性的同结构 fixture、固定官方 CLI 的隔离命令、Swift 严格校验/往返、聚合有界续页和 Mio 输出。丰富合法样例通过实际 CLI、包含合成凭据的私有输出、原生 DTO/owner wire、Mio adapter；真实 consumer 验证 tools/list 及改动拒绝。合成数据不等于真实供应方验收；2026-10-14 正式 build66 已核真实公开搜索：20 首均返回业务块，text/structuredContent 相同，原账号 ready；不读取私人库、不写歌单。独立 alias/发行时间/版次字段未由本轮已读合同证明，后续须按真实 commands/help 接入详情再验证。
