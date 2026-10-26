# ARL 图标

用户确认的柔雾橙图形，由既有图像确定性提取，不重新生成或调色。

- `approved-arl-crop.png`：只含 ARL 的原像素裁切；不含双图预览中的其他应用或标签。
- `AppIcon-1024.png`：标准尺寸透明主图，保留浅色圆角底板、A 和内部光影。
- `ARL.icns`：完整 macOS 尺寸资源，供主 App 的 `CFBundleIconFile` 使用。
- `provenance.json`：来源摘要、裁切范围、像素不变核对及产物哈希。

在主仓根目录使用系统 Python 和 macOS 自带图像工具重建：

```sh
/usr/bin/python3 -B script/make_app_icon.py \
  --output build/icon-assets.noindex/rebuild
```

重新写入源资源需显式加 `--publish`。如需从原双图复现首次裁切，使用 `--preview <本地原图>`；脚本核对已确认版本的精确摘要，拒绝其他版本。原双图只保留在本机忽略的审计目录；公开资源不包含其他应用图标。

裁切先沿原桃橙色边线定位圆角外轮廓，内部 RGB 不变、外部 alpha 为零，再等比缩放至标准 macOS 画布。小尺寸由系统重采样；内置元数据中的构建信息已去除，未改图像数据。生成器依赖系统 `sips` 与 `iconutil`，无第三方 Python 包。
