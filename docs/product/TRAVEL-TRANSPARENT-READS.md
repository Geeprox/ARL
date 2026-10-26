# 旅行透明适配

范围为现有高德11项与飞猪航班/酒店查询，不新增订单、支付或其他能力。ARL 负责连接、授权与有界传输，不对旅行结果二次筛选、重排、猜价格或补业务含义。

## 结果合同

`TravelReadResult.schemaVersion=2`；原有 toolName/state/fetchedAtMilliseconds/notices 等顶层键保留。payload 改为供应方业务 JSON 本身，旧的 geocodes/routes/hotels 等固定 DTO 包装不再作为原始结果。只消费旧 DTO 的调用方应按版本改读原始 payload。原生 Mio 目录、精确消费者和输出适配器已同步；成功与失败的 text/structuredContent 内容相同。

高德保留整份 JSON，包括 status/infocode/errcode、总数、建议、地址、电话、polyline、空数组与新增可选对象。飞猪保留经过协议校验的首选业务对象，包括总数、分页、供应方链接和新增字段；优先 structuredContent，缺少可识别业务对象时使用 text JSON。来源由 adaptation.response_kind 标明，不声称整个 MCP 传输信封都是业务数据。双表示中的已消费业务状态/data/error 不一致仍拒绝；不把匹配错误的响应当成功。

JSON 字符串、布尔、整数、数值、null、数组与对象保留。新增整数/无符号整数/decimal 表达避免原生 HTTP 大整数先转 Double。移除旧2048字符、固定10/20/50/200条及温湿度/供应方时间格式的业务限制，不再把空数组转 nil，也不把数值统一转字符串。合法可选字段演进不导致整次失败。

HTTP 状态通过 http_status 独立保留；安全的供应方代码与解释保留在 payload。未知骑行 errcode 是供应方拒绝，不再统一称服务不可用。业务失败不自动重新登录、重试或更换条件。无法通过协议完整性校验的响应仍明确失败；已知 HTTP 状态可保留。

## 请求合同

以[公开工具目录](../mio-tools.json)为精确接口，所有请求仍走固定只读端点、原有账号和 TLS。高德只固定 output=JSON，明确列于 injected_defaults；不再注入 citylimit=false、radius=1000、type=1 或 source 标签。未填参数由供应方默认，不代填业务筛选。weather 的 adcode/mode 为兼容别名，映射 city/extensions；冲突参数明确拒绝。

高德开放现有端点实际支持的城市、范围、分页、返回范围、策略及时间等选项。URL 查询参数按传输需要表示为字符串，值不拼接、不猜测。textSearch 接受 keywords/types 至少一项，transit 的 cityd 不再强制。

飞猪保留现有 snake_case 名称，映射供应方 camelCase；数值参数显式转换为供应方数值，兼容旧 journey_type/sort_type 字符串。航班支持已核日期范围、小时范围、最大时长等选项；limit 可显式给出，未填不再强塞10。固定 CLI 1.0.16 与当前官方参考均未提供 page/pageNo/offset 证据，不伪造上游分页。航班 origin、酒店 dest_name 为已核必要参数，其余由供应方处理。

