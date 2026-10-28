# NAS 文档文本提取组件

2026-10-24，主仓源码与本地合成格式回归通过。正式 ARL 仍为133；本组件已接入134候选但尚未正式发布为 Mio 新工具，没有进行 NAS 文档类型实测。

## 支持范围

| 格式 | 提取内容 | 明确边界 |
|---|---|---|
| PDF | PDFKit 读取内嵌文字；图片型页面使用本地 Vision OCR，按页返回 | 扫描件 OCR 可能识别不准，空白页无文字时返回 no_extractable_text；加密 PDF 返回 encrypted_pdf，不接受密码 |
| DOCX | 正文、表格、文本框的段落文字、制表符与换行 | 不读取页眉、页脚、脚注、批注或图片文字；按文档 XML 结构提取，不承诺版面还原 |
| XLSX | 工作簿顺序、工作表名/隐藏状态、单元格引用、共享/内联字符串、原始标量、公式及已有缓存值 | 不执行公式或外部连接；不推算未缓存值，不恢复日期/数字样式，不读取图表或图片 |
| PPTX | presentation 关系定义的幻灯片顺序及页内文字 | 不提取演讲备注、图片或独立图表/SmartArt 部件 |

DOC/XLS/PPT、宏文档等其他扩展名返回 unsupported_document_format。加密 ZIP 返回 encrypted_office_package；OLE/复合容器（可能是加密 OOXML 或旧格式）返回 encrypted_or_compound_office_unsupported，不推断密码错误。加密 Office 的覆盖证据包括真实密码 ZIP 拒绝，以及合成复合容器头识别；没有把复合头样例称为真实加密 Office 文件验收。

## 下载桥接

源码入口为 integrations/nas/document_text.py：

- extract_document 接受现有 attachment_bridge.VerifiedFile，先验证原始字节、大小和 SHA，再提取文字。
- extract_download 复用原 collect_download：核对原请求、来源/配置/epoch、完整分块、EOF 与 SHA；随后才调用解析器。
- 原 host 的 verify 回调在解析前后继续生效；解析中撤销则不交付结果。没有重试、重新连接、范围重绑、NAS 写入或发布行为。
- PDF worker 路径由受信 host 在组合时传入，不能来自文档、Mio 参数、文件名或 URL。worker 仅从 stdin 接收原始 PDF、向 stdout 返回 JSON。134候选已将它纳入原应用闭包与既有验证链；当前未新增或更换身份 pin。
- 不需要第三方 Python 包。Office 使用标准库 zipfile/ElementTree；PDF 使用系统 PDFKit。134候选已扩展原 owner、Mio 目录与recipe；正式运行进程未变。

内存便利下载接口保留 1 MiB 界限；大文件使用磁盘暂存下载接口。正式文档读取链路另有 32 MiB 解析输入预算，每个实际读取的 XML 部件最多 8 MiB；每次最多返回 128 个提取单元、64 KiB 文字及192 KiB紧凑UTF-8 JSON。PDF worker 有45秒进程期限，单页渲染最长边为2048像素，约5秒后在页间返回续读位置。它们是当前本地资源预算，不是供应商格式上限。到达文本/单元/JSON预算时 complete=false、truncated=true 并携带 stopped_reasons；覆盖范围始终单独列出。coverage 明示本地 OCR 及其可能误差；无内嵌文字不能作为文档无内容的证据。

## 验证与交接

执行：

    /opt/homebrew/bin/python3 -B -m unittest tests.test_nas_document_text tests.test_model_transport_boundary -v

26项通过：23项文档/桥接测试，3项模型传输边界测试。实际编译并执行 PDFKit worker，覆盖文字页、图像型扫描件、空白、真正密码加密PDF、非法PDF及129页预算；Office样例是自生成OOXML包，另有系统 textutil 独立生成DOCX的原文回归。桥接测试使用受控MCP收据，覆盖真实解析链及撤销后结果丢弃，不称为NAS实测。

证据目录：build/audit/nas-document-text-20261024.noindex/

