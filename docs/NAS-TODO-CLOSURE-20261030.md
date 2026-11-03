# NAS 收尾与验收入口 · 2026-10-30

当前正式安装和实机结果见 [TODO 收尾状态](TODO-CLOSURE-20261030.md)。主仓的 `NASCapability` 已包含 `NASDocumentContract`，Mio 的目录与 dispatch 共用这份注册；当前会话未看到 `mio_nas_read_document` 不能直接解释为主仓缺实现。应先核正式运行代次的真实 `tools/list`，再刷新原连接器的工具目录。不要新建隧道或绕过原 owner。

本轮各候选的显式只读 `mio_nas_list` 返回 `nas_transport_failed`，文件通道诊断定位到 TCP `EHOSTUNREACH`；同包原生 TCP 探测可连接。137 已记录实际授权回调的有限耗时，不能把这个差异直接归因密码、本地网络权限或地址族。固定创建尝试在首个持久 claim 前停止，claim 和样例写入均为零；未用写入作为性能测试，也未更改保存的 endpoint 或凭据。

138 的实机失败记录已确认**最后失败的 socket 属于 IPv4**，同期同包原生 TCP 探测仍可连接。这不证明之前每个地址的结果，也不证明特定系统策略允许或拒绝；不会据此改地址族、DNS、路由、权限或自动重连。

大文件写入还存在明确的性能未完成项。实际只读回调包含重复完整验签，按协商大小增大数据包的原型和单回调内去重分析尚未证明可满足现有 30 秒 Medium 预算；这些性能原型均未应用到生产。应用可由同 UID 修改，不能把签名或只读 mode 当作跨回调不可变证明来跳过验证，也不会简单延长业务期限。连接恢复后仍需经过真实传输和精确清理验收，不能由解析测试、包大小模型或回调计时替代。

## 无网络诊断

```sh
python3 -B -m integrations.nas.diagnostics
```

只读固定 `login-diagnostic.json` / `file-diagnostic.json` / `network-diagnostic.json` / `authorization-timings.json`，核对文件类型、权限、uid、硬链接及有限 schema；显示时间与是否在五分钟内，明确不探测当前服务器、不读凭据。过期记录不能当作当前故障证据。新 worker 对 connect / health / list / stat / read 的异常留下类型、errno、NTSTATUS、代码位置；不保留异常文本、服务器、账户、路径、请求或密钥。诊断写入私有临时文件后原子替换，失败不改变业务结果。

