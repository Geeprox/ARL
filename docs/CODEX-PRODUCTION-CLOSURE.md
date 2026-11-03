# 通用应用 Codex 执行闭环 · 2026-10-30

通用应用不再需要借用 Tisra/Friday 的产品接线来验证 Codex。新增 `arl.codex_application` 是显式可信宿主组合：同一个 `CodexService`、身份验证器、持久 Store 和单执行 worker 承接会话、目录、参数解析、提交、结果与取消。默认运行入口仍不启用这个组合。

## 生产宿主接线

宿主先按原流程建立 `CodexService` 和 `CodexCallerPeer`，后者同时验证现有代码签名与已登记的内核 PID/出生时间。调用方不能通过 RPC 提供自己的 grant、签名规则、PID、路径或 provider。已有原生 caller 的集成点为：

```python
from arl.codex_application import compose_codex_application, scoped_application_policy

# service / peer 来自既有经过审核的原生 activation，不从请求构造。
policy = scoped_application_policy(service, legacy_submit=True)
runtime = compose_codex_application(
    home, service=service, peer_verifier=peer, policy=policy,
    isolated=False, service_portal=service_portal,
)
```

默认仅授予已有 explicit 优先级。宿主若确实授予 background/interactive，须在 `priority_bands` 中显式列出；解析请求不能增加这些等级。服务原有限次或无本地次数上限值原样进入 AppPolicy，单 pending 和 30 秒执行期限保持。`legacy_submit=True` 仅保留同一原生 caller 既有 GUI 提交入口，避免升级改变原界面行为。

`Handler` 对 `runtime.application_execution_methods` 使用现有严格 JSON、真实 peer binding 和响应帧预算。默认 Runtime 即使被声明一个方法名也没有该方法的实现；全局元数据方法集合和默认策略没有新增执行授权。新增模块须纳入正式 core source manifest 后随同包构建，不能靠源码文件存在宣称已安装启用。

## 真实执行合同

调用方先 `connection.open/confirm`，再 `application.models.discover.v1` 与 `application.models.request.v1`。解析仍明确为 `resolution_only`，不会排队或调用模型。支持执行的宿主在目录中额外声明 `execution.method` 和 `execution.recover_method`。

`application.codex.execute.v1` 的精确参数为：

```json
{
  "schema_version": 1,
  "session_id": "64位会话标识",
  "request_id": "规范UUID",
  "request_sha256": "UTF-8输入SHA256",
  "resolution_id": "服务器返回的解析标识",
  "input": "本条确切输入",
  "max_output_bytes": 128
}
```

服务器从自己的解析记录提取 model、effort、Standard、priority 和 deadline；提交请求不能另带这些字段来覆盖。它核对会话身份、输入摘要、解析有效期、目录版本、当前 host admission、原生 scope、二进制身份及现有预算，再以原 request UUID 提交到同一个 Store。实际模型线程和 turn 必须确认相同 model/effort/tier；最终结果核对 thread/turn、输入/输出摘要及 completed 终态。

重复请求保持同一个 UUID/正文/排程，返回同一个 job，不重复扣预算。响应丢失或应用重连后调用 `application.codex.recover.v1`，仅传 schema_version、当前 session_id、原 request_id 和 request_sha256。它按原 owner/UUID 查已有持久 job，复用正常私有结果授权，不创建新任务、不续 deadline，也不重放。旧的运行中非幂等任务经原 Store 恢复为 needs_review。解析记录无需增加新的数据库表或迁移版本。

取消仍走原 `cancel`。interrupt ACK 与同一 thread/turn 的 interrupted 终态分别核验；只有两者成立才记录该项取消验收成功。取消不宣称退还供应方额度，也不保证即时停止。

## 可复现验收

默认离线：

```sh
python3 -B script/check_codex_production.py \
  --output build/todo-closure-20261030/codex/neutral-offline.json
python3 -B -m unittest tests.test_codex_production tests.test_codex_server \
  tests.test_codex_execution_options tests.test_scheduling -v
```

离线 runner 启动两个真实独立 Python 消费者，完成启动握手后才由宿主登记当前内核身份。它们经过真实 Unix socket 和真正 stdio 子进程，但 provider 是明确合成的协议 fixture，不接触账户或模型。一次完成、一次 active cancel，分别用 background 与 interactive；每次均关闭旧会话、建立新会话并恢复原 job。2026-10-30 定向运行共 40 tests 通过，含新组合/真实进程、原 Codex 取消/预算、模型选项及持久公平性回归。

受控真实模型验收只由协调者运行，明确指定当前已有配置的 model/effort：

```sh
python3 -B script/check_codex_production.py --real \
  --expected-model <当前配置model> --effort <当前配置effort> \
  --binary <既有Codex二进制> \
  --output build/todo-closure-20261030/codex/neutral-real.json
```

真实模式最多两条 intent：确切返回 `ARL_CODEX_OK`，以及一条只生成合成整数并在 turn ACK 后取消的请求。Standard 固定为 default；只使用既有 ChatGPT 账户，校验当前配置 model，不改账号、配置或正式 grant，不启 API fallback、工具或文件操作。供应方没有可证明的 token/费用硬上限，runner 不作该承诺。失败停止且保留原收据，不自动重新运行。

此 runner 的身份是受控开发消费者，收据如实保留 `production_signed_caller_verified=false`。真实模型通过也不能替代正式原生 App 的签名身份、安装与 GUI 消费验收；正式启用必须采用上面的既有双重身份 host 接缝。源代码测试、真实模型验收、正式应用部署分别记账。
