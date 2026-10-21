# 浏览与图像状态修复 — 验证报告

日期：2026-09-27
分支：`feat/viewer-ux-redesign`
方案：[2026-09-27-browser-correctness-and-performance-repair-plan.md](../superpowers/plans/2026-09-27-browser-correctness-and-performance-repair-plan.md)
基线：`6e63585`（本轮修复的起点；工作区当时干净）

本报告记录 11 类问题的修复内容、每条对应的永久回归测试，以及尚未完成或有意偏离方案的部分。所有数字来自本机 Debug 构建（`swift test`），是观测值而非性能门槛。

## 1. 修复清单与回归测试

| # | 问题 | 修复 | 回归测试 |
|---|---|---|---|
| 1 | 坏图尺寸为 nil，反复探测/回填/刷新（1.2 s 22 次发布） | 失败按**文件版本**记忆（`dimensionProbeFailures: [path: version]`），只探测真正缺失且未失败的项目；列表变化不再清空负缓存，改为按当前目录裁剪；一次探测只发布一次 | `DimensionProbeLoopTests.testAnUnreadableImageIsProbedOnceRatherThanOnEveryReload`（≤3 次发布）、`testAFailedHeaderIsReadAgainWhenTheFolderReopens` |
| 2 | 同路径换图后返回旧像素/旧尺寸 | `DecodeCacheKey` 增加 `version`（`SourceFileIdentity.versionToken`）；`DecodeCoordinator` 在请求开始时捕获版本、探测 await 之后校验代次；`DimensionProbe` 的缓存与 in-flight 都按版本区分 | `SamePathReplacementTests`（解码缓存、尺寸探测、观察者重扫三条路径） |
| 3 | 快速切目录时旧扫描覆盖新目录 | `open(url:)` / `openFolder` / `rescanPreservingCurrent` / `reloadWithCurrentSort` 统一走 `beginFolderRequest` 捕获的**目录代次**，发布前校验代次与目录 | `FolderSwitchRaceTests`（3000 文件 → 1 文件；两次 open） |
| 4 | 抽屉强引用缓存无上限（200 张 ≈69 MiB，清空后仍保留） | 按**可见窗口 + 预加载带**裁剪，数量上限与 24 MiB 字节预算同时生效；关闭/零窗口回退到小上限；迟到投递若文件已不在列表则不入缓存；缓存条目带版本，列表变化时剔除失效版本 | `DrawerThumbnailBudgetTests`（窗口内、清空列表、同路径替换） |
| 5 | 每次缩略图投递重算整目录布局（1k→50k：1.3→28.7 ms/次） | `GalleryGridView` 缓存行几何（键：布局类型、缩略图尺寸、宽度、内容修订号）；每次投递只取一次窗口；`GalleryLayout.visibleRows` 改为二分查找（原本全表过滤） | `GallerySyncAndScrollTests.testDeliveredThumbnailsDoNotRebuildTheGeometry`（20 次投递、4000 项，重算 ≤1 次） |
| 6 | 进子目录改根、重复行、点击失效 | 树模型「根」与「焦点」分离：根内移动只改高亮，向上越出根才扩展并把**原子树挂回**；视图顶层改为「上一级操作项 + 根节点」，真正的层级数据源；「上一级」有独立身份（不再与同名文件夹行混同） | `FolderTreeSidebarTests` 5 项（无重复行、每行可点、下降保留根与展开、刷新保留展开、向上扩展） |
| 7 | 图库列表与 session 不一致（显示 b 打开 a） | 列表变化统一由会话事件驱动图库重建；隐藏时只标记（进入时重建）；排序/插入/删除都走同一路径 | `GallerySyncAndScrollTests.testTheGridFollowsAnExternalAdd`、`testTheSortShortcutReordersTheGrid`、`testTheToolbarSortReordersTheGrid` |
| 8 | 尺寸到位后不重排 | 探测批次完成后按当前 sortKey 重新排序再发布（仅当仍为「图像尺寸」）；竞态窗口内选择排序也会生效 | `DimensionProbeLoopTests.testDimensionSortChosenWhileTheProbeRunsIsAppliedWhenTheSizesArrive` |
| 9 | 进图库丢 TIFF 页码 | 区分「列表变化」「选择变化」「内容版本变化」：`FolderChangeReason` + 显示请求记录（`requestedItem`），同一文件同版本不再重载；只有真正换文件/版本替换才重新载图 | `GallerySyncAndScrollTests.testEnteringTheGalleryKeepsTheCurrentPage`、`testASortDoesNotReloadTheCurrentImage` |
| 10 | 选中项移出屏幕不滚动（且被动刷新会抢滚动位置） | `GalleryGridView.SelectionVisibility`：只有主动导航（键盘/删除/最后一张/打开目录）才 `revealCurrent`，被动刷新一律 `preserveViewport`；`reload(_:)` 用 `ReloadReason` 区分导航、用户重排、被动刷新 | `GallerySyncAndScrollTests.testSelectingTheLastImageBringsItOnScreen` |
| 11 | 图库里快捷键切换隐藏抽屉 | `perform(.toggleThumbnailDrawer)` 改为与按钮同一条路由 `toggleLeftColumn()`（图库=目录树，图像=抽屉） | `ModeRoutedCommandTests` 3 项 |

