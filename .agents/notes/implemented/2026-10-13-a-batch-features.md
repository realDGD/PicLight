# Agent note：A 批功能的实现与维护边界

Status: implemented

记录日期：2026-10-13。交付版本：0.1.0 / Build 3。记录时分支为 `feat/viewer-ux-redesign`，实现尚未提交，工作区还包含此前的修复和 AI 工作流文档改动。

## 问题与范围

用户要求实现参考软件功能清单首表的全部 15 项 A 功能，并明确调整执行顺序为“减少测试，先实现功能，完成后再测试”。本批已实现缓存管理、最后窗口关闭策略、复制路径与 Finder 定位、双击网格、滚轮灵敏度、隐藏鸟瞰图、窗口置顶、随机图片、快捷键批量管理、循环浏览、删除确认、扩展名过滤、三态显隐、其他双击动作和简化文件夹访问入口。

功能入口由 [README](../../../README.md)和本地 `new_feature/功能清单与实现难度.md` 第 1.1 节说明；实施范围见[本批计划](../../../docs/superpowers/plans/2026-10-13-a-batch-features.md)。本记录保留后续修改容易破坏的选择及本次证据，不重复维护完整功能表。

## 已实施决定

### 缓存所有权与清理

[ThumbnailCacheService](../../../PicViewMac/Imaging/ThumbnailCacheService.swift)统一持有磁盘缓存，各查看器保留独立的 [ThumbnailPipeline](../../../PicViewMac/Imaging/ThumbnailPipeline.swift)。设置页使用同一服务统计与清理，不能另建缓存实例；内存读数统计管线缓存，不是进程的全部图像或 GPU 内存。

清理会推进管线与[磁盘缓存](../../../PicViewMac/Imaging/ThumbnailDiskCache.swift)的代际。普通解码、合并请求的等待者、迟到 Quick Look 和 `previewAndRemember` 都须拒绝清理前的结果。磁盘写入在串行队列中校验代际；清空后保留格式版本标记，避免下次启动误删刚生成的缓存。

清理还要重置查看器的抽屉缓存，以及[网格](../../../PicViewMac/Gallery/GalleryGridView.swift)的 `delivered`、`loadingPaths` 和[浏览器](../../../PicViewMac/Gallery/FolderBrowserViewController.swift)的 `pending`。只取消任务会留下无法完成的占位状态。当前可见网格允许重新请求；清理不意味着继续浏览后缓存永远为零。旧任务完成时也不能移除同一路径的新任务记录，查看器使用独立请求 ID 保护此处。

### 显隐策略与窗口内固定

[Chrome 状态模型](../../../PicViewMac/Viewer/ViewerChromeModel.swift)分别处理工具栏、翻页箭头和鸟瞰图；[原生窗口](../../../PicViewMac/Window/ViewerWindow.swift)处理标题栏。保留自动显隐不改变画布、缩放和中心的约定。网格使用自己的顶栏；无图片、沉浸和导航不可用状态仍限制图片专属控件。

自动模式下的工具栏图钉仅影响本窗口，不写入全局显示设置。取消“显示”模式的固定时，设置切回“自动”。`appliedDockDisplayPolicy` 只在策略变化时同步固定状态；每次无关设置通知都重新调用 `setPinned` 会破坏窗口内固定或重启隐藏计时。

### 过滤、导航与明确打开意图

[FolderSession](../../../PicViewMac/Folder/FolderSession.swift)统一提供循环导航及前后可用状态；菜单、工具栏和边缘箭头读取同一结果。随机选择在多张时避开当前索引，空列表和单张保持可用。

[FolderScanner](../../../PicViewMac/Folder/FolderScanner.swift)接收规范化的排除集合。直接打开的文件作为本次目录会话的例外保留，其他匹配文件被过滤。修改过滤条件要重扫并使旧扫描失效，不能仅重新排序旧列表。[ViewerViewController](../../../PicViewMac/Viewer/ViewerViewController.swift)用 `pendingDirectOpenURL` 保留尚未完成的明确打开目标，使其优先于被动重扫的 `.stayInPlace` 索引策略。

### 快捷键与文件操作

[ShortcutStore](../../../PicViewMac/Settings/ShortcutDefinition.swift)保存带版本的完整绑定快照；缺失绑定代表已移除，空快照代表全部清空。不能在读取新快照时先装默认键再覆盖，否则移除的键会在重启后复活。旧字典数据仍兼容，恢复默认是明确操作；Delete 与向前删除键规范化为同一绑定。

普通删除遵循确认设置，Command+Delete 使用独立静默命令。确认同时捕获目标和 `SourceFileIdentity.versionToken`，执行前再次读取文件版本；路径相同不代表确认过的文件仍然存在。取消确认不改变文件与选择。查看器菜单在文本编辑期间禁用图片命令，保留编辑焦点。

