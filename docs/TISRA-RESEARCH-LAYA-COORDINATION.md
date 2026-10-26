# Tisra research / Laya integration coordination

Current source update: typed research payload/run/receipt/CAS and a standalone
Swift6 wrapper are now implemented and tested in isolation. Exact authoritative
source contract: [TISRA-RESEARCH-API.md](TISRA-RESEARCH-API.md). This is not an
installed/published API or real inference acceptance. The draft-0 sections below
are retained as historical design context; their “not implemented” labels no
longer describe the implemented research transport. Laya remains unimplemented;
local-model work is cancelled. Codex text remains incompatible with Responses.

2026-10-01（Asia/Shanghai）。消费侧依据：`/Users/<user>/Repository/Tisra/docs/ARL-TISRA-CONTRACT.md`，SHA256 `4b5b7d5abc13ecaa9f3556dd349d256bfa944186c2c16ba1b37621278dfcb7b8`。本文是现状核对和 **draft-0** 协调方案，不是新 API 发布、生产授权或可调用推理承诺。

## 当前确实可消费的接口

- 已安装 `0.1.1-a0b5138d84c5f712`，profile `metadata-only`。固定 home `~/Library/Application Support/ARL`，Unix socket `runtime.sock`，协议 `arl/1`；capability descriptor version1，settings snapshot schema2。生产 `execute_jobs=False`，Tisra 私有 methods/tools/providers/budgets 为零，产品 verifier 未登记。后台 ready 与 Tisra 已验证/已授权是三件事。
- `examples/ARLClient.swift` 是真实 Swift6 传输 SDK，SHA256 `20ce4e56e9967a9bce412bbdc9c1c9593013fdea84b8493065c4901c26c470d6`。提供 `rpc/connect/submit`，单调整体 deadline、退避和用户停用语义；本轮保持此文件冻结，未新增研究 SDK。
- 请求严格是 `{"protocol":"arl/1","app":"tisra","method":"...","params":{...}}`，未知字段拒绝。现有方法：`capabilities/providers/submit/get/cancel/resume/heartbeat` 等，由实际身份与 AppPolicy 共同 gate。`submit` params 是 `{tool,args,key}`；`get/cancel/resume` 是 `{id}`。现有 job projection 只有 `id,tool,state,attempts,result,error,updated`，**没有 owner/run/requestHash/epoch/provider-format 回执合同**。
- `integrations/tisra/TisraRuntime.swift` 是 default-off 显式 action 示例，只有 ping/digest 示例；不替代 PreparedResearch/Ledger/Responses 语义。Tisra 新消费代码以其真实 repo 为准，此处不改它。
- 现有 `model.complete` 参数只有 `provider/model/prompt/max_tokens`：prompt schema≤1024字符，router 还检查≤1024 UTF-8字节；tool token range8..512，普通默认 app 上限256，生产上限0。没有研究、multipart、tokenizer 计数或 Responses/encrypted reasoning adapter。不能通过提高预算使它兼容512KiB研究。
- 现有 Laya 只读 `/health`、推理 `/classify`，任务 `home_route_classification`，label `simple/complex/ignore`。它不是提醒/研究意图分类，confidence 不是 Tisra task probability；生产推理关闭。
- **帧细节纠正**：当前服务请求硬限16384字节（含换行），tool result 编码硬限65536字节；完整 RPC 响应外层没有统一65536字节检查，Swift SDK receive cap131072字节。新研究合同须另行对完整请求/响应帧落实16KiB/64KiB，不能把现有 result cap说成完整回复帧保证。

## 拟议分块合同：arl.payload.v1（尚未实现）

所有对象的 owner 来自已核验 transport peer，绝不由 JSON owner 声明授权；即使 ID不可猜，也必须同 owner核对。无任意路径/URL、文件扫描或整库入口。所有对象/schema `additionalProperties=false`，哈希64位小写SHA256，UUID规范化小写；拒绝非整数、负数、重复/未知字段、非法base64、非完整UTF-8和超限，不能修补/截断后执行。