## 2. 修复前实测（用于对照）

均为一次性复现脚本（跑完已删除，结论固化进上表测试）：

- 坏图：可读目录 1.2 s 内 1 次发布；含不可读文件 **22 次**。修复后 ≤3。
- 同路径替换：64×48 → 8192×256 后第二次解码仍返回 64×48；`DimensionProbe` 在文件变成 32×24 后仍返回 8192。修复后分别为 200×120（用例尺寸）与新尺寸。
- 切目录：`directory=B`，`items=3000`（A 的列表）。修复后 `directory=B`、`items=1`。
- 抽屉缓存：60 张 20 MiB（351 KiB/张）→ 200 张外推 68.6 MiB；清空列表后仍保留。修复后按窗口/字节预算有界，清空即释放。
- 布局：1k→50k 项，单次投递 1.27→28.7 ms；`rows()` 本身 0.33→13.8 ms。修复后投递不再重算几何。
- 目录树：模型 4 行 → outline 渲染 6 行 `[上一级, A, B, C, B, C]`；点击重复行无回调。修复后每行唯一且可点。
- 图库：session `[a,b,c]` 时网格仍 `[b,c]`；双击显示 b 的格子打开 a。修复后一致。
- 页码：第 2 页进图库后 `pageIndex 1 → 0`。修复后保持。
- 选中：选中 199，可见 `0…15`，scrollY 不变。修复后自动滚入。
- 快捷键：图库内 `drawerOpen false → true`。修复后改的是可见左栏。

## 3. 与方案的偏离（有意为之）

| 方案条目 | 处理 | 原因 |
|---|---|---|
| T1 `FolderSnapshot` / `revision` / `GalleryInteraction` 身份化 | 只落地语义：`FolderChangeReason` + 保守重载 + 版本感知重显 | 行为契约已满足；不为此重写已有有效的会话/图库实现（方案第 2 节亦要求「不得为满足计划形式而重复重写」） |
| T3 `FolderItem.sourceVersionToken`、`VersionedDecodeEvent` 信封 | 未引入；版本在缓存键与显示层校验 | 内容变化只需当前文件一次 `stat`；扫描期不增加每文件一次 stat |
| T4 `DimensionStore` actor、4 并发/128 批次 | 保留单批次探测 + 版本化负缓存 | 并发/批次数值是未经验证的建议值，宜与 T9 的 Release 基准一起定 |
| T6 `GalleryViewportAnchor` 锚点恢复 | 未实现 | 不在 11 类问题内：插入/删除非当前项会让视口相对位移，但不会错位选择 |
| T5 异步 `loadChildren`、稳定 `FolderTreeItem` 引用 | 视图层用 `FolderSidebarItem` 区分操作项与节点；枚举仍在主线程 | 报告的问题（重复行/根/点击）已解决；异步懒加载需要单独评估权限/错误态 |
| §3.4 尺寸未知项排在末尾 | 未改 | 属可见行为调整，与 11 类问题无关，单独议 |
| T2 `FolderRequestGate` / `FolderScanning` 协议 + 可控替身 | 用 viewer 内的代次计数；竞态用真实大目录复现 | 保证（最后意图获胜）已由测试覆盖，测试稍慢但无需新协议 |
| T9 Release 基准 | 未跑；用「不重算」的行为断言替代计时断言 | Debug 计时作为门槛易抖动；Release 基准建议单独一轮 |

