# PicLight 图标 · 参考图还原 v2

仅供审阅，尚未接入应用。所有新文件均位于本目录；原有 `Resources/AppIcon` 草稿保留。

## 先看效果

- `preview/01-reference-preview.png`：尽量还原参考图的浅色、深色静态效果。
- `preview/02-native-glass-preview.png`：Apple 实际渲染的分层液态玻璃版本。
- `preview/03-native-26-27.png`：同一原生文件在两代渲染器下的对比。
- `preview/04-small-sizes.png`：256、128、64、32、16 像素的实际尺寸检查。

静态还原版保留参考图的大面积柔光和较厚玻璃边缘。原生版把背景、玻璃内层、手套与手电筒、光束分开，系统材质会产生不同效果。因此两套预览分别展示，不能将静态还原图当作系统实时渲染结果。

## 可用文件

| 文件 | 用途 |
| --- | --- |
| `reference/PicLight-light.png`、`PicLight-dark.png` | 1024 × 1024 透明背景的静态图标 |
| `reference/PicLight-reference.icns` | 浅色还原版，10 个 macOS 常规尺寸 |
| `reference/PicLight-reference-dark.icns` | 深色还原版，独立的静态文件 |
| `reference/PicLight-reference.appiconset` | 浅色还原版的资产目录文件 |
| `PicLight.icon` | 原生分层 Icon Composer 文档，支持 Default、Dark、Clear、Tinted 外观 |
| `legacy/PicLight.icns` | 原生版的静态兼容文件，10 个尺寸，16–1024 px |
| `legacy/PicLight.appiconset` | 同一原生版的静态资产目录文件 |
| `verification/compiled/Assets.car` | Apple `actool` 编译产物，供验证和未来接入参考 |

单独的浅色、深色 `.icns` 不会自动随系统切换。系统自适应外观由 `PicLight.icon` 的分层数据提供。

## Apple 方案与兼容性

应用图标采用 **Icon Composer → `.icon` → `actool` → `Assets.car`** 的资源流程，不需要给应用图标编写 `NSGlassEffectView` 界面代码。

按 Apple 文档，Xcode 会从 `.icon` 为旧系统生成静态图标。这里额外提供完整 `.icns` / `.appiconset`，便于独立预览或传统打包。当前项目最低部署版本为 macOS 14，因此兼容目标为 macOS 14、15；这些系统显示静态图标。

原生文档包含新版折射和高光位置设置，使用 **Xcode / Icon Composer 27** 编辑与编译。Apple 明确说明，在 27 之前的系统中，折射设置没有可见效果，高光位置退化为开启状态。**新版本编辑工具要求不等于应用运行时最低版本要求。**

注意：添加 `.icon` 后，Xcode 通常优先使用它，并为旧系统自动生成相近的静态版本；不能假定同名 `.appiconset` 会覆盖这些回退图标。如果最终选择“新系统原生玻璃、旧系统参考图还原版”，还需在正式接入时验证打包优先级。此次没有实施这一步。

来源（2026-09-27 核对）：

- [Apple · Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [Apple · Icon Composer](https://developer.apple.com/icon-composer/)
- [Apple · App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)

## 验证范围

在本机 macOS 27、Xcode 27.0（27A266a）上：

- `ictool` 分别使用 `--design-generation 26`、`27` 渲染六种外观。
- `actool --minimum-deployment-target 14.0` 编译分层文档；编译日志保存于 `verification/compiled/actool.log`。
- `assetutil` 检查产物中含 Aqua、DarkAqua、Tintable 的 icon stack 与静态多尺寸数据。
- 三份独立 `.icns` 均通过 `iconutil` 解包并检查 10 个文件及像素尺寸。
- 对比生成前保存的摘要，确认原有图标与构建文件没有被此任务修改。

这是渲染、资源编译和文件验证。尚未在 macOS 14、15、26 的独立实机或虚拟机上安装应用验收，也未做 App Store 上传验证。Icon Composer GUI 首次启动的许可协议未代用户确认；文档验证通过命令行工具完成。

## 重新导出

```sh
python3 design/AppIcon-reference-v2/build-icons.py
```

仅重新导出本目录，不会替换应用图标或修改应用构建配置。需要本机 Xcode 27 自带的 Icon Composer、`swiftc`、`actool`、`iconutil`，以及 Python 3 标准库。

绘画素材使用内置图像生成工具完成，提示词保存在 `source/PROMPTS.md`。参考版原始输出保存在 `source/ReferenceExport.icon/Assets`；导出时通过 Apple 的系统图标遮罩裁切外缘，保持平滑边界。源图未被覆盖。原生玻璃内层和光束是可编辑 SVG，主体为透明 PNG。