运行中 GUI 的既有 `home/ARL-Test` 连接遇到 `nas_transport_failed` 后，仅对原保存 endpoint 做一次 2.8 秒预算的 `NWConnection` TCP 诊断，不登录或发送 SMB 载荷。固定 `network-diagnostic.json` 为 0600，只包含有限状态、`currentPath.unsatisfiedReason`、错误域/数值和时间；不保存 endpoint、用户名或正文。只有明确的 `local_network_denied` 路径原因能作为该次拒绝证据；TCP ready 也不代表 SMB 登录或文档读取通过。命令行与 GUI 在 macOS 本地网络权限上的行为可能不同，依据 [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。

`authorization-timings.json` 为固定 0600 记录，只在真实只读 `kind=connect`、旧 `kind=list`，以及 SDK `fileOperation` 实际使用的 `kind=files` / `request.operation=list` 窗口采样。原请求校验仍完整执行；分类函数只读取选择字段，不构成准入。read/read_text/read_document/search/download、upload 与 acceptance 均不采样。每个回调只在内存累计，在最终业务结果发送前原子落盘，避免 owner 收到失败后立即停止 worker 丢失记录；落盘耗时不计入回调样本，诊断失败不改变业务结果或重试授权。

耗时定义为 `authorize_entry_to_validated_reply`，包括 Python 入口、组帧、管道、原生验证和回包校验，不是原生 CPU 单独耗时，也不是外部包验签基线。记录只含固定 stage、次数、整数微秒及有限结果分类，最多 4096 次、每 stage 最近 16 个样本，截断会显式标记；不保存 frame、scope、nonce、endpoint 或凭据。用既有只读 connect/list 后运行上述 CLI 读取，不调用 create/consume/cleanup 做 benchmark。纯聚合/reader 测试列入 portable；实际 PrivateWire/真实 files-list dispatcher 测试列入 dependency，并要求锁定的 nas_dependencies。

## 固定验收包

```sh
python3 -B -m integrations.nas.acceptance --prepare build/todo-closure-20261030/nas/fixtures
```

输出必须是新目录；目录 0700、文件 0600，既有同名本地文件不覆盖。输出六个固定文件与 `MANIFEST.json`：

| 文件 | 用途 |
|---|---|
| `ARL-Test-20261030-document.pdf` | 内嵌文本 PDF |
| `ARL-Test-20261030-document.docx` | 中文正文、换行和表格 |
| `ARL-Test-20261030-document.xlsx` | 工作表顺序、中文、原值及缓存公式 |
| `ARL-Test-20261030-document.pptx` | 幻灯片顺序及中文 |
| `ARL-Test-20261030-large.bin` | 3,145,745 字节的确定性大文件 |
| `ARL-Test-20261030-write.txt` | 64 字节的新建与精确清理样例 |

ASCII 前缀显式对应用户要求的 `ARL-验收-20261030`。所有内容均为合成数据，大小与 SHA 由确定性生成器产生。NAS 目标仅既有 `home/ARL-Test`；准备本地包不授予写入权限，也不改持久只读 scope。

协调者必须先确认六个精确名称都不存在。任一已存在则停止该文件，不覆盖，即便它的内容恰好和样例相同。实际创建成功及原字节回读后，保留原操作 ID、路径、对象引用、修订、大小及 SHA；未知写入结果保留核对，不换 ID 绕过。

`read_acceptance(call=..., listing=..., verify=...)` 接受协调者的既有受信工具调用和当前目录回执，核对精确样例、同一 source / generation / epoch，逐一执行四格式解析和六文件整文件下载 SHA；下载复用私有磁盘暂存，不把大文件累积在内存。首次失败停止，无自动重连或重试。返回值只陈述 owner 提供的 transport，通过合成调用并不构成 NAS 实测。

`CleanupRun` 只登记明确新建、原来不存在、完整内容已核验的样例。清理前再次核对路径、对象引用、修订、大小和 SHA；在任何删除前持久标记 `delete_attempted`。条件删除后端必须将对象与修订绑定到实际删除，单纯按路径删除不能实现此接口。删除后再核对原目标消失；超时、撤销或效果不明保存 `unknown`，重开后拒绝自动再删或更换 ID。不会清理预先存在的同名文件，不会删除目录或其他记录。

## 同包原生 create / cleanup 接缝

固定 manifest SHA-256：`f49588e49abac09328eb2a5a3ec6026548ebc610d28ac9b7f24f3822556a39d1`。

`NASAcceptanceExecutor` 在正式应用的管理分支中加载原 deployment / Keychain owner 和已经保存的 NAS 设置，硬性要求 `share=home`、`root=ARL-Test`，并再次绑定原凭据代次。不保存新范围、不新挂载、不让密码返回管理命令。SDK 的 `runFixedAcceptance` 只有 `create` / `cleanup` 两个枚举和固定清单摘要，底层仍用原继承匿名私有 pipe、原 `SMBReader`、原 source / generation / credential 复核及120秒管道期限；没有新增 Mio 写入工具。

管理入口由协调者接到以下固定参数形态，不能增加任意 JSON、文件路径或内容参数：

```sh
ARL --internal-nas-acceptance create f49588e49abac09328eb2a5a3ec6026548ebc610d28ac9b7f24f3822556a39d1
# 同一原有Mio范围内完成文档/下载检查后：
ARL --internal-nas-acceptance cleanup f49588e49abac09328eb2a5a3ec6026548ebc610d28ac9b7f24f3822556a39d1
```

创建阶段先检查六个名字都不存在，才逐项以 SMB `FILE_CREATE` 创建，write-through、flush、完整回读 SHA 后保存对象身份、原对象引用、修订和大小。四份文档还会经过实际包内解析器。固定样例字节包含在签名 runtime 中，不从命令参数导入。重复 create 不覆盖或重建。已知字节成功但解析失败时仍保留可安全清理的创建回执。

清理阶段读取同一私有持久回执，并在原 SMB3 加密会话内持有无写/删除共享的祖先句柄。目标以 `DELETE+READ` 打开，保持目标句柄到整文件 SHA、稳定对象身份和修订全部匹配；先持久记录 deleting，再通过该确切句柄的 `FileDispositionInformation` 设置删除并关闭，最后核对原名字消失。已经删除的记录不会再删；若原名字后来被新文件复用，只报 target_changed。已存在的同名、内容变化、身份变化、未知创建和未知删除一律不当作可删除测试文件。

固定命令不代表已实际调用；正式构建、签名、执行和精确清理收据由协调者统一记录。`NASAcceptanceContractTests.swift`、`test_nas_acceptance_host.py` 分别验证实际 SDK 合同与真实 SMB 删除报文/持久引擎。SDK全源在正常编译环境typecheck通过；默认沙箱阻止SwiftUI编译插件的错误单独保留。

固定验收的每个原生授权 checkpoint 最多等待 30 秒，且与管道原截止时间、本阶段原 90 秒预算及当前 Medium 的剩余期限共同取较早者；原生回报的剩余时间只能缩短该截止时间。所有 Medium 检查都会在验证前后复核关闭状态与截止时间。保留全部原生校验，不重新授权或重试；准备授权超时/撤销时尚未创建 journal 或 NAS 文件，效果未知时仍保留未知状态并禁止重放。

延长原生授权的单次等待不证明大文件能在原业务预算内完成。3 MiB+17 字节样例有 97 块，write/read 路径至少产生 970 次检查；30 秒 Medium 预算对应每次平均不足约 31 毫秒，且尚未计 SMB 往返。真实验收前，应先在同一正式进程中对既有严格签名检查做少量只读计时（冷、热分别记录），再以只读连接/目录元数据调用观测授权回调延迟；不调用 create、consume 或 cleanup 来做性能探测。签名检查基线不能冒充完整原生回调的性能结论。若仍不能证明预算可行，应继续标为未验，保持原预算和未知效果规则。

## 平台文件组件

官方 [文件接口](https://developers.openai.com/plugins/reference#file-apis) 提供组件侧 `uploadFile` 与 `getFileDownloadUrl`。当前无组件服务不能将 NAS transfer_ref 或本地路径直接当作平台文件 ID。本轮新增的 vanilla widget 走这条实际支持路径：

1. MCP Apps `ui/initialize` / `ui/notifications/initialized`，接收原下载 manifest。
2. 用户点击“准备下载”，通过原 `mio_nas_transfer_read` 取块；核原 scope、序号、块 SHA、EOF 及整文件 SHA。
3. 仅在宿主确实提供文件 API 时，调用 `uploadFile(File, {library:false})`，再以实际返回的 fileId 获取下载 URL，不请求额外保存到文件库。官方参数类型为 `{library?: boolean}`，其中 `true` 才请求额外保存文件库；该选项不构成宿主上传副本的保留期或删除承诺。组件不构造 URL，不访问账号 cookie，不开下载服务器。
4. 上传结果未知时保存未知状态，不自动上传第二次。已取得 fileId 而 URL 查询失败时只重新查询 URL，不重新上传。重载恢复同一操作状态。

组件以 MCP Apps 标准 bridge 为主，ChatGPT 文件 API 是可选扩展；没有对应宿主能力时明确不可用，客户端编排的已验证下载路径仍保留。32 MiB 是这个浏览器组件的内存预算，不改变原磁盘下载接口。上传成功不声称平台下载后字节已重新核验；真实验收还须下载并比较 SHA。

组件从 `integrations/nas/download_widget.js` / `.html` 生成静态 `native/NASDownloadWidget.swift`。用以下命令防止生成副本漂移：

```sh
python3 -B integrations/nas/build_download_widget.py --check
node tests/NASDownloadWidgetTests.cjs
node tests/NASDownloadWidgetAppTests.cjs
```

共享接线已由协调者合入主仓：Mio 原生编译清单加入该 Swift 源；initialize 声明 resources；resources/list 返回唯一固定 listing；resources/read 只允许固定 URI；download descriptor 绑定 `_meta.ui.resourceUri`，transfer_read 声明 UI 可见。任何调用仍经过原 owner 与范围校验。`tests/MioNASWidgetTests.swift` 使用真实 adapter 检查固定资源、目录元数据、未知 URI / 路径 / approval 字段拒绝及元数据调用不进入 owner；最终组合编译与执行由协调者统一完成。

本页不把组件源、模拟宿主测试或本地解析成功称为正式平台附件交付，也不把本地固定文件包称为 NAS 创建/删除完成。

本轮较广回归为116项，默认沙箱的4个错误来自重复发现的两项真实 Vision OCR 用例。相同两项随后在正常本机执行环境精准复验通过，未改 OCR、未转 skip；错误和复验日志分别保留。新增诊断、样例/清理和资源一致性，以及组件字节/握手/恢复检查分别通过，计数有不同入口，不汇总为单一全量通过数。
