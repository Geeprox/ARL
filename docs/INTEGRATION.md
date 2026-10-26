# 第二阶段：最小受控接入

核心已运行和验收；让它真正服务 Tisra / Friday 尚需下面的小规模接入。当前未安装后台进程、未修改现有 apps、未持有供应方凭证。无须另造通用 tunnel 或换产品结构。

1. **实际接口已对齐**：Friday已有homeplane.arl.ARLRuntime/runtime_for并引用本ARL SDK，无第二底座；真实adapter在受控隔离进程跑status/ping/mock/dedupe通过。Tisra现有ResearchSession/ResearchService涉及Keychain、ledger及Responses lineage，不能覆盖并行WIP；独立TisraRuntime.swift默认opt-in禁用、显式action稳定key，已编译及真实RPC验收。原repo保持只读。下一步在安全接线点引入模块与状态展示，typed研究合同必须保留现有语义，不能纯文本假造Responses结果。见 [APP-INTEGRATION.md](APP-INTEGRATION.md)。
2. **真实进程身份代码已验**：ControlledSupervisor只启动固定executable/args/cwd/source manifest，核对PID/出生时间/source pin，不信任shared解释器路径；实际Friday adapter受控启动通过。SignedPeerVerifier使用LOCAL_PEERTOKEN+Swift Security动态guest检查，native cdhash pin测试通过，identifier-only政策拒绝。真实Tisra为adhoc签名，稳定生产签名/批准manifest及产品启动方式仍待落实；没有产品持久部署。注册撤销竞态已修复；RPC无注册或创建凭据接口。
3. **双向生命周期落地**：Tisra action → discovery → supervisor bootstrap → ready →任务；Friday在ARL starting期间等待；ARL→固定已注册Tisra bundle/Friday worker的wake callback→进程身份核验→ready handshake→消费inbox。默认停用标志高于所有唤醒。核心 tests已证明并发、竞态、重连和模拟wake；真实native app唤醒要另外验收。当前不存在任意shell/path RPC。
4. **已有本地模型接入**：先定位并复核已有服务实际端口/模型list，再给具体app开放显式任务provider；不启动未知服务、不下载模型。当前固定11434/8811不在线。16 GB M4不保证27B能加载或低延迟；应先获用户指定模型、输出/调用预算和容量验收，再运行极小推理。Ollama/Laya真实adapter已实现、HTTP合同已验，真实推理未验。Codex app-server / Jev保持禁用：需限定只返回结果、不让模型直接调用任意系统工具，以及可执行的任务/账户费用预算后才写正式adapter；不能用用户开发授权自动消耗额度。
5. **Apple接入**：将EventKitHelper作为具有稳定身份的native helper打包/签名，先只查授权状态；在用户批准后由明确的前台授权flow请求Calendar / Reminders范围。runtime本身永不requestAccess。连接必须已有peer身份验证；只对原owner开放私有结果。calendar限定31天100条，reminders限定未来31天未完成100条。真实数据、锁屏操作和TCC身份尚未验收。Notes暂无写工具；在获准独立测试笔记中先测原生追加候选、富文本/附件/并发保真，禁止回写整篇body冒充append。
6. **Mio兼容接入**：唯一既有 tunnel `<USER_TUNNEL_ID>` 与插件 `<USER_PLUGIN_ID>` 继续复用；不另起同tunnel客户端、不增加key。适配现有服务内部transport，保留12工具+ping的名称/schema/result envelope。`TravelAdapter`仅接收host注入的已批准transport，默认供应方调用被身份和transport两道gate拒绝。生产旅行服务不就地迁移：未来发布前审查adapter、健康/12schema兼容、原旅行端到端和rollback，在具体范围获批准后仅更新对应已审文件，凭证保持原位，不能复制或输出。当前只读schema已保留，未调用供应方或重启生产。

### 需要单独明确批准后才能部署的范围

| 项目 | 明确授权内容 | 可撤销/验收方式 |
|---|---|---|
| ARL后台长期运行 | 安装位置、具体用户LaunchAgent、登录自启/故障重试、状态目录与日志留存；不默认root daemon | bootout与移出plist、保留disabled；前台/重连/24小时稳定性检查 |
| 应用登记/信任 | 固定真实Tisra和Friday二进制/目录、签名或受控supervisor登记、允许工具；若采用per-app凭据，另批准配置 | 取消注册/撤销信任，未登记进程拒绝 |
| Apple私有数据 | Calendar/Reminders具体读范围及helper身份；Notes/Shortcut另批 | TCC撤销、app allowlist移除、独立测试对象验收 |
| 旅行新能力发布 | 同一服务内部兼容adapter与同一插件新增能力的具体schema、回滚步骤 | 先保持旧旅行路径，明确刷新工具和端到端复核 |
| 模型推理及费用 | 用户/任务/provider/model/预算，Codex/Jev额度另批 | 禁用路由/调用cap；无默认付费fallback |
| 电源长期条件 | 接电防系统自动睡眠，允许显示器关闭；温度/能耗影响 | 恢复原电源项；不禁用锁屏/FileVault |
| 新远程入口 | 任意SSH、远程控制或持久访问范围 | 当前一律未启用；不是前台开发默认授权 |

真正系统睡眠会暂停普通进程；注销结束用户会话；FileVault首次解锁仍需人工恢复。当前Mac已登录且锁屏时shell和旧旅行health成功，不证明所有Apple/UI能力都能锁屏运行；当前其他进程的NoIdleSleepAssertion不是ARL长期保证。状态文档明确未做重启/锁屏/睡眠实机测试。

后续家庭iMessage通道只作为独立typed adapter扩展点；父任务研究建议未来复用imsg独立RPC，使用明确的applescript transport与已批准群范围。未安装、未读取消息、未启用private bridge、未关闭SIP。此项不属于当前实施或权限范围。

Friday集成保持真实现状：HA在内网NAS；BE6500Pro/米家极客版作为现有中枢；已有NAS录像只读复用，不复制全天录像；HomeKit/Siri并行，网关规则不搬到Mac。Qwen3.8-27B需求保留为可明确选路的Ollama模型目标，16GB只是按需加载/容量验收约束，不删除目标模型。以上背景不增加本轮实现或权限。

设置界面有专属settings ID与只读overview，见 [SETTINGS-API.md](SETTINGS-API.md)。默认公共元数据不等于Tisra身份；没有可写配置或自动授权API。UI由独立任务负责。
