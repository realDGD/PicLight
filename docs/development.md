# PicLight 开发指南

这是命令与代码位置的主要说明。项目行为约定在[AGENTS.md](../AGENTS.md)，验证选择在[验证指南](testing.md)，历史设计和发布记录按需读取。

## 环境与名称

- 运行平台：macOS 14 或更新版本。
- 构建：Swift 工具链 6.0 或更新版本、Xcode 26 或更新版本的 macOS SDK；原生新材质使用的 API 需要对应 SDK。发布时需要可用的 Metal 编译工具链。
- 开发检查器：Python 3.9 或更新版本，仅使用标准库。
- SwiftPM 包与可执行目标：`PicViewMac`；C 目标：`PicPNGStream`；测试目标：`PicViewMacTests`。
- 交付包：`dist/PicLight.app`；包内可执行文件：`Contents/MacOS/PicLight`；默认 DMG：`dist/PicLight-0.1.0.dmg`。

## 开始与恢复任务

```sh
git status --short --branch
git diff --stat
```

未跟踪文件单独检查；`git diff` 不能显示它们的正文。用户点名的本地资料也可能被忽略规则排除，按实际文件读取，不从 Git 输出推断它们不存在。

先找到承担使用行为的代码，再查相关测试和已有计划。已有未提交修复参与当前功能时，空的新 worktree 不能代替当前状态；需要隔离再记录并复制必需的修改与未跟踪文件。

## 代码地图

| 行为 | 主要位置 |
| --- | --- |
| 启动、Finder 打开与窗口选择 | [App](../PicViewMac/App/) |
| 原生窗口、标题栏、放置和尺寸 | [Window](../PicViewMac/Window/) |
| 画布、缩放、平移、覆盖控件和输入路由 | [Viewer](../PicViewMac/Viewer/) |
| 文件夹网格与目录树 | [Gallery](../PicViewMac/Gallery/) |
| 缩略图栏及单元格 | [Sidebar](../PicViewMac/Sidebar/) |
| 扫描、排序、当前选择和目录监听 | [Folder](../PicViewMac/Folder/) |
| 解码、缓存、缩略图、原生细节与动画 | [Imaging](../PicViewMac/Imaging/) |
| Metal 绘制与 PNG 逐行读取 | [ImageShaders.metal](../PicViewMac/Shaders/ImageShaders.metal)、[PicPNGStream](../PicPNGStream/) |
| 设置、快捷键、默认应用关联 | [Settings](../PicViewMac/Settings/) |
| 菜单、命令、右键与复制 | [Commands](../PicViewMac/Commands/) |
| 元数据与外观 | [Metadata](../PicViewMac/Metadata/)、[Appearance](../PicViewMac/Appearance/) |

模块间的状态整合目前集中在 `ViewerViewController`。改标题栏、网格或解码时，还需检查整合端，不只查看被改的独立视图。

## 构建与运行

```sh
swift build
swift run
```

运行开发目标不等于运行打包应用，资源和默认应用关联的可用性不同。测试与构建共享 SwiftPM 输出，在同一工作区串行执行。

## 应用包与 DMG

```sh
bash scripts/build-release.sh
bash scripts/verify-release.sh
bash scripts/make-dmg.sh
```

构建脚本组装 `PicLight.app`、编译 Metal 与图标资源并进行 ad-hoc 签名。`VERSION` 和 `BUILD_NUMBER` 可按交付需要传入；更改版本后，应用包检查的 `EXPECTED_VERSION` 应与它一致。脚本会覆盖同名生成物，交付时先明确需要保留的版本。

`verify-release.sh` 只检查现有产物，不会重建；默认还会寻找 `dist/` 中已有的 DMG。验证本次产物前核对实际路径和版本。仅检查新 `.app`、暂不涉及旧 DMG 时，为 `DMG` 指定一个不存在的文件路径并记录跳过项。包验证不能替代图像操作和原生窗口检查。

安装与发布遵循当前任务授权，已明确授权的同一工作不重复确认。相关说明见[独立应用安装文档](release/unsigned-installation.md)。

## 本地输入与历史资料

`bugs/`、`new_feature/` 和构建产物当前属于本地忽略资料。引用这些输入时保留用户给出的原图和说明；需要共享或纳入版本控制时另行明确范围。现有 `docs/specs/`、`docs/superpowers/`、`docs/audit-*.md` 和 `docs/release/` 提供具体主题的历史背景，以当前源码核对其中的状态、名称和数量。
