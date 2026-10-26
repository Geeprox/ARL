# 本机验收状态 · 2026-09-30

已安装的 metadata-only release 为 `0.1.1-a0b5138d84c5f712`，真实 runtime PID23017，正式设置 App PID23564已从安装路径重新启动。动态列表实际验收见 [CONNECTED-APPS-ACCEPTANCE.md](CONNECTED-APPS-ACCEPTANCE.md)。v1/v2、资源首次空值→间隔采样、日志筛选/导出、零任务/零推理和只读身份边界已验；见 [CONTROL-UPDATE-ACCEPTANCE.md](CONTROL-UPDATE-ACCEPTANCE.md)。首个安装历史证据保留在 [DEPLOYMENT-ACCEPTANCE.md](DEPLOYMENT-ACCEPTANCE.md)。登录自启已配置，没有真实登录/重启/24小时或睡眠验收。本机 Mac mini M4 / 16 GB / macOS27.0.1，Python3.9.6。无commit/push。

主列表现在只显示已登记、身份核验且有新鲜建联证据的应用，当前真实连接为零；安装版概览AX确认“尚无已连接的应用”。14项专项、46项schema、SwiftUI类型检查和7项隔离真实peer检查通过。名称/版本/SF图标引用来自host描述，不从Friday/Tisra名单或预算生成；历史离线应用不显示。UI/shared client源码已冻结供独立设计任务接手，未开始视觉重设计。

新增控制面 schema2 的限定统一回归：74 tests / 21.798秒 / OK，其中18项新增测试；旧overview schema1保留。资源/已验证应用登记/多态provider/日志边界与凭据、Apple、Friday状态合同见 [CONTROL-API.md](CONTROL-API.md)；逐项真实完成程度见 [CONTROL-MILESTONE.md](CONTROL-MILESTONE.md)。这不是七项完整产品升级已经安装。

此前统一核心验收命令：`./script/build_and_run.sh --verify`。Python bytecode、Swift6客户端/Tisra模块/Security helper、EventKit helper编译成功；**45个tests，14.036秒，全部通过，无skip**。当时临时demo也成功：Tisra bootstrap → ready/live → trusted Friday wake inbox →真实text.sha256 succeeded。该阶段服务仅在临时目录运行，结束时停止自己的子进程。

### 真实执行证据

- 8个并发SDK bootstrap，单一真实PID，race loser正常退出；starting时health live=true/ready=false，ready后恢复完成。
- 真进程SIGKILL crash/restart：queued任务恢复；running幂等读只做受限重试；模拟外部写marker保持一次，任务needs_review，重复key不重放。
- 真实RPC取消/退避、同key并发去重/不同payload冲突、响应前断连后同key恢复。
- owner对象拒绝跨owner查询/取消；未知method/tool/app/path/wake/字段/版本拒绝；声明已知app ID仍不能访问默认敏感能力。
- 真实macOSgetpeereid + LOCAL_PEERPID/libproc登记验证：同UID同解释器未知进程被拒绝，错误app声明/错误executable/出生时间变化拒绝，撤销后拒绝。
- Swift6客户端编译并通过真实RPC调用SHA256；可信host启动并登记真实Swift进程的调用也通过，无凭据。
- 主动stop的disabled跨进程持久保留，SDK不自行拉起；显式enable才解除。
- 启动尚未ready时主动stop立即生效，不等模型/恢复初始化完成；客户端仍遵守持久停用。
- 持久调用预算跨重启保留，去重不重复扣；pending queue cap拒绝；模型输入字节/输出上限/未知付费路径均服务端拒绝。
- 恢复任务重新检查已移除能力，futureSQLite schema不覆盖原数据。
- EventKitHelper编译并实际查询授权状态：calendar=not_determined、reminders=not_determined、prompts_requested=false，**未读任何真实Calendar/Reminders内容**。
- 同刻父调查确认机器已登录并锁屏，shell和原旅行health可用；本项目不锁/重启真实Mac作测试。

### 模拟执行证据

- mock model路由明确标simulated=true，不冒充真实推理。
- Ollama真实adapter的HTTP请求/输出cap/无pull/模型缺失拒绝，用loopback server double验证；Laya真实adapter的health/classify及仅返回决策证据，用double验证。
- Apple已有权限/needs_unlock/resume和私有结果identity gate用transport double；不是原生数据访问验收。
- ARL→Friday host callback和双向durable inbox用模拟应用验证；不是原生GUI app唤醒验收。
- 外部写副作用用临时marker，证明恢复策略，不证明真实Notes / HA动作exactly-once。
- Mio13工具schema与result envelope/ping/日期校验已验证，未调用真实供应方。

