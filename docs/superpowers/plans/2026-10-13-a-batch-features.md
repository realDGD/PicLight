# PicLight A 批功能实现计划

> 使用 piclight-development、piclight-verification 和 executing-plans，在当前工作区逐组实现；保留已有未提交修复。用户已要求实现此批，普通实现选择不另行重复确认。

**Goal:** 实现功能清单首表的全部 15 项 A 功能，设置接到真实行为并可持久化。

**Architecture:** 扩展现有 AppSettings、统一 ViewerCommand、FolderSession、Chrome 状态模型和设置窗口；增加一个共享缩略图缓存服务供查看器和设置页使用。复杂持久化目录授权保持 B 范围，仅实现系统目录选择、读取说明和打开入口。

**Tech Stack:** Swift 6、AppKit、Foundation、XCTest；macOS 14+。

**Spec:** 本地 `new_feature/功能清单与实现难度.md` 第 1 节与第 6 节。

## Global Constraints

- 产品包为 PicLight，SwiftPM 目标为 PicViewMac；保留原生窗口、Metal/Quartz 与现有大图预算。
- 默认保持现有退出、双击、滚轮、首尾停止和自动显隐行为。删除确认默认关闭；普通删除可配置确认，Command+Delete 使用独立静默命令。
- 顶栏、底栏、翻页箭头各自支持显示、隐藏、自动；无图片和沉浸状态仍禁止空覆盖控件。标题栏悬停不能改变图片位置与缩放。
- 单独打开排除扩展名的图片仍允许显示；排除列表仅过滤文件夹浏览。目录选择和说明不会声称授予完全磁盘访问或完成跨重启授权。
- 设置窗口仍固定 560×560；新增内容可通过页签或滚动访问，不裁掉控件。快捷键清空后重启保持清空；系统固定快捷键保留。
- 不提交、推送、改变真实格式关联或自动安装；交付新的 dist/PicLight.app，实际交互验证使用这次构建。

## Review Focus

- 只有一张图或空列表时随机/循环不产生无效索引；循环开启时首尾箭头可用状态一致。
- 旧设置与旧快捷键数据继续可读；清空、单项移除和恢复默认都跨实例一致。
- 清除缓存后，清除前已经开始的解码与迟到 Quick Look 结果不能重新写入旧缓存。
- 显隐设置、侧栏和图片/网格反复切换，保持手动缩放、焦点与无图片第一帧约定。
- 取消删除确认不改文件或选择；普通/静默删除分流；设置窗口所有入口可达。

### Task 1: 设置和快捷键持久化

**Files:** AppSettings.swift、ShortcutDefinition.swift、GestureRouter.swift；新增 AFeatureSettingsTests.swift。

**Interfaces:** ChromeDisplayPolicy（automatic/alwaysVisible/alwaysHidden）；TitlebarBehavior.alwaysHidden；退出、循环、默认置顶、隐藏鸟瞰图、删除确认、滚轮灵敏度与排除扩展名属性。ShortcutStore.clearAll()/restoreDefaults() 保存完整绑定状态并兼容旧数据。

- [ ] 为单项移除重启复现 RED，再实现完整绑定保存、全部清空和恢复默认。
- [ ] 为设置默认、持久化、灵敏度范围与扩展名规范化写回归；滚轮灵敏度默认 0.0015，范围 0.0001…0.02。
- [ ] 扩展双击操作：无操作、关闭、全屏、网格；保留已有实际像素与沉浸操作兼容。
- [ ] Run: `swift test --filter 'AFeatureSettingsTests|ShortcutStoreTests|GestureRouterTests'`。Expected: 非零用例、零失败。

### Task 2: 文件夹导航与文件命令

**Files:** FolderSession.swift、FolderScanner.swift、ViewerCommand.swift、MainMenuBuilder.swift、CanvasContextMenu.swift、ViewerViewController.swift、AppDelegate.swift。

**Interfaces:** FolderSession 循环导航、随机选择与统一前后可用状态；扫描接受排除集合，明确直接打开文件的保留路径。统一命令增加复制路径、Finder 定位、随机、置顶、目录选择与静默删除。

