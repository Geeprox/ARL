# 应用消费模块与前台可信启动 · 0.1.1

本阶段保持 `~/Repository/Tisra` / `Friday` 仅读；确实存在无法安全合并的公开接口边界，不是笼统因WIP而停工。已在ARL中完成可直接消费的模块和真实app栈harness，无需新权限/安装服务/读取凭据。接口文件SHA快照见 `docs/evidence/app-interface-snapshot.json`。

### Friday：复用已存在的新接线

`~/Repository/Friday/homeplane/arl.py` 已直接导入本ARL SDK，协议arl/1；`.venv`实际arl模块路径是本任务ARL，没有另一底座。默认home是`~/Library/Application Support/ARL`，只有status(start=True)才bootstrap，run_job只认runtime.ping/model.complete，已限时、取消、丢弃晚结果、禁止设备authority进入ARL。没有复制它的传输代码。

`integrations/friday/smoke.py` 在真实Friday `.venv`解释器里导入这个模块，连接临时ARL，运行status/ping/mock complete/相同key去重。harness由 `ControlledSupervisor` 固定脚本/解释器/cwd/源文件SHA启动，先阻塞host gate，登记内核PID+出生时间后才开始RPC。每次RPC仍复核pinned source set。真实SDK+现有adapter测试通过，不读取Friday配置、HA/米家凭据，不调用设备/模型。

现有 `friday/providers.py` 的ARLPlanner明确拒绝大于1024字节的完整plan schema/context；formal家居task decision也缺少上游typed task contract，不能把routing confidence当动作许可。下一步应与现有接口共同实现有类型`plan/decision`能力、预算和校准合同，不能在Friday偷偷截断或另起直连模型fallback。当前mock输出不会进入真实家居动作。

### Tisra：独立Swift6 opt-in模块

最小可消费文件为 `examples/ARLClient.swift` + `integrations/tisra/TisraRuntime.swift`，放进真实Mac target即可编译（只针对Mac，不加入共享iOS target）。默认enabled=false；构造/refresh/typing/autosave不会启动runtime或调用模型。refresh只读取已有服务health/capabilities，明确disabled/offline/starting/ready/userStopped/unverified/failure。

在显式action确认后才创建immutable `ReviewedARLAction`，保留原action UUID，`submit`将它映射为稳定owner key；receipt/cancel/wake inbox可供UI消费。测试使用非敏感ping/SHA256，不显示假研究结果。trustedLauncher closure仅来自审查过的安装代码，不能来自输入正文、RPC参数或用户任意路径。

当前 `ResearchService.submit(prepared, apiKey)` 先在Ledger原子预留研究身份，再用`ResearchTransport.send(Data,apiKey)`和OpenAI专用response/encrypted lineage/citation envelope解码；`ResearchSession.submit()`还直接读取Keychain。替换这三个正在修改的文件会改变已审阅bytes/状态/凭据语义。ARL没有提供相等的研究合同，故本轮不把普通model.complete伪装成ResearchTransport、不伪造Responses envelope，不改其默认provider。下一步可用独立ARLResearchService适配Ledger begin/finish与通用ResearchResponse；须保持原事项/path/provenance/取消和不确定状态，明确选择provider，不迁出作者文本。

### 真实macOS身份，不靠通用解释器名字

1. 已有 `RegisteredPeerVerifier` 适合由可信host掌握的进程，generation/revoke线性化；不能用进程名扫描或让RPC自注册。
2. 新增 `ControlledSupervisor` 只消费本地host构造的immutable LaunchSpec：受信app ID、固定executable/arguments/cwd、明确源文件SHA和少量非凭据env。先验证hash再启动，gate后再核验出生时间/实际executable并登记；源码变化拒绝launch并使RPC身份失败。它仅管理自己创建的子进程，close撤销并停止这些子进程。没有远程命令/路径/注册API，也不会安装launchd。Python产品身份来自受控launch+审查过的entry/package source set+内核PID/birth，不是“这个解释器的所有进程都可信”。
3. 新增 `SignedPeerVerifier` + 可编译 `apple/PeerSignatureHelper.swift`，使用内核LOCAL_PEERTOKEN和Security动态guest check；audit token带PID版本，避免仅PID重用。host requirement仅允许完整固定cdhash，或者严格的identifier+Apple signing anchor+10字符team组合，拒绝identifier-only/自由or表达式。声明app ID不能替换requirement。
4. 本机Tisra开发bundle只读签名元数据是ad-hoc、无TeamIdentifier，designated requirement为cdhash；本轮没有启动或修改该bundle。每次新build cdhash会变，须审查并更新pin；不能把`app.tisra.dev` alone作为长期安全身份。正式Team/证书策略未配置，不生成证书或凭据。
5. 真实测试：Security按固定cdhash接受编译的Swift客户端（该PID未登记），同UIDPython进程自报tisra被拒绝；另有受控native/Friday进程登记测试。没有把这说成真实产品已签名部署或TCC已接通。

### 最小原repo接线（待协同应用WIP后使用）

- Tisra仅新增上述2文件到Mac target，新增一个default-disabled coordinator实例；Settings显式启用后才被动读取状态；显式actionhandler用稳定review ID提交非敏感工具并独立展示receipt。不得接入text-change/autosave、不得改ResearchService默认路径。当前native模块和编译harness已可复用，不要求先改Package.swift或Ledger schema。
- Friday已有adapter无需新增第二个；保持homeplane.arl入口，将真实supervisor启动清单接到其明确start动作。不要把默认SDK的逻辑同UID服务误称verified生产身份；生产签名/受控host只在批准具体安装清单后配置。
- ARL前台组合用Runtime(identity_verifier=...)；可信host把签名Tisra verifier与受控Friday verifier组合，再设置wake callback只启动已注册固定spec。没有让client claims成为trusted registry。已授权jobs有持久scoped授权；撤销新RPC不等于undo已提交任务。

编译和测试入口仍为 `./script/build_and_run.sh --verify`，不会进入UI目录 `macOS/ARLSettings`。生产安装、自启、Apple权限、模型额度和同一Mio服务发布范围仍按INTEGRATION.md逐项批准，本轮均未操作。
