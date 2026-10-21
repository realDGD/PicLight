# PicLight 验证指南

先确定改动可能影响的行为，再选择检查。测试命令成功但选中零项不算覆盖；历史 PASS 不算本次证据。项目约定见[AGENTS.md](../AGENTS.md)，构建与产物位置见[开发指南](development.md)。

## 文档与 AI 规则

```sh
python3 scripts/check-agent-docs.py
```

检查器读取根入口、README、开发/验证指南和活动 `.agents/` Markdown，包含未跟踪的新文件。它检查本地文件链接、技能的单行 `name` / `description`、名称与目录一致性、决策状态与目录一致性，以及末尾换行。它不访问远程链接，不验证锚点、图片显示或文档语义；归档记录不作为当前导航检查对象。

修改检查器时运行其行为测试：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_check_agent_docs.py' -v
```

仅编辑其他 Markdown 时检查实际改动与引用；增加图片要核对每张原图、路径及渲染预览。`git diff --check` 不覆盖未跟踪和被忽略的文件，不可用它声称已验证本地截图文档。纯文档改动无需运行 Swift 全量测试或重新打包应用。

## 打包脚本与预编译资源

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_precompiled_resources.py' -v
python3 scripts/precompile-resources.py check
```

定向检查覆盖缓存失效、损坏、目标变化、更新失败保留原资源、编译前阻止打包、签名失败保留原包、CLT 默认值和 Homebrew 的嵌套沙箱参数。它们不编译 Swift、不调用图标或 Metal 编译器，也不打开窗口。实际 CLT 编译与包内 Metal 加载仍需对当前产物检查。

Homebrew 安装后可运行 `brew test realdgd/piclight/piclight` 检查资源、ad-hoc 签名和无窗口 Metal 探针。临时前缀执行 Formula 的安装及测试方法，只证明配方主体和产物；不能声称已完成远程 tap 下载、正式 Cellar 安装或 GUI 首次启动。安装方法见[安装指南](release/unsigned-installation.md)。

## 按改动选择 Swift 测试

以下是起点，变更整合端或共用状态时扩展相邻测试。类名可能与文件名不同，例如 `DrawerReservationInvarianceTests` 位于 `WindowArchitectureTests.swift`。

| 改动面 | 测试类起点 |
| --- | --- |
| 标题栏显隐、尺寸和侧栏预留 | `TitlebarPresentationRegressionTests`、`TitlebarVisibilityTests`、`ColumnTitlebarCapTests`、`DrawerReservationInvarianceTests` |
| 画布手势、覆盖层与焦点 | `ViewerInputRoutingTests`、`InvisibleOverlayGestureTests`、`GestureRouterTests`、`ViewportStateTests` |
| 空窗口与第一次打开 | `EmptyWindowOpenTests`、`ViewerRootTrackingTests` |
| 图片/网格切换与目录树布局 | `FolderBrowserModeTests`、`FolderBrowserLayoutTests`、`FolderBrowserSidebarLayoutTests` |
| 文件夹访问记录、书签与读取失败恢复 | `FolderAccessStoreTests`、`FolderAccessViewerTests`、`FolderSwitchRaceTests`、`SettingsWindowTests` |
| 扫描、监听、快速切换和同路径替换 | `FolderSwitchRaceTests`、`FolderSessionTests`、`FolderDynamicsTests`、`SamePathReplacementTests` |
| 解码、取消、文件身份和缓存 | `DecodeCoordinatorTests`、`RapidSwitchCancellationTests`、`SourceFileIdentityTests`、`CacheIdentityTests`、`LifecycleEpochTests` |
| 原生细节、瓦片与显示变换 | `NativeDetailPositionTests`、`NativeDetailLifecycleTests`、`NativeInFlightReplacementTests`、`TilePlanAndRedrawTests`、`SourceOrientationTests`、`MetalFallbackTests` |
| 设置与格式关联界面 | `SettingsWindowTests`、`FileAssociationTests`、`ShortcutStoreTests` |

例如标题栏位移修复的起始检查：

```sh
swift test --filter 'TitlebarPresentationRegressionTests|TitlebarVisibilityTests|DrawerReservationInvarianceTests'
```

过滤器选择测试类和测试名，不是文件路径。修改测试前确认它能捕获原来的错误行为，运行时记录实际选中数量、失败、跳过和日志。用稳定条件等待异步结果；资源与窗口结束时清理，设置和全局状态恢复原值。

## 什么时候跑全量

```sh
swift test
```

发布或较大整合前、修改共用窗口/视口/解码生命周期且难以可信地限制影响面时，执行全量回归。修复定向检查暴露的失败后，按实际影响扩展。相同代码和前提下已经通过的检查不为提交动作重复运行。当前仓库没有 `.github` CI 工作流，不能把未跑的检查说成已由 CI 覆盖。

AppKit 测试需要 macOS 和可用的窗口服务。某些真实大图测试依赖本地输入，跳过必须单列；合成的小图、原生事件测试和物理设备交互分别报告，不互相替代。不要在共享工作区同时启动多个 `swift test` / `swift build`。

## 原生使用验证

对用户可见的图像或窗口改动，用当前构建的应用按实际入口检查受影响的操作。

| 场景 | 观察结果 |
| --- | --- |
| 空窗口 → 打开图片 | 第一帧没有空缩略图框或图片专属控件闪现 |
| 标题栏移入/移出，Fit 与手动放大 | 图片位置、缩放和中心保持不变 |
| 打开/关闭缩略图栏，图片 ↔ 网格往返 | 选择、布局和手动视口按当前约定恢复 |
| 工具坞、导航按钮和画布上的滚轮/捏合 | 输入到达正确视图；控件编辑焦点不被抢走 |
| 快速翻页、切换目录和关闭窗口 | 旧扫描或解码不覆盖当前内容；资源按生命周期结束 |
| 设置页与格式关联页 | 固定尺寸内可操作，草稿与系统状态区分；只测布局不点击真实应用 |

按需要检查亮/暗外观、全屏、Retina 与当前设备。工具无法驱动物理触控板或窗口管理工具的真实行为时，明确记录未覆盖，保留自动事件测试的实际结果。

## 应用包与验收运行器

用[开发指南](development.md)中的脚本构建并检查当前 `.app`；如果交付 DMG，再检查该 DMG。旧 `dist/` 产物和安装目录中的旧进程不能代表当前改动。

内置 `PICVIEW_SELFTEST` 会检查特定颜色分布、方向和文件属性；不能随意传入一张 PNG 后把失败解释为打包失败。现有[发布清单](release/v0.1-checklist.md)记录了 fixture 与旧运行器预期不匹配的情况。仅在明确准备了符合断言的输入时运行，结果和包检查分开报告；普通图片是否成功打开用相应 XCTest 或原生使用检查证明。

完成报告写清楚实际改动、运行命令与结果、产物路径和剩余限制。纯文档交付只报告文档与检查器结果，不引用以前的 Swift 测试数量作为新结果。