参数依据：[高德 POI](https://lbs.amap.com/api/webservice/guide/api-advanced/search)、[路径](https://lbs.amap.com/api/webservice/guide/api/direction)、[地理编码](https://lbs.amap.com/api/webservice/guide/api/georegeo)、[天气](https://lbs.amap.com/api/webservice/guide/api-advanced/weatherinfo)、飞猪官方[航班](https://github.com/alibaba-flyai/flyai-skill/blob/main/skills/flyai/references/search-flight.md)/[酒店](https://github.com/alibaba-flyai/flyai-skill/blob/main/skills/flyai/references/search-hotel.md)及固定官方 CLI 源码 SHA。未升级 CLI、协议签名或持久权限。

## 本地分页与限制

供应方原始 page/offset/total 等字段保持原值。单次业务响应超过 owner 帧时，按完整 POI/路线/航班/酒店等条目生成本地页；每条的字段完整保留，排序不变。adaptation.item_path/source_item_count/returned_item_offset/returned_item_count/partial 说明本地切片；next_cursor 与 local_continuation_end 只描述这份已取响应，不代表供应方全库完成。

续页不重查供应方；采用最多300秒、8个条目、总计4MiB的内存快照，不新增磁盘数据。游标单次使用，绑定精确供应方参数、工具、凭据及 owner 租用的授权代次；续读仍验证部署门和有效凭据。参数/授权改变、过期或容量淘汰后明确要求重新查询，不返回别的账号数据。取消、撤销和进程重启不能绕过原 owner 检查。

保留1MiB供应方 HTTP字节预算和256KiB owner 帧预算。无法容纳的单条或非列表对象明确返回 responseTooLarge/failure_reason 且不发空循环游标；不静默删字段或伪称空结果。可信结果解析给外层包装保留有界32层深度，入站请求仍为16层。容量/超时是本地限制，不能说成供应方没有结果。

## 认证与诊断

复用三服务的明确认证键与认证上下文规则，保留普通业务 session/signature。OAuth URL 的 query/fragment、用户信息和固定认证 API 的签名参数隔离；普通公共链接中的业务 signature/key 保留。已知账号密钥、实际请求认证头和签名材料反射到响应时隔离，并仅记录 omitted_authentication_fields 类型。未知任意业务数据无法仅靠键名规则证明绝对没有秘密，不作此保证。

不记录请求正文、地理查询、酒店/航班候选、账号或整份响应日志。必要状态、来源、时间和本地分页在当前工具结果中可查。既有验证登录、权限和读请求状态边界保持分离。

Keychain 新条目使用稳定的用途标签，独立于界面显示名。旧条目只接受明确的发版历史标签，继续核对服务、账号、nonce、持久引用、原始元数据和 ACL。读取/更新/移除精确查询绑定实际核验的 label，不猜新标签，也不为兼容而重命名或迁移现有条目。

## 验证与 TODO

- 已实现且合成验证：完整字段/JSON类型、大整数、空数组、超长可选字段、供应方错误、实际参数无隐藏默认；60条富字段两页完整往返且只查供应方一次，参数/代次变化拒绝游标，单条超限明确失败。MCP匹配、SSE结束与凭据验证的有限回归另行核对。
- 已实现且正式包回读：build73 完整生产构建、签名、fresh transaction 与启动通过，App/Mio 同为73，Core 源码绑定、全部包文件和原授权范围一致；旧配置未修改。真实连接器音乐读取及 Mio build73 ping 通过。
- 已实现且真实只读验收：build73 的高德天气与地址均为 schemaVersion=2/HTTP200，保留计数、状态、原始天气字段及地址中的空数组；飞猪航班、酒店均为 schemaVersion=2/HTTP200，各保留供应方当前响应的10个完整条目，未注入 limit。四次 text/structuredContent 一致，不代表已遍历供应方全库。此前 build72 的实际 Mio 高德天气与飞猪航班返回 configuration_required，未进入供应方业务读取。后续只读归因已确认：两项原生回执及 Keychain 条目均存在且已验证，引用、服务、账号、nonce、元数据和 ACL 全匹配，唯一失败是旧 label 与缩短后的界面显示名不一致。历史文案提交 d81b0f9 已在 build52/66 中；本轮 v2 没有改变查找路径或命名空间。snapshot 将本地校验异常转成空引用，owner 再概括为 configuration_required，所以不能据此要求用户重填密钥或迁移。标签兼容修复已独立复核并随 build73 正式安装；真实连接器高德天气/地址、飞猪航班/酒店全部成功，text 与 structuredContent 一致。无需重填或迁移密钥。归因过程未读取密钥值，修复未重写既有 item、label、回执或 ACL。
- 远端目录待核：包内20项基础目录及实际 consumer/wire 已验证；当前连接器声明仍为旧缓存，本代 tools/list 回复计数为0，不能声称已重新接收新参数。配置错误在连接器 structuredContent 中另附 error_code，须与包内双表示一致性的合成结论区分；真实业务成功返回的整链路一致性已通过；平台配置错误包装和新参数接收、供应方失败的实网样本仍待单独核验。
- 待开发：上游未来参数/输出变化按真实合同复核；尚无依据的飞猪上游分页不宣称支持；公开分发依赖、许可、签名及 Git历史隐私阻断按现有清单处理。
- 继续暂停：未集成业务、订单/支付、任意宿主执行及其他已暂停产品路线。真实 NAS、信息/备忘业务不属于本轮验收。