[AppDelegate](../../../PicViewMac/App/AppDelegate.swift)在打开文件夹选择面板前捕获发起操作的查看器，避免多窗口下替换最后创建的窗口。目录读取失败与空目录分别处理；网格模式下的错误使用原生 sheet 呈现。选择目录和权限说明不等于授予完全磁盘访问，也没有实现授权列表或跨启动恢复，这些仍属 B 批。

[SettingsView](../../../PicViewMac/Settings/SettingsView.swift)保持固定 560×560，增加第六个“文件与缓存”页。重新显示设置窗口时刷新缓存统计与快捷键标签，不能只依赖页签切换事件。

## 考虑过的替代方案

- **所有窗口共享一条缩略图管线。** 最初计划采用此方式，后来保留按窗口管线与共享磁盘服务，以免一条管线的 `cancelAll` 同时影响其他窗口的请求。
- **图钉直接写入全局工具栏策略。** 实现中尝试过，回归暴露了跨窗口及后续测试的固定状态污染；改为自动模式下的窗口内覆盖，并保留显式显示策略的持久化。
- **每项功能先测再实现。** 用户明确要求先完成功能，再集中测试；因此合并验证，并在修复失败项后只复查受影响部分。这是本次任务的执行选择，不是取消项目验证要求。

## 验证依据与交付

下表记录本次实际执行结果，不代表未来版本的通过状态。本地日志位于 `.superpowers/sdd/2026-10-13-a-batch-features/`，该目录被 Git 排除。

| 检查 | 实际结果与处理 | 日志 |
| --- | --- | --- |
| 一次全量 `swift test` | 950 项，12 个断言失败，涉及 5 个用例：旧页签列表、旧标题栏标签和工具栏固定状态；随后修正并定向复查。没有再次跑全量。 | `full.log` |
| 修正后的定向回归 | 181 项，剩余一个工具栏动画用例因未隔离“自动”策略前置条件而出现 4 个断言失败；其余用例通过。 | `final-focused.log` |
| 最后工具栏复查 | 隔离前置设置后，28 项、零失败。 | `dock-recheck.log` |
| 最终构建 | `BUILD_NUMBER=3 bash scripts/build-release.sh` 退出 0，生成 `dist/PicLight.app`。 | `release-build-final.log` |
| 最终应用包检查 | `DMG=/tmp/piclight-a-batch-no-dmg.dmg bash scripts/verify-release.sh`：27 项通过、零失败；未检查旧 DMG。 | `release-verify-final.log` |

定向回归的实际过滤器：

```sh
swift test --filter 'AFeature|FileAssociationTests|SettingsWindowTests|CanvasContextMenuTests|TitlebarVisibilityTests|ToolDock|GalleryAuditTests|GalleryLoadingStateTests|GalleryThumbnailSharpnessTests|FolderBrowserModeTests|ViewerInputRoutingTests|TitlebarPresentationRegressionTests|FolderSwitchRaceTests'
swift test --filter 'AFeatureBehaviorTests/testPinningAutomaticToolbarDoesNotChangeOtherWindowsOrSettings|ToolDockIdempotentAnimationTests|ToolDockVisibilityTests'
```

本批新增回归集中在 [AFeatureBehaviorTests](../../../PicViewMacTests/AFeatureBehaviorTests.swift)、[AFeatureCacheTests](../../../PicViewMacTests/AFeatureCacheTests.swift)和 [AFeatureSettingsTests](../../../PicViewMacTests/AFeatureSettingsTests.swift)。

原生检查使用这次构建的应用，确认空窗口没有图片专属覆盖控件、设置页可操作、文件夹选择进入三项网格、首尾循环回绕、随机切换其他图片和双击进入网格。最后补入的“设置重开刷新”在重新打包后做了原生检查，没有为该局部改动再跑 XCTest。临时修改的个人应用设置已在退出后恢复，并按字典比较确认一致。

未执行真实照片删除、系统默认应用关联写入、物理触控板测试、完整授权恢复、安装、提交、推送或发布；DMG 未重建。因此不能将本次结论写成“最终全量零失败”或“新包已安装”。

## 后续恢复

恢复时先核对分支和工作区。现有 `git diff` 混合了此前修复与本批实现；本地任务目录中的 `baseline/` 是本批开始前的快照，`previous-PicLight.app` 保留原先的 Build 2。不要把当前全部差异归因于这 15 项功能。

后续需求继续由功能清单与对应计划管理。改变上述行为时，按[验证指南](../../../docs/testing.md)选择检查；引用旧日志只能说明历史结果，不能代替新版本的验证。
