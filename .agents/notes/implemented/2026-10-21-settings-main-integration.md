# Agent Note：设置最终版本与动画、CLT 的完整整合

Status: implemented

## 问题与输入

Homebrew 安装的是 main；之前只移入 CLT 打包和动画优化时，`feat/viewer-ux-redesign` 上的设置、目录和查看器功能没有进入安装包。保留偏好配置文件并不等于保留设置界面及其功能。此次按用户要求恢复“检查项目使用逻辑”对话（`01a1076e-d5bf-73d0-b77e-cec89bb225b6`）的最终实现，包括未提交输入。

输入基线为 main `654dfb2`、功能分支 `49bc39a` 及原工作区的设置/目录源文件、测试与记录。原工作区 89 个修改或未跟踪文件先保存 SHA-256 清单，再在独立工作区整合，没有重置原分支。设置改版见[原决定](2026-10-13-settings-window-redesign.md)，用户文件夹授权见[后续修正](2026-10-13-downloads-folder-selection.md)；原对话的[交接文档](../../../docs/handoffs/2026-10-13-piclight.md)也一并收录，并将本地绝对链接改为可移植的引用。那些记录中的“未提交/未安装”描述保留为当时事实，本次状态以此记录为准。

## 决定与范围

- 整合设置的原生六个顶层页、看图六个分类、窗口尺寸和分类条稳定性、背景、快捷键与授权列表。目录管理、浏览器、查看器状态和菜单等依赖一起进入 main，避免只复制窗口文件而缺少实际行为。
- 9 个最终待提交的设置/目录生产文件与原工作区逐字节一致。保留用户文件夹作为 Downloads 前置授权目标的最后纠正；预检查只判断路径，不提前读取受限目录。
- 保留 main 的有界三槽动画、时间轴、独立封面 APNG 修正、像素转换与预编译资源；保留切图、空列表、关闭窗口的代际检查与停止生产。共享查看器按两边行为整合，不能用一边整文件覆盖后丢掉另一边的保护。
- Formula、CLT 打包脚本、资源检查器及预编译图标/Metal 库继续沿用 main。包仍最低支持 macOS 14；构建 SDK 26+，保留原生新材质所需的链接 SDK 标记。
- 安装仅由 Homebrew 从源码更新，`/Applications/PicLight.app` 指向稳定 opt 路径；不使用用户 Applications 目录，不修改全局 Xcode 选择。
- 没有移入历史图标试验的 `design/` 产物，也不制作测试 App、DMG 或应用副本。恢复依据保存源码、差异和日志，最终仅保留一个有效 Homebrew 安装版本。

实现入口：[设置](../../../PicViewMac/Settings/SettingsView.swift)、[目录授权](../../../PicViewMac/Folder/FolderAccessStore.swift)、[查看器](../../../PicViewMac/Viewer/ViewerViewController.swift)。既有动画预算与边界继续见[动画决定](2026-10-20-bounded-animation-playback.md)。

## 验证与边界

Xcode 的 XCTest 定向执行 123 项，全部通过，0 失败、0 跳过。设置的两个可见窗口用例 `testVisiblePaneSwitchAppliesStableGeometryImmediately` 和 `testMouseAndPagingSwitchNeverMovesTheVisibleWindow` 通过 `--skip` 明确排除，不计入 123 项。未显示窗口的检查涵盖设置布局、持久化、格式关联的注入后端、目录书签/恢复、源身份、动画像素、时间轴与缓冲，以及窗口关闭时拒绝旧动画结果。

实际过滤器：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter 'FolderAuthorizationPreflightTests|SettingsWindowTests|AFeatureSettingsTests|FileAssociationTests|FolderAccessStoreTests|FolderAccessViewerTests|FolderAccessManagerTests|FolderTreeTests|AnimationMainIntegrationTests|AnimationTimelineTests|AnimationFrameBufferTests|AnimatedFormatRegressionTests|AnimationConversionTests|AnimationLifecycleTests|SupportedImageTypesTests|DecodeCoordinatorTests|CacheIdentityTests|SourceFileIdentityTests|MetalFallbackTests.testSwitchFromMetalToSixteenBitHidesTheOldSurface' --skip 'SettingsWindowTests.testVisiblePaneSwitchAppliesStableGeometryImmediately|SettingsWindowTests.testMouseAndPagingSwitchNeverMovesTheVisibleWindow'
```

新增授权回归在将目标临时改回 Downloads 时失败（1 个用例、2 个目标断言失败），恢复用户主目录后通过；没有读取真实 Downloads 或打开授权面板。应用偏好字典在检查前后比较一致。历史真实大图测试改为显式的 `PICLIGHT_ACCEPTANCE_LARGE_IMAGE` 输入，不发布个人样本路径。

CLT Release 可执行文件在禁止读取 Xcode 的沙箱中编译通过：`DEVELOPER_DIR=/Library/Developer/CommandLineTools SDKROOT=<CLT SDK> xcrun swift build -c release --disable-sandbox`，退出 0，构建输出 38.66 秒，整个命令 51.609 秒。未组装应用包。首次检查继承了终端的 Xcode SDKROOT，沙箱拒绝读取后失败；失败日志保留，使用与 Formula 一致的显式 CLT SDK 环境重跑后通过。

没有运行全量 Swift 测试、可见窗口检查、真实文件关联写入或真实权限授权。单元测试与编译不能证明最终界面在屏幕上的显示效果；用户要求不弹窗，因此本轮不新增这一层声明。Homebrew 安装包的签名、资源和无窗口 Metal 检查在更新后单独确认，不把旧包结果当作新包结果。