### 当前明确阻塞 / 未验收

| 项目 | 准确状态 | 最小下一步 |
|---|---|---|
| Tisra/Friday真实产品接入 | 真实Friday现有adapter和独立Tisra模块已跑隔离RPC；原repo只读 | 将opt-in模块接入允许的Tisra状态/action边界，保留research ledger；批准具体产品manifest/部署后接线 |
| Ollama/Laya真实模型 | 只读检查固定11434/8811均unavailable | 查已有实际服务配置与运行条件；用户明确模型/预算后再做容量及极小推理验收 |
| Codex/Jev | Codex已安装；两个付费路线disabled，正式推理adapter未接通 | scoped result-only adapter +可靠预算/单次明确模型额度授权；不得自动付费fallback |
| Apple真实能力 | helper可编译运行，授权not_determined，transport未生产启用 | 稳定helper身份，明确批准TCC范围，真实数据/锁屏逐项测试 |
| Notes保真 | sdef调查完成，无编辑工具 | 独立测试笔记的原生追加候选、富文本/附件/并发验收，勿整篇body重写 |
| Mio生产接入 | adapter_only，无生产迁移；原服务不改 | 同一tunnel/plugin内审查兼容adapter与rollback，具体批准后发布 |
| 7×24 | 当前用户LaunchAgent已批准安装；停用/恢复/service-only restart实测；睡眠设置未改，FileVault首次解锁仍需人工 | 24小时稳定性和睡眠策略分别验收/批准；不能把登录自启配置冒称真实重启或7×24已验 |

代码和编译验收不等于原生产品功能/权限验收。运行环境调查依据父任务报告：`/Users/<user>/Documents/Codex/2026-09-30/task-5/mac-lock-runtime-investigation.md`。接入与批准清单见 [INTEGRATION.md](INTEGRATION.md)。

### 边界与剩余工程工作

单执行worker限制并发/内存，最长本地模型HTTP等待30秒，尚无模型子进程隔离/优先级。job / tombstone /调用预算长期增长，生产部署前需留存/容量与预算刷新策略；audit固定最多10000行。受控supervisor/source pin及native audit-token签名核验真实有效但未产品部署，注册volatile。wake inbox消费并删除，offline launch默认没有adapter，不能承诺exactly-once delivery。数据库是权限保护的本地明文，不是加密凭据库。

### 审查与本轮增量

独立复核task-7/ARL-fix-verification.md已关闭原1项条件P1+4项P2，32现有+12新增负向测试通过，无新增必修P0/P1。持久权限防描述删除/降级泄漏、撤销竞态、外部副作用异常、升级contract漂移、HTTP整体deadline及worker存活时资源保有均有回归。

本轮新增ControlledSupervisor真实Friday adapter和Tisra opt-in模块，SignedPeerVerifier实际Security audit-token核验，settings专属最小只读overview API；5项settings增量覆盖未验证读取范围/所有对象写方法拒绝/伪造owner或app/撤销public read/启动状态和字段筛选。overview不读Apple数据、不启模型、不配置系统。整体45项与编译/demo通过。UI目录由独立任务拥有，不包含在本核心增量审查manifest。

### 历史 Production host 部署准备

metadata-only固定host、release SHA校验、当前用户LaunchAgent模板、安装/更新/回滚/停用/启用/卸载脚本已实现。当前user_disabled正常退出0；SuccessfulExit=false策略避免显式停用重启循环。生产profile不claim/replay历史任务，settings公共元数据以外全部零grant，真实模型/Apple/Mio访问关闭。

限定core+部署回归51 tests / 25.099 s / OK（部署专项14项），包括实际test-installed host的RPC、异常退出恢复/停用/启用；fake launchctl模拟事务，不冒称真实launchd或登录部署已验。UI产物仅只读复制，未修改或重新编译UI/shared client。具体批准范围与固定release见deployment/approval-plan.json，独立增量hash见docs/evidence/production-host-delta-manifest.json。原45项统一验收是此前core阶段记录，本轮没有重跑UI编译/交互。

上述是早期批准前记录。之后的首安装、first-four更新及动态列表窄修分别记录于 DEPLOYMENT-ACCEPTANCE.md、CONTROL-UPDATE-ACCEPTANCE.md、CONNECTED-APPS-ACCEPTANCE.md；历史数据不代表当前版本未安装。
