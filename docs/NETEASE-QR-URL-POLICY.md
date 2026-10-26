# 网易云登录二维码地址

官方“获取登录二维码”文档：
https://developer.music.163.com/st/developer/document?docId=2bb12a93e71a4be0842243b930c2f33c

2026-10-09 读取的公开文档定义 `data.qrCodeUrl` 为字符串，说明可能返回短链或长链，示例使用精确域名 `163cn.tv`。接口为 `/openapi/music/basic/user/oauth2/qrcodekey/get/v2`。文档要求展示二维码，由用户扫码登录；该字段不是二维码图片下载地址。

已固定的官方 `@music163/ncm-cli@0.1.7` 将这一字段原样交给二维码生成器，其 `url` 与 `clickableUrl` 也使用同一字符串。ARL 只把内容传给本地 Core Image 二维码生成器，不下载、解析跳转或自动打开短链，不把完整地址写入日志、磁盘或辅助功能文字。

内容规则接受 HTTPS、精确 `163cn.tv`、原有 `music.163.com` 及其子域名，拒绝短链域名的子域名、相似域名、用户信息和非 443 端口。原有长度、字符及帧校验继续生效。Swift 的运行时帧接收与二维码渲染共用 `MusicLoginURL.validated`，避免只修显示端仍被接收端拒绝。

此内容许可不扩大网络许可。桥接网络请求仍只允许 `openncm.music.163.com`，ARL 不访问 `163cn.tv`；也不把图片 CDN 域名当作登录内容许可。

故障调用 `5EE96C92-7FB6-4330-9158-E0E6E6BB0D82` 的已记录原因是 `qr_url_host`，没有记录实际 hostname。因此官方短链兼容缺陷已有确定依据，但原调用是否使用该域名、实际二维码显示和扫码登录仍需安装后分别验证，不能由合成测试推定。