- [ ] 先覆盖空/单张/首尾循环及排除扩展名的扫描行为，再实现并接到所有扫描和导航入口。
- [ ] 增加普通删除确认与独立静默命令；确认期间捕获目标身份，取消不修改选择或文件。
- [ ] 增加关闭最后窗口是否退出、当前置顶、目录选择与双击窗口操作。
- [ ] Run: `swift test --filter 'AFeatureNavigationTests|FolderSessionTests|FolderScannerTests|CanvasContextMenuTests'`。Expected: 非零用例、零失败。

### Task 3: 覆盖控件显示策略与手势

**Files:** ViewerChromeModel.swift、TitlebarVisibilityModel.swift、ViewerWindow.swift、ImageCanvasView.swift、ViewerViewController.swift。

**Interfaces:** 三种显示策略在原有状态机内计算；隐藏鸟瞰图独立开关。滚轮灵敏度传到 GestureRouter。固定工具坞按钮与显示策略保持一致。

- [ ] 覆盖显示/隐藏/自动、无图片、沉浸、首尾不可用以及反复显隐视口不变。
- [ ] 将新设置接到状态机、真实画布和窗口；双击依所选行为路由。
- [ ] Run: `swift test --filter 'AFeatureChromeTests|TitlebarPresentationRegressionTests|TitlebarVisibilityTests|ToolDockVisibilityTests|FloatingNavigation'`。Expected: 非零用例、零失败。

### Task 4: 共享缓存管理

**Files:** ThumbnailPipeline.swift、ThumbnailDiskCache.swift；新增 ThumbnailCacheService.swift 和 AFeatureCacheTests.swift。

**Interfaces:** 共享磁盘缓存、按窗口隔离 pipeline，统计占用/数量和缓存目录；清理使旧任务的缓存写入失效，内存与磁盘一起清除。

- [ ] 覆盖清除后的统计、再次请求和清除前的迟到写入，再增加缓存代际和管理入口。
- [ ] Run: `swift test --filter 'AFeatureCacheTests|ThumbnailDiskCacheTests|ThumbnailPipelineTests'`。Expected: 非零用例、零失败。

### Task 5: 设置与入口整合

**Files:** SettingsView.swift、ViewerWindowController.swift、AppEnvironment.swift；新增 AFeatureInterfaceTests.swift。

- [ ] 提供缓存统计/清除/Finder、退出、循环、默认置顶、删除确认、排除扩展名、三态显示、鸟瞰图、灵敏度和恢复默认、快捷键批量操作、目录选择与说明入口。
- [ ] 所有页签在 560×560 可操作；布局测试检查实际控件边界或可滚动区域。
- [ ] Run: `swift test --filter 'AFeatureInterfaceTests|SettingsWindowTests|FileAssociationTests|ViewerInputRoutingTests|FolderBrowserModeTests'`。Expected: 非零用例、零失败。

### Task 6: 完整验证与交付

- [ ] 执行一次最终 `swift test`，记录实际数量、失败与跳过；构建/测试串行。
- [ ] 独立评审本次差异，优先检查上面的五个风险；必要修复有对应回归。
- [ ] 构建新 PicLight.app 并检查包；原生检查新增设置、菜单、循环、双击及标题栏显隐。真实删除与默认应用关联不作为 GUI 测试动作。
- [ ] 更新需求清单的已实现状态和 README，交付可运行包与具体剩余限制。

## 执行记录

实际进度与验证日志保存在本计划独立的本地工作目录，恢复时先读取它；不把历史测试结果作为本次验证。

用户执行顺序调整（2026-10-13）：先完成全部功能，再统一测试；上面逐任务测试步骤合并至任务 6，不逐项先跑测试。

### 本次完成记录

维护选择与交接注意事项见 [A 批 Agent note](../../../.agents/notes/implemented/2026-10-13-a-batch-features.md)。

全部 15 项已实现。命令入口、默认值和 A/B 边界已写入本地功能清单第 1.1 节；README 已更新。Build 3 已构建，应用包检查 27 项通过；原生界面检查已完成相关入口和使用流程。一次全量 950 项暴露的问题已修正并做定向复查（181 项覆盖后，28 项最终工具栏复查通过），按用户要求不再重复全量。设置窗口的重新打开刷新使用最终应用确认。交付应用包；未提交、推送、安装或发布，未重建 DMG。个人应用设置已恢复，旧包及本次验证日志保留在本地任务工作目录。