| 拟议 method | 严格 params / 行为 |
| --- | --- |
| `payload.begin.v1` | `{purpose,run_id,epoch,sha256,byte_count}`；purpose仅 `tisra.research.request.v1` / `tisra.intent.input.v1`。request最大524288 bytes；返回随机opaque `payload_id`,expires_at_ms,chunk_bytes=8192。draft staging TTL900秒，固定server策略而非caller任意留存 |
| `payload.write.v1` | `{payload_id,index,data_base64,sha256}`；分块原始字节≤8192，index连续；相同index+相同内容重试返回原确认，相同index不同内容冲突。总数/内存/未封存对象按owner限额 |
| `payload.seal.v1` | `{payload_id,sha256,byte_count}`；验证总字节/完整hash/连续分块；sealed immutable，不能写或覆盖。返回同一object descriptor |
| `payload.read.v1` | `{payload_id,offset,limit}`；limit≤32768原始bytes（base64约43692），完整回复帧仍≤65536；仅同owner且有效对象，无整段1MiB JSON回复 |
| `payload.revoke.v1` | `{payload_id}`；幂等撤销，后续提交/读取拒绝；已开始外部推理不冒称被停止 |

sealed request提交时事务内pin到唯一run，避免TTL清理与claim竞态；执行开始前过期/撤销则不调用provider。提交后撤销使该run失效，原迟到结果不能完成研究。response最大1048576 bytes，经同一owner隔离blob读取；草案结果TTL24小时，过期仅返回 `payload_expired`/不可用，不触发新推理。幂等run tombstone与blob TTL分离，删blob不能让旧key重新执行。具体owner并发/总存储与retention预算要在实现+审查时公布，不把本草案当成已实施的数据留存策略。

## 拟议研究工具：tisra.research.v1（尚未实现）

保持现有 `submit` framing，`tool="tisra.research.v1"`，key≤128字符，映射同一已审阅执行UUID；strict args候选：

```json
{
  "schema_version": 1,
  "run_id": "<reviewed-execution-uuid>",
  "epoch": 0,
  "request": {"payload_id":"<opaque>","sha256":"<64hex>","byte_count":524288},
  "provider": "<explicit-registered-provider>",
  "model": "<exact-model-fingerprint>",
  "request_format": "<registered-provider-request-format>",
  "output_format": "<registered-provider-output-format>",
  "history_version": "<registered-history-format>",
  "max_output_tokens": 4096
}
```

512KiB applies ONLY to the original immutable OpenAI request bytes, excluding descriptor/manifest, JSON and base64 transport overhead. Separately bounded metadata binds request_sha256 and evidence/parent identifiers; no source-budget shrinkage or provider-body reserialization. Request/output/history versions are negotiated independently, not inferred from the consumer semantic ID openai.responses.v1. Output token1..4096 still needs an actual provider hard budget.

同一 owner+logical key 绑定唯一run。重连仅返回原run/当前回执；semantic digest绑定完整request hash、run/epoch、provider/model、format/history及预算，不因重新上传的opaque handle不同而重复执行。相同key但上述内容不同为冲突。研究工具非幂等：进入外部调用后异常/timeout/crash不自动重发，持久 `needs_review` 与未知上游完成度；只有明确新审阅动作才创建新的执行UUID。

完整新回执须有固定schema：`schema_version,job_id,owner,run_id,request_sha256,epoch,state,provider,model_fingerprint,request_format,output_format,history_version,result_ref,error_code,cancel_requested,external_stop`。`result_ref`为空或 `{payload_id,sha256,byte_count}`；正文通过分块读。owner为服务器事实，用于消费匹配，不作为授权凭据。error仅有限code，不能回传prompt、secret、上游异常文本。state使用当前队列枚举：queued/running/succeeded/failed/cancelled/needs_unlock/needs_review；unknown执行度单列，不造假succeeded。

必须新增研究专属取消/获取或严格typed SDK wrapper：以 job/run/epoch核对取消并事务内标记run失效；只有相同epoch且未cancel/revoke/expire时才可发布result。取消ack表示已收取请求，`external_stop`必须 `unknown`/`confirmed` 等真实证据，不能把OS取消当上游停止。**现有通用worker明确允许非幂等完成结果在迟到cancel后succeeded，并且没有epoch，因此不能直接承担此Tisra语义**；需要研究结果发布CAS/隔离迟到结果，而非只让UI隐藏。

如果request_format是 `openai.responses.request.v1`，只有真正的Responses adapter能接受；完整回执使用 `openai.responses.envelope.v1`，原上游body及encrypted reasoning lineage必须保真校验。当前没有该adapter，不存在可用版本或计费批准。其他provider只能声明它真实实现的request/output/history版本；Tisra显式迁移解码/历史格式，不能把字符串包成Responses。版本名字也是草案，发布前双方freeze并以capability/schema digest发现。