- REGRESSION.json / release-source-regression.log：准确命令、退出码、源码哈希。
- fixtures/：四份无私人内容的PDF/DOCX/XLSX/PPTX，均不足3KiB。
- FIXTURE-MANIFEST.json / CASE-RESULTS.json：每份大小、SHA及真实解析结果。
- native/NASPDFTextExtractor、NATIVE-BUILD.json：仅本地审阅用构建，未安装或部署。
- FROZEN.json：本轮源码/测试/说明冻结清单。

后续 NAS 真机验证只使用既有 home/ARL-Test 只读绑定。需用户将上述合成文件放入该目录后再读取；本轮没有往NAS添加任何文件，也未将scope扩大为写。

## Mio 内建附件发布的实际缺口

现有 Mio runtime 只有工具分派与受限字节传输，未注册 ChatGPT UI 文件桥接，也没有可调用的、已授权的平台持久文件发布接口。NAS transfer_ref、base64 或本地路径均不是平台文件ID；不能把它们拼成可点击附件或标记 downloadable_artifact=true。

[官方文件接口](https://developers.openai.com/plugins/reference#file-apis)说明的是组件侧 uploadFile、selectFiles、getFileDownloadUrl 以及工具输入 fileParams。它们不能据此视作当前无组件MCP服务可直接调用的Library创建接口。当前核验未建立这种服务端发布能力；这不是对所有平台接口都不存在的断言。

内建交付仍缺少：经过支持且授权的宿主/组件上传接线，能将已校验字节登记为真实平台文件、返回实际文件ID及可下载引用，并在当前Mio运行链中完成验收。现有入站fileParams只处理接收，不能替代这个出站接口。本轮不创建公网下载服务器、不借用客户端凭据、不伪造URL，也不将其他产品的返回文件字段套入MCP。

已验证路径仍是客户端编排：真实NAS download/transfer → Library create → 官方下载助手 →37字节/SHA复验。回执在 build/audit/apple-nas-133-20261024.noindex/；对应文件 [private Library reference omitted]。该路径无需改变NAS只读scope，可继续使用。

## 134 候选的正式 host 接线（未发布）

2026-10-24：新增兼容接口 mio_nas_read_document，读取指定 object_ref / revision / size / name 的 PDF、DOCX、XLSX、PPTX。mio_nas_read_text 继续严格 UTF-8；原始 download / transfer_read 保留。文档读取不恢复 scope、不重连，不接受 root、主机、凭据、worker 路径或模型执行参数。正式运行版本仍133。

调用链为 MioReadOwnerAdapter → NASFileExecutor / 原 journal → NASFileRequest → 原 NASCredentialService 私有 pipe → nas_file_reader_host → ScopedFileReader.read_complete → 原 manager.file_operation 的 stat/read/stat → 冻结解析器 → SDK/owner/Mio 响应校验。解析前后继续核对原 source / generation / epoch 与授权期限；完整原字节在32 MiB解析预算和原32 KiB分块读取链路下计算SHA，保留原权限与期限。解析失败保留有限原错误码，不自动重试或重连。

候选纳入独立 NASDocumentContract、nas_document_host、标准库解析模块与 NASRuntime/Tools/NASPDFTextExtractor。PDF helper 由构建器在 staging 前编译，并进入原 NAS immutable inventory、来源哈希和正常发布的嵌套签名流程。Office 无新增第三方依赖，PDF 只依赖系统 PDFKit。私有 host 的192KiB默认JSON帧超限时显式标记 owner_frame_budget 并截断提取文本，原下载内容不变。

当前证据位于 build/audit/nas-document-host-134-20261024.noindex/：106项Python回归、81项Swift SDK/owner/Mio断言、包内隔离Python与默认worker的四格式合成实测，以及候选manifest与源码冻结清单。候选134为 build-only：未进行完整应用签名/归档认证、未安装、未启动，不可直接作为正式更新输入。正常发布仍需明确批准，按既有流程完成签名、受管更新及真实Mio验收。

真实NAS文档验证仍未进行。最小数据范围是现有 home/ARL-Test：用户自行放入冻结样例4文件，或另行明确授权仅创建这4个精确名称、精确SHA的新文件且同名不覆盖；ARL的持久scope继续只读。不得用当前候选/本地格式测试宣称真实NAS或客户端验收通过。
