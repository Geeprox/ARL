# 可复现测试分组

`script/check.py` 明确登记 `tests/**/test_*.py` 的全部模块。它也覆盖旧 `unittest discover -s tests` 未递归发现的 service_deployment、service_portal 和 Moments 子目录。新模块未分类、清单指向已删除模块、分类指向不存在的测试或前提名称，均退出 2；没有“其他测试默认不跑”的通配规则。

默认执行当前平台的自包含组：Python 标准库 portable，以及 macOS 上的 native。每个模块由独立进程运行；只运行该模块自己声明的方法，继承或导入的原测试在原模块运行一次。独立脚本型测试有明确 command 入口，不将零个 unittest 当成测试通过。

```sh
# 默认：portable；macOS 同时执行 native。不会登录账号或调用真实模型。
python3 -B script/check.py --output build/check-self-contained

# 与公开 Linux CI 对应的平台无关范围。
python3 -B script/check.py --profile portable --output build/check-portable

# 只核对完整清单和实际前提，不导入测试或运行业务。
python3 -B script/check.py --all --list --output build/check-plan

# 需要锁定 NAS 依赖时，先复制解释器到全新的独立测试树。
# copytree 拒绝覆盖；不在离线发布 cache 内运行测试或写 bytecode。
python3 -B -c 'import shutil; shutil.copytree("vendor/nas/python", "build/check-nas-python", symlinks=True)'

# 包括依赖、外部消费者与私有历史验收；缺前提如实保留为 blocked。
build/check-nas-python/bin/python3 -B script/check.py --all --output build/check-all
```

已有结果目录不能覆盖；为每次验收选择新目录。plan.json 记录实际选择、未选择、缺少的前提和测试源码摘要；每个模块有独立日志/结果，result.json 汇总通过、失败和阻断。运行期间测试源码改变或清单出现新模块，不会生成全绿结论。

runner 为每个 Python worker 和 command 显式传 `-B`，测试内另起的 Python 夹具也显式传 `-B`。仅设置环境变量不足以约束 `-I` 子进程；隔离模式会忽略 `PYTHONDONTWRITEBYTECODE`。实际执行测试时，runner 拒绝把 `vendor/` 发布输入直接用作解释器；`--list` 仍只读检查前提，不启动测试子进程。

| 分组 | 条件与边界 |
|---|---|
| portable | 随源码分发的标准库逻辑、合成 transport 和本地临时文件/socket；没有外部应用或私有签名壳前提 |
| native | 本机 macOS、Swift/Apple frameworks、真实内核身份及公开源码编译；无真实业务增改删。四个旧 core smoke helper 缺失时，先用既有 build-only 入口从源码准备 |
| dependency | 实际 NAS 第三方库等已锁定依赖；通过现有 NAS 依赖锁核对版本，不临时 pip 安装或用协议 double 替换库 |
| external | 实际 Tisra/Friday 源码、隔离应用或 Capture 原生执行文件及其原 pin/review；缺失或已变更不能当作合成成功 |
| private | 冻结验收材料、旧签名包、历史部署源码和维护者资源壳；源码发行明确不携带这些内容 |

混合模块按类或方法细分。例如 Office 标准库提取继续属于 portable，PDFKit/Vision 和系统 textutil 是 native；NAS 诊断中使用实际 SMB 异常与锁定 transport 的检查属于 dependency，其他诊断检查仍为 portable。旧部署模块的缺失不阻止公开 core 包装测试导入；它自己的拒绝验收仍保留在 private。

实际执行的退出码：0 表示所选范围无失败、无阻断；1 表示实际测试失败；2 表示清单/前提阻断或出现意外 skip。原测试若自行 skip，runner 将结果记为 incomplete，不转成通过。`--all` 包含真实外部验收前提，因此即便自包含测试全部通过，只要这些前提仍缺失，整体仍返回 2。`--list` 在清单有效时返回 0，同时明确列出 blocked 数量；这只证明计划已生成，不是测试通过。

公开源码导出保留全部测试模块与同一份分组清单。private/external 组保留其原前提，不因私有资料被明确省略而伪造成功；portable 不导入这些材料。可从主仓生成全新快照后，在导出目录执行相同 CI 入口：

```sh
python3 -B script/export_public_source.py --output build/public-check-source
cd build/public-check-source
python3 -B script/check.py --profile portable --output build/check-portable
```

导出的 `publish_ready=false` 只表示尚未完成独立发布审查；测试导出不推送仓库。本轮 833 项 portable 完整基线为全绿；在真实导出树发现并修复的五个失败涉及被省略的历史提醒材料、深路径 Unix socket 夹具及非 deadline 用例的短等待，修复后对应四模块 30 项在导出树通过。137 对应源码随后以标准库解释器完整执行当前 portable 分组，**849 tests、94 个模块 job，0 failures、0 errors、0 skips、0 blocked**。此收据属于主仓当前分组，不能代替更新后的导出树、native、dependency、external 或 private 验收。

2026-10-30 正常宿主首次完整 discovery 记录为 1,088 tests、3 failures、22 errors、11 skips。新增源码尚未完成配方/清单更新时触发的拒绝、外部 Capture/Friday 前提、一次 Vision 超时与加权公平性夹具分别记录，不能混为产品回归。加权公平性按实际耗时计费；在并行高负载下，原用例的 5 ms 固定耗时假设不成立。其次数比例检查现只固定 claim/finish 业务时钟，保留 1:3 的精确断言，并独立验证真实 elapsed 超过估算后仍按权重补记服务。生产调度算法保持原样。

## 2026-11-03 源码同步复验

本地主仓 portable/native 自包含全组已完整执行：969 tests，0 failures、0 errors、0 skips、0 blocked。独立公开源码快照的 portable 全组已完整执行：876 tests，0 failures、0 errors、0 skips、0 blocked。两组有重叠，不相加。完整原生源码的五步编译全部通过，未签名、安装或启动应用。实际 SDK 的 NAS/Mio 合成下载链路通过 416 项检查，文件操作、固定验收契约、下载 widget 和 Codex 权限策略检查也已通过；这些结果不能替代真实 SMB 或宿主平台附件验收。

本次补齐三个新 Codex 模块的测试登记，修复服务档位诊断字段破坏严格版本化回执的问题，并修正 Session 帧预算及 NAS staging 模块路径的旧夹具。最终测试命令保持与上文和公开 CI 相同。

`--all --list` 当前记录 211 项前提阻断，涉及外部 Capture/Friday 工程、冻结执行夹具及锁定 NAS 依赖；它是计划检查，不是全量通过。真实 NAS 连接、文档、大文件和写入验收保持独立。普通 NAS 读取可配置共享根目录或任意有效子目录；既有保存范围不由源码同步自动扩展，固定样例创建/清理仍限定其验收目录。
