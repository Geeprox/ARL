# 网易云官方 CLI 适配源切片

`arl/netease_music.py` 使用现有 ARL `Tool` registry，五个能力现已默认登记为 `not_configured` 元数据，未增加默认应用授权。只有受信 host 明确提供 `NcmCliTransport`、设置独立读/写 policy、配置已验证调用方身份后，ARL 才可能执行 CLI。当前 Mio 公开入口没有真实账号 transport，并在 transport 前拒绝所有歌单写入。服务目录、正式 UI 消费与 Mio 打包绑定见 `integrations/mio_music/README.md`。

能力：歌单列表、歌单详情和曲目、建歌单、单首加密 ID 去重追加并回读、歌曲搜索。歌单与歌曲 API ID 必须是 32 位 hex；网页链接只由返回的十进制 `originalId` 生成。每个非播放命令的 `--userInput` 是固定最短音乐意图，不传整段对话。创建或追加使用非幂等 ARL 工具；创建结果不明时直接返回 `outcome_unknown`，追加结果不明只读回一次，绝不自动重写。已有曲目直接返回 `already_present`；曲目总数无法证明完整时拒绝追加。

官方来源：

- https://github.com/NetEase/skills/blob/master/netease-music-cli/SKILL.md ：`ncm-cli commands` 与各子命令 `--help` 是命令契约；公布了 `playlist create --playlistName`、`--userInput`、双 ID 规则。
- https://www.npmjs.com/package/@music163/ncm-cli ：当前 0.1.7，过期 token 自动刷新，`login --check` 可主动续期。

其他歌单子命令名称、参数及 JSON 输出尚未在本机官方 CLI 实测。适配器在每次进程生存期首次调用前要求版本精确为 0.1.7，并核对 `commands` 与每个子命令帮助；输出结构不符即失败。没有官方 CLI、应用 API 配置和登录时，**当前状态为 unavailable**，不得把离线假 CLI 测试当成网易云真实写入。

后续真实启用应由用户完成官方开放平台入驻和申请 App ID / Private Key，然后在其认可的设备上执行 `ncm-cli configure` 与 `ncm-cli login`；详情见 https://developer.music.163.com/st/developer/apply/account?type=INDIVIDUAL 。本源切片不执行登录、不读取或输出凭据，也不安装程序。仅做歌单操作，不需要播放用的 mpv。
