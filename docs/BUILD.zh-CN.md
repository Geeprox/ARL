# 构建 ARL

在 ARL checkout 中使用统一入口：

```sh
./build.sh --check --build-only
./build.sh --build-only
./build.sh
```

默认版本/构建号以 recipe 为准。`--check` 只核前置条件；`--build-only` 编译完整原生输入但不签名；默认完整构建签名、核验并归档，均不安装/启动/上传。显式候选使用 `--build-number`；安装前回读当前版本，拒绝降级。

构建要求 Apple Silicon、macOS 14+、Swift 6 工具链。输入由 `script/release_recipe.json` 显式登记。编译始终单 worker，复用仓内模块缓存。新原生文件必须登记；源目录、hash、资源清单或公开 authority 模板不匹配即停止。不能从历史目录或已安装主程序凑输入。

音乐与 NAS runtime 已随正式包封装，无须用户另跑 npm/pip。维护者离线缓存位于 ignored `vendor/release/` 和 NAS runtime cache；目前尚未公开，因此干净克隆不能完成正式包构建。公开依赖准备与通用签名配置见 [Agent 安装](AGENT-INSTALL.md) 的待完成边界。

当前本机维护者链使用既有正式身份，不自动创建证书、读取密钥正文、改 Keychain 或转 ad-hoc 签名。签名保持 hardened runtime，最终 Security inspector 和严格 codesign 核验。离线签名不含在线时间戳/公证，不能称为公开发行验收。

产物保存在 ignored `build/releases.noindex/`：

- `package/manifest.json`：版本、源输入、签名、完整 bundle 清单与 runtime inventory。
- `artifact.json`：归档与 manifest 哈希。
- `package/ARL.authority.candidate.json`：保留原 scope，只绑定新 executable。
- `native-plan.json`、`logs/`、`result.json`：计划、各阶段回执与结果。失败不会写 PASS artifact。

安装前需独立审查及平台权限流程。核对 candidate 与当前 authority 的原 hash；原 grant 已变化时重审，不临时篡改 scope。升级仍需保留原状态与回退，GUI/真实业务验收分别记录。

候选 App 仅在 `.noindex` 目录暂存，避免 Spotlight/应用搜索产生重复入口。交付物为 ZIP；验收后执行：

```sh
python3 -B script/finalize_build.py --output build/releases.noindex/ARL-版本-构建号 --check
python3 -B script/finalize_build.py --output build/releases.noindex/ARL-版本-构建号
```

该入口先核 manifest、归档 hash 与逐文件内容/模式，再移除同一构建的 App 暂存并注销其精确路径。源码、SDK、日志、ZIP 和已安装 App 保留。失败时保留原产物；不清空全局 LaunchServices。增量基线暂存应在最后一次复用后收尾，保留 ZIP 以便恢复。

正常签名构建默认自动核 ZIP 并移除 App 暂存。实际包验证与增量构建使用同一暂存锁：只在 `.noindex` 内按需展开，成功或失败退出时核归档并收回。`--retain-staging` 仅供定向审查，不能作为日常默认；用完运行收尾入口。未签名的 `--build-only` 保留在 `.noindex` 内，不可作为正式发布物。
