# 网易云透明适配

ARL 代理服务调用与授权，不替调用方做音乐判断。此次范围只有网易云；不增加语义专辑判定、课程策略、录音评分或新的写入操作。

## 请求与兼容

- `mio_netease_song_search` 保留公共搜索及 offset 合同。
- `mio_netease_song_search_unified` 保留公共曲库加当前账号云盘，响应 `search.version=3`。
- 公共请求只发送原始 `keyword`、已核供应方支持的 `limit/offset`。不拼接 artist/album，不按本地文本、艺人、专辑、原唱标签或版次过滤、排序供应方候选。
- `artist/album/recording_version` 继续接受以兼容旧调用，但不生效；`search.unsupported_parameters` 明确列出。需要这些词时由调用方明确写入完整 keyword。
- `field` 仅选择云盘本地检索字段。云盘对 keyword 做大小写、重音、全半角折叠，全部空白分词须在实际返回的对应文本中出现。缺少元数据不能把完全无关条目变为候选。该匹配是本地算法，非供应方搜索结论。
- 每次返回先保留当前公共页顺序，再按资源 ID 的固定顺序返回云盘命中。不同来源独立成行并保留 `source_records`；同 ID 不证明录音身份，也不合并成已核录音。
- `identity_assessment=deprecated_not_assessed`、`recording_identity_confirmed=false`、`query_unknown_fields=[]` 为兼容字段，不再参与选择；false 表示 ARL 未评估。`search.deprecated_fields` 说明旧字段语义，`matching_complete` 仅指本地关键词评估，不代表身份或全库覆盖。

## 原始记录与安全

公共搜索、云盘、歌单歌曲新增 `provider_record.fields`，保留供应方歌曲对象的字段名、值与 JSON 类型，包括 null、空数组、未知业务字段。旧 metadata/business_info 继续提供兼容视图，不能覆盖或代替原始记录。聚合的 source_record 持有对应供应方记录。

不复制响应外层认证信封。歌曲对象内按明确认证键和认证上下文隔离字段，检查 URL query、fragment 及用户信息中的认证材料；普通 recording.session、artist.signature 保留。已识别的认证字段及 URL 剔除后，`omitted_authentication_fields` 仅列认证类型；已知本机会话材料仍在桥接输出边界检查。凭据只在原有 owner 私有通道流转，不进入 Mio 结果或日志。键名策略和已知秘密扫描不能证明任意未知业务内容绝对不含秘密，不作此保证。读写授权、TLS、固定端点与写入恢复门保留。

`fullArtists` 为非空列表时优先用于兼容艺人视图；其为 null/空数组时可使用实际有效的 ar/artists。原始字段仍各自保留，备用字段不伪装为完整艺人列表。专辑的 al=null 不吞掉有效 album。非空但含缺失姓名的 fullArtists 不伪装成完整姓名列表，原始内容仍可查。

2026-10-15 读取官方[关键词搜歌](https://developer.music.163.com/st/developer/document?docId=b175e0d52550427cbb7cd4735a9de765)与[歌曲信息](https://developer.music.163.com/st/developer/document?docId=b8bdaa8e40b946ecbc1d08978f3f12b0)文档：duration 仅标 long/时长，未标单位；fullArtists 为包含已下线的全部艺人。故 duration_raw 保留原值，duration_unit 仍未知，不按数量级猜毫秒。旧 recording_edition=null/not_requested 只说明兼容投影未另查版次，不能据此认定原始业务记录没有版次信息。

## 分页与缓存

公共搜索超过真实私有帧或原生结果预算时，按完整歌曲续页，offset 按实际返回数量推进。字段不裁切。云盘 cursor 不能代表被截断的半页：超限时在同一个上游 cursor 请求更小 limit，采用该完整供应方页及其 cursor；后续沿用该 limit，避免重复大页。聚合按包含来源、状态与游标的真实完整响应编码测量，能由 owner 帧承载的大单首整首返回。单项本身超过传输上限时返回 response_too_large/output_failure 且不发续页游标，避免空页循环；不伪称空结果。公开统一入口只用 `search.next_cursor`，原样保留查询参数；公共 offset 不能恢复聚合进度。

现有账号/代次隔离、内存索引、12小时刷新与失败退避、容量/时限、列表遗漏保留和 stale/partial 状态继续保留。原始业务记录会增加缓存与响应字节，因此可能更早触及现有容量；状态必须如实表达，不能声称已遍历全库。来源状态的 read_attempts 是 owner 读步骤数，不包含单步骤内部缩页请求。

## 诊断与验收

最少请求关联日志只含 owner request_id、工具名、参数 JSON 的 SHA256、build、耗时、响应字节、歌曲数量、complete 与续页是否存在。默认不记关键词、候选、整库、账号或凭据。provider 有限诊断通过 request_id 关联。摘要可比对一次已知请求，不是请求内容备份，不能用于追溯恢复旧调用参数。

已实现并通过合成验证：33字段原样保留、额外业务字段/JSON 类型、null 备用字段、认证剔除、公共顺序、缺元数据的无关云盘排除、同 ID 独立来源、90条聚合续页与50首富字段云盘完整缩页。Beatles 固定案例验证 keyword 原样、旧过滤参数明确未生效及 Remastered 不被 ARL 总判冲突。真实账号结果须在独立审阅、正式包安装后限定核验；不能把合成数据当实机验收。

正式 build73 已安装并完成 App/Core/Mio、签名库存与原授权范围回读。实际连接器 Mio 的 Beatles 公共搜索为 authorized_read，返回20条，首条 provider_record.fields 保留39个供应方字段；text 与 structuredContent 相同。Mio 远端 ping 回读 build73。此证据来自连接器，不是本机直连替代。

待核验：真实富字段公开续页、统一搜索的账号云盘与缓存边界。私人云盘未额外扫描或输出整库。真实歌曲写入、NAS、信息/备忘业务不在此轮验收范围。

## 旅行与后续

高德/飞猪透明适配已实现并独立复核，正式包与音乐一起安装，具体合同见[旅行透明适配](TRAVEL-TRANSPARENT-READS.md)。原审计中的隐藏默认参数、固定 DTO 字段裁切、字符串/条数业务限制、供应方错误丢失与 Mio 双表示问题已有对应实现和合成证据。历史 configuration_required 已通过只读属性核对定位为显示名与存储 label 耦合，并以稳定标签/有限历史别名修复。build73 未重填或迁移凭据，实际连接器高德天气与地址、飞猪航班与酒店均成功，原始业务字段及 text/structuredContent 一致；新参数的远端目录接收仍待单独核验。

待开发：其他适配器逐项按原始业务记录原则审计；开放分发依赖、签名与隐私历史阻断仍按现有公开清单处理。用户暂停项继续暂停，不恢复私有应用或其他产品功能。