## 拟议Laya工具：tisra.intent.classify.v1（尚未实现）

输入仅明确授权局部段落；普通typing默认零调用。拟议strict args：`schema_version=1,task="tisra.intent.v1",run_id,epoch,input_ref,model_fingerprint,task_fingerprint,max_input_tokens`；input_ref同opaque/hash/count，指向purpose `tisra.intent.input.v1`，包含固定locale/timezone/reference_time以及当前局部原文，不含整个Ledger。model/task fingerprint绑定权重/adapter revision、tokenizer、完整template、候选顺序与任务schema；不接受自由prompt-template/labels。

固定intents：`remind/research/recall/ordinary/unknown`。返回：`schema_version,run_id,epoch,input_sha256,task_fingerprint,model_fingerprint,tokenizer_fingerprint,input_tokens,max_input_tokens,status,intent,calibration,time_state,error_code`。status至少 `classified/unknown/input_too_large/unavailable/unsupported_task`；失败或未校准不得classify成强肯定。time_state：`not_applicable/explicit/incomplete/conflicting/dst_ambiguous/dst_nonexistent/unknown`；明确时间只能在真实解析/时区证据成立时给出。

完整tokenizer count必须覆盖原文、固定template、选项及所有special tokens，推理前准确计数，超限直接拒绝；mock计数不等于真实tokenizer。calibration只有原生任务输出和固定验证集revision才可给，未知为null；家居route confidence不能迁作提醒分数，门槛不为demo调低。Laya是否支持新任务及准确时间状态仍需实际本地provider实现/验证，不靠标签改名。

SDK/action coordinator须携带run/epoch/input hash；IME composing、局部文本变化、opt-in撤销、取消或新revision使迟到结果失效。分类至多打开现有ReminderView候选审阅，不能自动写EventKit、创建研究/标签/checkpoint。时间解析可作为独立有类型纯代码模块，不能假称Laya已理解时间。

## 发布与验收门槛

1. ARL纯代码：payload存储/TTL/revoke/预算；两个strict任务schema与真正typed Swift wrapper；研究receipt/CAS取消/持久未知执行度；精确tokenizer任务adapter与provider格式版本。新模块先独立测试，不改冻结UI/client或Tisra WIP。
2. 受信宿主：已有 SignedPeerVerifier 可用LOCAL_PEERTOKEN+Security cdhash/严格team+identifier requirement；已有ControlledSupervisor适合固定host创建的进程，绑定源文件pin/PID/birth。Tisra已运行native bundle优先签名pin；ad-hoc每构建重审cdhash，identifier-only或通用Python解释器路径不可授权。没有RPC自注册。
3. 正式host组合同时装verifier + AppPolicy narrow工具/method/provider/call/pending/token/byte预算；明确Tisra新payload权限，execute_jobs启用仅相应工作。签名身份不等于模型或数据授权。metadata-only不能由caller flag变生产执行profile；发布新的已审host后才会出现可发现接口。
4. 隔离真实runtime+Swift consumer：最大512KiB/1MiB、多字节/分块重试与冲突、完整哈希保真、跨owner/spoof拒绝、TTL/撤销/崩溃、同key恢复零重发、未知外部副作用needs_review、epoch/cancel/expire竞态与迟到回执、unknown/schema/model/tokenizer漂移。保存明示真实/模拟证据。
5. 实际允许的本地Laya task与研究provider：确认已有模型/任务/context容量，授权标注样例评估提醒/ordinary/unknown与IME/time/DST，真实调用证明不是lexical/mock/home route。16GB策略按需单provider，不下载新模型、不auto paid fallback。调用本身与具体预算/模型启用由用户另外批准；OpenAI/Codex付费与credential操作未被本消息批准。

当前可对接的是状态/传输/隔离身份基础，**没有可直接提交的tisra.research.v1或tisra.intent.classify.v1**。此次只增加协调文档，不改安装服务/core/UI/Tisra或调用模型；下一步实现上述缺口后，才能freeze实际schema与SDK版本并发给消费侧。

Consumer follow-up: source Codex tool format is codex.appserver.text.v1, not Responses. It cannot accept this raw request/history contract or provide a4096-token upstream hard cap. The typed research payload/owner/run/hash/epoch receipt and cancellation CAS remain unimplemented. Local-model trial was cancelled before any download/inference.