## 4. 验证

命令与结果见下方「运行记录」。全量 `swift test` 之外的验证项：

- `--filter Metal`（14 项）通过。
- 方案要求的人工项 M01/M02（真实按键 `⌘⇧T`、真实拖拽/缩放）未执行：本轮为无人值守环境，改由 `ModeRoutedCommandTests` 覆盖命令与按钮两种入口，真实按键路径仍建议在有屏幕的机器上复核一次。

### 运行记录

| 轮次 | 命令 | 结果 | 日志 |
|---|---|---|---|
| 1（基线 `6e63585`，改动前） | `swift test` | 810 用例 / 0 失败 / 542 s | `/tmp/piclight-fulltest.log` |
| 2（改动中） | `swift test` | 836 用例 / 14 用例失败 | `/tmp/piclight-fulltest2.log` |
| 3（修掉连带回归后） | `swift test` | 836 用例 / 9 用例失败（全部为 `TilePlanAndRedrawTests` 超时） | `/tmp/piclight-fulltest3.log` |
| 4（测试侧动画收尾后） | `swift test` | 836 用例 / 同样 9 个瓦片用例超时 | `/tmp/piclight-fulltest4.log` |
| 5（对照实验：排除本轮新增的 7 个测试类） | `swift test --filter "^(?!.*(DimensionProbeLoop|SamePathReplacement|FolderSwitchRace|GallerySyncAndScroll|DrawerThumbnailBudget|FolderTreeSidebar|ModeRoutedCommand)).*"` | 同样的 9 个瓦片用例超时 | `/tmp/piclight-noskip-tests.log` |
| 6（线程审计定位） | 全量运行中 `sample <xctest-pid> 1 1` | **71 线程 / 65 个阻塞在 `-[NSAnimation _runBlocking]`**，dispatch 软上限 64 已被触及 | `/tmp/piclight-midrun.sample` |
| 7（关闭离屏窗口动画后） | 全量运行中同法采样 | **28 线程 / 17 个动画（瞬时）**，无软上限告警 | `/tmp/piclight-noanim.sample` |
| 8（最终） | `swift test` | **839 用例 / 0 失败 / 465 s** | `/tmp/piclight-noanim.log` |

第 2 轮暴露了两个由本轮改动引入的连带回归，均已修复并复测：

- **空目录文案**：`showCurrentItemIfNeeded` 在「没有当前项」时提前返回，空状态没有被渲染，`folderHasNoImages` 变成了 `noImageOpened`（`AppStartupTests`、`LoadingStateTests`）。现在没有当前项时一律走载入路径。
- **一次发布会解码两次**：会话的 `onItemsChanged` 与 `onCurrentChanged` 都会询问「屏幕上的图对不对」，同一文件因此被请求两次（`ResizeWiringTests` 期望 1 次解码、`NativeDetailWiringTests` 期望 1 次 head 请求）。现在用 `requestedItem`（url + version）记录进行中的请求，第二次询问直接返回。

第 3 轮的失败集中在 `TilePlanAndRedrawTests`（Metal 瓦片用例，与本轮改动无关：它们单独运行 16/16 通过、耗时 0.2 s）。按第 6 节的采样证据（64 个线程池线程阻塞在 `-[NSAnimation _runBlocking]`），这批超时是测试间动画残留导致的线程池耗尽，属测试基础设施问题。本轮已加入测试侧收尾（`TestAppKit.close(_:)` / `settleAnimations(_:)`），并做了定向验证：`GallerySyncAndScrollTests|FolderTreeSidebarTests|ModeRoutedCommandTests|DrawerThumbnailBudgetTests` 之后紧接 `TilePlanAndRedrawTests|TileTextureInvariantTests`，34 项全部通过（瓦片组 0.05 s）。

