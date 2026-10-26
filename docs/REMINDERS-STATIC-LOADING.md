# 提醒事项静态加载修复

当前已装 ARL47 的旧提醒事项 helper 使用本地签名、hardened runtime 和两份独立自签 dylib。之前实际 `--permissions-status` 在 dyld 阶段因 Team IDs 拒载，尚未进入权限检查。此修复保留原 helper 身份、DR、策略和系统权限归属，把 Core/EventKit 静态链接进同一执行文件；不增加 helper，也不启用 disable-library-validation。

正常 `script/build_release.py` 路径新增三个串行 swiftc：Core、EventKit、helper。它从固定 vendor shell 的已封存 Info 复制全部策略和用途字段，只增加 `ARLRemindersLinkage=static`，不读取真实权限、提醒事项数据或凭据。构建后拒绝非系统/Swift runtime 动态依赖；替换仅发生在新的 build/ 候选包，旧副本保留用于审计，vendor cache 原字节不改。原本地证书签 helper、严格核原 DR 后，再按原正式 ARL 身份签外层包。未签构建不会发布 authority 候选。

Control 仅在严格验签后读取布局声明：缺失声明仍要求旧五文件闭包，精确 static 要求 Info/执行文件/CodeResources 三文件闭包；未知字符串或错误类型拒绝。文件哈希、策略 pin、对等身份、启用状态和操作记录门全部保留。

本轮源码和纯 Python 定向检查不代表新的 native 或安装完成。下一轮需新鲜编译槽：三个 helper 编译、当前 Control 链接、布局原生夹具；签名后检查实际动态依赖/原 DR/权限只读状态。仅更新安装公开 control/closure 的新执行文件与签后闭包 pins，保留 activation、source 选择和所有 journal，旧 policy 不得自动刷新成新授权。真实 UI 连接及既有来源升级复核仍需单独验收，不把历史 authorized_full 当本轮证明。

主应用直接承接 Apple 业务仍是后续架构方向。此项解决现有加载故障，不把旧 helper 的 TCC 权限称为主 ARL 已获权限。
