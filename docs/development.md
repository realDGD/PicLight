# PicLight 开发指南

这是命令与代码位置的主要说明。项目行为约定在[AGENTS.md](../AGENTS.md)，验证选择在[验证指南](testing.md)，历史设计和发布记录按需读取。

## 环境与名称

- 运行平台：macOS 14 或更新版本。
- 主程序构建：Swift 工具链 6.0 或更新版本、macOS 26 或更新版本的 SDK；SDK 可由 Xcode 或对应版本的 Command Line Tools 提供。CLT 27 / Swift 6.4 已完成干净 Release 编译实测，原生新材质 API 仍要求对应 SDK。
- 日常打包使用 CLT 和 Python 3，复用仓库中的 `default.metallib`、`Assets.car` 与现有 `.icns`。仅更新预编译资源时需要已安装的 `metal`、`metallib`、`actool`；脚本不安装工具、不更改全局开发目录。预编译资源的维护方式见[资源说明](../Resources/Precompiled/README.md)。
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
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/build-release.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools bash scripts/make-dmg.sh
bash scripts/verify-release.sh
```

构建脚本默认在进程内选择 CLT，保留显式指定的 `DEVELOPER_DIR`，不改变全局 `xcode-select`。它先检查预编译资源的源文件、目标配置和 SHA-256，再编译 Swift / C、复制资源并进行 ad-hoc 签名。资源失效会在 Swift 编译前停止；组装或签名失败会保留原应用包。`VERSION` 和 `BUILD_NUMBER` 可按交付需要传入；更改版本后，应用包检查的 `EXPECTED_VERSION` 应与它一致。成功构建会替换同名应用包，DMG 脚本也会覆盖同名 DMG，交付时先明确需要保留的版本。

图标、着色器、最低系统版本或资源编译参数变化后，显式更新资源：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/precompile-resources.py update
python3 scripts/precompile-resources.py check
```

`update` 仅重编译失效的资源；全部一致时不调用资源编译器。`--force` 可强制更新两项资源；`--minimum-system-version`（默认 `14.0`）须与打包时的 `MINIMUM_SYSTEM_VERSION` 一致。若 Xcode 位于其他位置，按已安装路径设置进程级 `DEVELOPER_DIR`。资源和 `manifest.json` 应一并保存到版本控制；日常改 Swift / C 无须更新。图标的经典 `.icns` 更新仍见[图标说明](../Resources/AppIcon/README.md)，缓存内容与失败处理见[预编译资源说明](../Resources/Precompiled/README.md)。

Homebrew 从源码安装使用[Formula](../Formula/piclight.rb)，命令见[安装指南](release/unsigned-installation.md)。Formula 在 Homebrew 外层沙箱内设置 `PICLIGHT_SWIFTPM_DISABLE_SANDBOX=1`，仅关闭无法嵌套的 SwiftPM 子沙箱；普通构建默认保留 SwiftPM 沙箱。Formula 不下载发行版 `.app`，也不调用资源更新或申请 Developer ID。

`verify-release.sh` 只检查现有产物，不会重建；默认还会寻找 `dist/` 中已有的 DMG。验证本次产物前核对实际路径和版本。仅检查新 `.app`、暂不涉及旧 DMG 时，为 `DMG` 指定一个不存在的文件路径并记录跳过项。包验证不能替代图像操作和原生窗口检查。

验证优先复用 SwiftPM 输出和 Homebrew 管理的一个安装版本；不把多份 `.app` 副本当作日志备份。需要保留的恢复依据使用源码版本、差异和日志，临时应用包在验证结束后清理。

安装与发布遵循当前任务授权，已明确授权的同一工作不重复确认。相关说明见[独立应用安装文档](release/unsigned-installation.md)。

## 本地输入与历史资料

`bugs/`、`new_feature/` 和构建产物当前属于本地忽略资料。引用这些输入时保留用户给出的原图和说明；需要共享或纳入版本控制时另行明确范围。现有 `docs/specs/`、`docs/superpowers/`、`docs/audit-*.md` 和 `docs/release/` 提供具体主题的历史背景，以当前源码核对其中的状态、名称和数量。