### Release 基准（T9）

命令：`swift test -c release --filter GalleryPerformanceTests`（3 项通过，日志 `/tmp/piclight-release-perf.log`）。

| 指标 | Debug（修复前） | Release（修复后） |
|---|---|---|
| 50,000 项目录，单次缩略图投递 | 28.7 ms | **0.005 ms**（100 次共 0.542 ms），几何重算 **0 次** |
| `uniformRows` / `adaptiveRows`（50k 项，一次性） | 13.8 ms（仅 uniform） | **3.4 ms / 4.9 ms** |
| 可见行查询（10,000 行 ×200 次） | 全表过滤 98.8 ms | **二分 0.044 ms**（约 2200×） |

测试同时断言二分查找与线性扫描在 6 个边界矩形上结果完全一致（`testVisibleRowsMatchTheLinearScanAndDoNotScanTheFolder`），并断言 100 次投递最多触发 1 次几何重算。

## 5. 对方案的评估

方案整体可用，且对本轮草稿的批评基本正确。已采纳的关键意见：排序两个入口（工具栏 / 快捷键）必须分开测；隐藏图库不应重建；被动刷新不得抢滚动位置；尺寸失败负缓存要绑定版本并按目录裁剪；探测的 in-flight 必须按版本合并；await 之后要补代次校验；抽屉要按字节与窗口预算；「上一级」需要独立身份；向上扩展要保留原子树；`visibleRows` 的全表扫描要处理。这些都已落地并有对应测试。

未采纳的部分及理由见第 3 节：主要是 T1 的快照/revision 类型、T3 的 `sourceVersionToken` 与事件信封、T4 的 `DimensionStore` actor 与并发/批次参数、T5 的异步 `loadChildren`、T6 的视口锚点、§3.4 的未知尺寸排序调整。它们要么是本轮 11 类问题之外的增强，要么需要独立基准来决定参数；方案本身也声明这些是建议的目标设计而非验收条件。

## 6. 未完成项

1. ~~全量测试的线程池饱和（T10 验证项）~~ **已定位并修复**。
   - 症状：`TilePlanAndRedrawTests` / `TileTextureInvariantTests` 在全量运行中超时（30–80 s），单独运行 16/16 通过（0.2 s）。
   - 过程与证据：① 对照实验证明与本轮新增测试无关（排除后同样失败）；② 在失败运行中 `sample` 进程，得到 **71 线程、其中 65 个阻塞在 `-[NSAnimation _runBlocking]`**，dispatch 软上限 64 已被触及，主线程正卡在该用例的 20 s 信号量等待里；③ 定位到原因：`NSWindow.animationBehavior` 默认对 order-front/close 做动画，而测试窗口被移到屏幕外后关闭，该动画永远无法完成，于是**每个测试窗口都留下一个阻塞在动画驱动里的线程池线程**；④ 修复：测试侧统一设置 `animationBehavior = .none`（`TestAppKit.prepareForOffScreen`），并在关窗前让动画收尾（`TestAppKit.close`）。
   - 修复后：同样时机采样为 **28 线程 / 17 个瞬时动画、无软上限告警**；全量 **839 用例 / 0 失败 / 465 s**。线程峰值由 `ThreadAudit` 在每次运行时打印（`THREAD-AUDIT peak N threads`），防止回归。
2. **Release 性能基准（T9）**：布局缓存的效果由「重算次数」断言保证（`GalleryPerformanceTests.testDeliveriesDoNotRebuildGeometry`）；Release 下的毫秒分布见下方「Release 基准」。该文件同时断言二分查找与线性扫描在边界处结果一致，避免用性能换正确性。
3. **人工验收**：M01（真实按键切换左栏）、M02（深层目录/符号链接下的树行为）。
