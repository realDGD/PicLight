# PicLight 浏览与图像状态修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> 本文是修复建议与测试执行方案，不表示修复已经完成。建议由同一执行者顺序实施共享状态相关任务；是否采用多代理由用户决定。

**Goal:** 修复目录浏览、图库选择、图像版本、异步发布与资源保留中的 11 类问题，使“目录、列表、选择、屏幕像素”一致，并用永久回归测试证明。

**Architecture:** 保留 `FolderSession` 作为目录与选择的唯一状态来源，将列表变化、选择变化、文件内容变化分开处理。异步扫描、尺寸探测、解码和缩略图投递都携带开始时捕获的身份及请求标记；目录树使用真正的层级数据源，视图缓存与布局工作按可见窗口约束。

**Tech Stack:** Swift 6 / SwiftPM / AppKit / XCTest / ImageIO / CoreGraphics / 现有 Metal 与 PicPNGStream。

**Spec:** [现有 UX 规格](../../specs/viewer-ux-redesign.md)，重点第 3、9、13–17 节；本文第 3 节补充本次修复的行为约定。目录树的“稳定根目录”是对旧第 9.4 节的建议修订，实施时须同步规格及原有测试。

## Global Constraints

- 最低运行系统继续为 macOS 14.0；维持 `Package.swift` 中构建 SDK 标记 26.0 及现有可用性分支，不将修复变成系统版本升级。
- 继承规格：“Keep all image operations routed through shared commands/state instead of duplicating behavior.”
- 继承规格：“Preserve large-image bounded decoding, tile-cache correctness, and existing Metal rendering behavior.”
- 继承规格：“Thumbnail drawer and folder browser must virtualize rows/items.” / “Folder tree uses lazy enumeration.”
- 继承规格：“Do not unnecessarily re-decode the current image simply because the browser mode was entered and exited.”
- 继续使用系统 ImageIO 和现有管线，不增加第三方运行时依赖，不递归索引整块磁盘。
- 不重写 Viewer 的整体架构。只提取本次需要独立验证的请求、探测与缓存单元。
- 不降低已有滑块回流、超大图占位、瓦片身份、方向和色彩管理的正确性要求。
- 本文中的新接口、预算与行为选择均为建议的目标设计；当前代码是否已满足，必须由对应测试判定。
- 现有未提交改动需保留并逐项审阅；不能直接覆盖、整体提交或将其当作已验证基线。

## Review Focus

1. **A → B → A，以及同目录两次扫描乱序**：旧结果不能通过“路径相同”检查重新生效。由 T2 / R03-02、R03-03 验证。
2. **同一路径在探测、解码或主线程投递之间被替换**：旧像素不能被标成新版本，旧任务不能删除新任务记录。由 T3 / R02-02～R02-05 验证。
3. **用户滚离选中项后，后台尺寸回填或缩略图到达**：不能突然把视口拉回选中项。由 T6 / R10-02、R10-03 验证。
4. **窗口关闭、图库退出、空目录及迟到回调**：不得重新发布 UI、重新填满缓存或继续自发探测。由 T2、T4、T8 / R03-05、R01-04、R04-03 验证。
5. **树节点折叠再展开、深层目录、路径前缀和符号链接**：节点不重复，点击有准确目标，不递归循环或在主线程遍历大量子目录。由 T5 / R06-02～R06-06 验证。

---

## 1. 基线、证据与范围

### 1.1 本方案的代码基线

- 检查日期：2026-09-27。
- 当前分支：`feat/viewer-ux-redesign`。
- 已提交基线：`6e63585`；此前还有 `1057f9b` 的 SDK 构建修正。
- 编写时已有 13 个文件存在未提交修改，涉及 FolderSession、图库、目录树、解码缓存、尺寸探测、抽屉和测试。工作区可能继续变化，以下草稿评价仅对应编写时读取的内容。
- 本次只生成文档，没有运行新的全量测试，也没有把草稿标记为修复完成。

已提交的滑块结束事件、重排期间缩略图保留和窗口尺寸变化布局修正，应作为回归基线保留。不要在此轮重新引入相同问题。

### 1.2 如何理解已有实测

此前复现与用户提供的复核报告大体一致，足以安排修复，但临时测试需要转为仓库内可重复运行的测试。报告中的具体次数、毫秒数与内存值属于相应机器和构建配置下的观测，不直接成为所有机器的性能门槛。

| 编号 | 已知问题与边界 | 优先级 | 负责任务 |
|---|---|---|---|
| 1 | 坏图的尺寸一直为 nil，重复探测、回填、刷新；约 1.2 秒出现 21–22 次发布 | P0 | T4 |
| 2 | 同路径覆盖后，解码与尺寸缓存可能返回旧内容；还须覆盖处理中换版本 | P0 | T3 |
| 3 | 快速切目录时，旧目录扫描结果覆盖新目录；同目录乱序也须防护 | P0 | T2 |
| 4 | 抽屉自身强引用缓存不受管线预算约束；200 张约 69 MiB，清空列表仍可保留 | P1 | T8 |
| 5 | 每次缩略图投递重复整目录布局；50k 项 Debug 单次约 25–29 ms | P2 | T9 |
| 6 | 进入子目录会改根；层级与展平数据混用还造成重复行、点击失效 | P1 | T5 |
| 7 | session 与网格列表不一致，显示 b 的格子可能按新索引打开 a | P0 | T1 |
| 8 | 尺寸已知时排序正确；选择排序早于探测完成时，回填后可能不重排 | P1，随探测一起修 | T4 |
| 9 | 同一 TIFF 进入图库时，尺寸回填触发重载，页码由第 2 页回到第 1 页 | P0 | T1 |
| 10 | 键盘导航到屏幕外项目后没有滚入可见；修复须防止后台刷新抢滚动位置 | P1 | T6 |
| 11 | 图库里的快捷键可能切换隐藏抽屉，而按钮切换目录树 | P1 | T7 |
| X | 全量测试曾出现线程池饱和；另一轮 810 用例通过，属于未稳定复现问题 | 验证项 | T10 |

优先级含义：P0 阻断本轮功能验收；P1 在发布前完成；P2 性能优化单独衡量，但不得以它延后 P0 的正确性修复。

两点需要修正原报告的表述：

- “排序保留目录树状态”不能一概成立。工具栏排序和菜单/快捷键排序的调用链不同，两条都要测。
- 一次全量通过只能证明该次通过。`--filter Metal` 不能替代 `TilePlanAndRedrawTests` 的验证，后者才是此前超时涉及的测试类。线程池样本只提供线索，不能直接断言根因是环境。

尚未确认的“网格真实键盘焦点”“多窗口复用目标”不列为本轮已确认缺陷；放入人工探索项，有复现再单独立项。此前有效的视口实验没有证明缩放必然丢失，因此缩放是保护性回归要求，而不是已确认症状。

## 2. 对现有修复草稿的处理

| 草稿方向 | 建议保留 | 合入前必须补齐 |
|---|---|---|
| `FolderSession` 只在索引或身份变化时通知 current | 区分列表回填与切图的方向 | 索引改变仍不等于图像改变；相同身份不同内容版本必须更新；两个回调不能重复发起首次解码 |
| `onItemsChanged` 调用图库 reload | 让列表更新进入图库 | 区分内容、顺序、尺寸、选择；隐藏图库只标脏；避免每次全重建、重复 reload 和自动滚动 |
| 解码 key 加 version | 复用 `SourceFileIdentity.versionToken` | probe 的 await 后补代次检查；完成与 UI 接收时校验；不得完成时读取新 version 标记旧图片 |
| 尺寸缓存记录 version | 让已完成缓存失效 | `inFlight` 仍按 path 合并时会复用旧任务；清理也须按请求标识，不能旧任务清掉新任务 |
| 失败路径集合阻断探测 | 可以作为止血思路 | 失败须绑定文件版本，不能仅 path；排序不能清空失败记录；同路径修复后应自动允许新版本探测 |
| 切目录加 generation | 防止 A 覆盖 B | 同目录两次 rescan、A→B→A、旧 watcher、排序期间变化、关闭窗口的失效 |
| 树传 root、按 item(atRow:) 点击 | 正确的层级与选择方向 | reloadData 全程回调抑制；已有 children 的再次展开也更新模型；多层 reveal 须逐级加载 |
| 树在子目录中保留 root | 符合用户反馈的目标方向 | 稳定节点身份、向上扩展时保留子树、外部打开策略、符号链接与权限错误 |
| 网格增加 rows cache | 避免重复布局计算 | 可见行查询仍可能全表扫描；纯缩略图投递不能重建几何；失效键须覆盖尺寸变化 |
| 每次 reload 都 scrollCurrentIntoView | 仅保留主动导航场景 | 元数据回填、被动刷新、同一选择重复同步不能抢滚动位置 |
| 抽屉按数量裁剪缓存 | 裁剪可见窗口与移除失效文件 | 字节预算；关闭/空窗口；迟到投递；滚动后裁剪；cell 和 layer 强引用释放 |
| 快捷键改走 toggleLeftColumn | 与按钮共用模式路由 | 两种模式、原先状态组合、菜单状态和实际按键验证 |

执行前先把草稿映射到 T1–T10：已写的部分补测试并审阅，未写的部分再实现。不得为满足计划形式而重复重写已有有效实现。

## 3. 建议冻结的用户行为

### 3.1 目录、列表、选择与图像

1. 用户看到的目录标题、网格顺序、当前项和操作目标来自同一份已发布快照。
2. 打开新目录期间，保留上一份完整快照并显示目标目录的加载状态；首次打开则显示加载空态。成功后一次替换目录和列表。失败显示错误，保留上一份有效快照，不能把 A 的列表标为 B。
3. 显式打开图片选中该图片；显式打开另一个文件夹默认选新目录排序后的第一张，空目录则没有选择。不要跨目录通过同名文件意外继承选择。
4. 同目录重排、插入和尺寸回填，优先保持当前文件身份；删除或外部移除继续尊重现有 `deleteFollowUp` 设置，不能借此修复改掉“智能跟随/停留位置”偏好。
5. 网格单击、双击、Return 都携带项目身份。遇到已删除的旧格子事件，忽略并同步视图，绝不打开当前相同下标的另一项。
6. 进入图库、尺寸回填、重排不改变同一文件同一版本的 TIFF 页码；保留合法的缩放、中心和播放/暂停意图。
7. 更换文件、主动换页与同路径内容版本变化是不同事件。内容替换后重新读取描述信息；建议保留仍合法的页码，页数减少时夹到最后一页，尺寸变化时按既有几何规则校正视口。
8. 同一图像请求尚未完成时，重复的元数据通知不能再发一个相同请求；失败后也不能因被动刷新无限重试。新版本、显式重试或主动离开后再次打开才允许重试。

### 3.2 左侧目录树

推荐的稳定根行为如下，需替换旧规格中“当前文件夹永远就是根”的描述：

- 首次进入图库，以当前图片目录为导航根。
- 在根内进入子目录：保留根、兄弟目录与用户展开状态，只更新当前目录高亮及右侧内容。
- “上一级”始终表示当前目录的父目录。根内上一级只移动选择；从根继续向上，则把根扩展到父目录，保留原根的已加载子树。
- 显式从 Finder / 打开面板打开根外目录：建立新的导航根；打开根内目录保留现有树。
- 排序、缩略图到达、尺寸回填不改变展开状态。用户主动折叠的节点，普通刷新不得自动展开。
- 导航到被折叠的后代时，允许只展开使目标可见的祖先链。
- 顶层只由“上一级”操作项（若有）和根节点组成。文件夹通过真正的 children 递归提供，不把展平列表再次作为顶层输入。
- “上一级”是独立的操作项身份，即使目标路径等于树内父节点，也不能与该节点混成同一个 outline item。
- 跟随符号链接时使用规范化目标判断包含关系，并对祖先身份去重防止循环；不递归预读未展开子树。读目录失败保留节点并提供错误/重试状态，不能伪装成已确认的空目录。
- 本次不加入导航历史、收藏、拖放文件管理或全盘索引。

### 3.3 滚动与刷新

| 触发 | 选择处理 | 滚动策略 |
|---|---|---|
| 下一张、上一张、第一张、最后一张、明确定位项目 | 更新当前身份 | 最小滚动，使目标可见 |
| 打开新目录、首次进入图库 | 展示当前项目 | 定位当前项；空目录回到顶部 |
| 主动点击已经可见项目 | 选择该项 | 不做额外跳动 |
| 后台尺寸回填、缩略图投递 | 不改选择 | 保持视口锚点 |
| 被动插入/删除非当前项 | 保持当前身份 | 保持视口锚点 |
| 删除当前项并产生后继选择 | 按现有删除偏好 | 使新的当前项可见 |
| 用户主动排序 | 保持当前身份 | 使当前项可见；不因随后重复回填再次跳动 |
| 滑块回流、布局切换、窗口/侧栏宽度变化 | 不改选择 | 当前项可见时围绕当前项；否则围绕顶部可见项，保持相对偏移 |

锚点由“项目身份 + 相对可见区域偏移”表示，不能只保存旧 scrollY；项目被移除时退到邻近仍存在项目，最后夹到合法滚动范围。

### 3.4 尺寸与缓存

- 对每个文件版本明确区分未请求、进行中、成功、失败。空尺寸不能同时表达四种状态。
- 尺寸结果只更新它实际读取的版本。失败版本不因 reload 或排序自动重试；内容变化、显式刷新/重试可以重置。
- 自适应布局和尺寸排序复用同一探测结果；只有确实需要尺寸的场景启动探测，普通等宽网格加文件名排序不应主动扫全目录 header。
- 本方案建议尺寸按像素面积排序；未知或失败项在升降序中均放末尾，组内按自然文件名稳定排列。已知尺寸相同也按自然文件名，再按规范化路径打破相等。该缺失值策略属于明确的行为调整，应更新 `ImageSortTests`。
- 尺寸批次完成后，按当时仍有效的排序设置发布；中途改回文件名排序不能被旧尺寸任务改回去。
- 所有缓存 key 和进行中的工作都区分版本；“换 key”不代替“拒绝过期投递”。
- 抽屉缓存按实际 `bytesPerRow × height` 计费，不能仅按 width × height × 4 估算；共享 CGImage 的引用不能在进程总内存估算中重复相加。

## 4. 文件和接口边界

下面列出建议新增文件，不要求先搭建通用框架。每个文件随负责的任务和测试一起落地。现有文件内的类型应先复用，避免同名概念重复存在。

| 单元 | 文件 | 职责 |
|---|---|---|
| 会话快照与事件（新增） | `PicViewMac/Folder/FolderSnapshot.swift` | 有序 items、directory、revision、选择、变化原因；明确一次原子发布 |
| 会话（修改） | `PicViewMac/Folder/FolderSession.swift` | 选择策略、应用快照；保留现有调用兼容入口并逐步迁移 |
| 文件版本请求（新增） | `PicViewMac/Imaging/VersionedSource.swift` | url + 既有 versionToken；只封装，不发明另一套身份算法 |
| 目录请求闸门（新增） | `PicViewMac/Folder/FolderRequestGate.swift` | folder epoch、scan sequence、失效与判断 |
| 扫描接口（修改） | `PicViewMac/Folder/FolderScanner.swift` | `FolderScanning` 协议、真实实现、后台读取；允许确定性替身 |
| 尺寸状态（新增） | `PicViewMac/Imaging/DimensionStore.swift` | 版本化结果、负缓存、合并请求、取消与重试 |
| 解码（修改） | `DecodeCache.swift`、`DecodeCoordinator.swift`、`DimensionProbe.swift`（均在 Imaging） | 请求开始/完成/发布全链路身份与代次 |
| 图库（修改） | `PicViewMac/Gallery/FolderBrowserViewController.swift`、`GalleryGridView.swift`、`GalleryLayout.swift` | 消费快照、身份事件、视口策略和几何缓存 |
| 目录树（修改） | `PicViewMac/Gallery/FolderTreeModel.swift`、`FolderTreeSidebarView.swift` | 根与焦点分离、稳定层级节点、异步懒加载 |
| 抽屉缓存（新增） | `PicViewMac/Sidebar/DrawerThumbnailCache.swift` | UI 自身引用的预算、窗口裁剪和生命周期 |
| 集成（修改） | `PicViewMac/Viewer/ViewerViewController.swift`、`PicViewMac/Sidebar/ThumbnailDrawerView.swift` | 将各入口接到统一语义，不放第二份权威列表 |
| 测试辅助（新增） | `PicViewMacTests/Support/ControlledFolderScanner.swift`、`ControlledImageWork.swift` | 可手动释放的异步请求、可观测事件，不靠随机时序 |
| 基准（新增） | `PicViewMacTests/GalleryPerformanceTests.swift` | Release 结构计数及分布指标 |
| 验证报告（执行时新增） | `docs/release/2026-09-27-browser-correctness-verification.md` | 修复版本、运行命令、日志位置、未完成平台检查 |

注意：`ImageSort` 定义实际位于 `PicViewMac/Folder/FolderItem.swift`，不要修改不存在的 `ImageSort.swift`。`FolderItem.==` 目前只比较 id，不能用整个数组的 `==` 判断尺寸或文件内容是否变化。

## 5. 实施顺序与提交边界

| 批次 | 顺序及依赖 | 可以独立验收的交付 |
|---|---|---|
| A：正确性 | T1 → T2 → T3 → T4 | 一致快照、有效请求、正确版本、无尺寸刷新循环；覆盖 1/2/3/7/8/9 |
| B：交互与资源 | T5；T6 依赖 T1；T7；T8 依赖 T3 | 稳定树、正确滚动和路由、有界缓存 |
| C：性能与交付 | T9 依赖 T1/T4/T6；T10 汇总全部 | 热路径不重算全表、完整验证与可追溯报告 |

T4 是 P0 止血工作，不能因为它排在共享契约之后就拖到性能批次。A 批的任务只做必要正确性，不夹带布局优化。每个任务形成单独可回退的提交；共享契约可在同一任务中保留迁移适配，不能提交编译不通过的中间状态。

执行前：

- [ ] 记录 HEAD、工作区差异、Swift/Xcode/SDK/macOS 版本；识别现有草稿归属。
- [ ] 优先在隔离 checkout 中执行；需要沿用草稿时保留其内容并记录 diff，不对原工作区做 reset/stash。
- [ ] 为各项复现指定固定测试名称，保留旧基线失败和修复后通过的日志。
- [ ] 如果当前草稿已使测试通过，用旧提交的隔离 checkout 运行兼容的行为复现；不能把“缺少新接口导致编译失败”当成证明旧缺陷的证据。

### T1：让图库、选择与图像状态使用同一份会话语义（#7、#9）

**Files**

- 新增 `PicViewMac/Folder/FolderSnapshot.swift`。
- 修改 `FolderSession.swift`、`ViewerViewController.swift`、`FolderBrowserViewController.swift`、`GalleryGridView.swift`。
- 测试：扩展 `FolderSessionTests.swift`、`FolderBrowserSelectionTests.swift`、`PendingPageIndexTests.swift`；新增 `PicViewMacTests/FolderSnapshotRegressionTests.swift`。

**Interfaces**

- 新增 `FolderChangeReason`：`navigation / rescan / sort / metadata / selection / removal / sourceReplacement`。
- 新增 `FolderSnapshot`：`revision: UInt64`、`directory: URL?`、`items: [FolderItem]`、`currentIndex: Int?`；revision 仅在对外可观察状态真正变化时增加。
- `FolderSession.snapshot: FolderSnapshot`；`onSnapshotChanged: ((FolderSnapshot, FolderChangeReason) -> Void)?`。
- `apply(directory: URL?, items: [FolderItem], selection: FolderSelectionPolicy, reason: FolderChangeReason)`；策略为 `first / preserveIdentity(FileIdentity?) / preserveIndex(Int?)`，删除入口仍按已有设置选择策略。
- `GalleryInteraction` 携带 `identity: FileIdentity` 与 `snapshotRevision: UInt64`；grid 两个交互回调改为该值。host 的打开入口改为 `openGalleryItem(identity: FileIdentity)`。
- Browser 消费 `apply(snapshot: FolderSnapshot, reason: FolderChangeReason)`；不再从多个入口分别猜测是否 rebuild。

**步骤**

- [ ] 编写 R07-01～R07-04 和 R09-01～R09-03，先证明插入、重排与 TIFF 回填错误；测试交互目标的文件身份和最终像素，不能只断言 currentIndex。涉及文件替换的 R09-04 归 T3 实施，避免本任务依赖尚未落地的版本接口。
- [ ] 运行 `swift test --filter 'FolderSnapshotRegressionTests|FolderBrowserSelectionTests|PendingPageIndexTests'`，保留可归因的失败。
- [ ] 在 session 一次应用 directory/items/selection 后发出一次事件；维护路径到索引映射或按变更批次重建，避免每帧全表查找。现有旧回调若暂时保留，只由统一发布派生，不能在 Viewer 双重订阅。
- [ ] 图库可见时应用相同 revision 的快照；隐藏时记录最新 revision 并标脏，重新进入时再创建视图和请求缩略图。元数据更新只更新必要几何，不重置目录树。
- [ ] 点击按身份解析；旧 revision 的事件若项目仍在当前目录中可解析到该项目，已删除或来自旧目录则忽略。不能退回使用旧下标或跨目录同名匹配。
- [ ] Viewer 区分“当前文件/版本/页码请求”和“列表索引”。同时记录进行中的显示请求，避免首次 head 到达前被重复通知重启；T3 补齐版本化请求信息。
- [ ] 只因元数据或排序变化不得重新 apply 首帧。真正换图、版本替换、主动换页走专用加载路径，处理页数减少与失败状态。
- [ ] 重跑上述测试，加跑 `swift test --filter 'FolderSessionTests|AnimationLifecycleTests|ViewportStateTests|FolderBrowserModeTests'`。
- [ ] 审阅并仅提交本任务改动，建议主题 `fix: synchronize gallery snapshots and preserve image state`。

### T2：隔离目录扫描、刷新、排序和窗口生命周期（#3）

**Files**

- 新增 `PicViewMac/Folder/FolderRequestGate.swift`、`PicViewMacTests/Support/ControlledFolderScanner.swift`、`PicViewMacTests/FolderRequestRaceTests.swift`。
- 修改 `FolderScanner.swift`、`FolderSession.swift`、`ViewerViewController.swift`；扩展 `FolderDynamicsTests.swift`。

**Interfaces**

- `FolderScanning: Sendable`，方法 `scan(directory: URL) async throws -> [FolderItem]`；`FolderScanner` 遵循。
- `FolderLoadToken: Equatable, Sendable` 包含 `directory: URL / epoch: UInt64 / sequence: UInt64`。
- `@MainActor FolderRequestGate` 提供 `beginNavigation(to:) -> FolderLoadToken`、`beginRescan() -> FolderLoadToken?`、`accepts(_:) -> Bool`、`invalidate()`。
- 独立 `sortRevision: UInt64` 标记用户排序设置变更；排序结果只能作用于它读取的 items revision，并按照当前有效设置计算。
- Viewer initializer 注入 `scanner: any FolderScanning = FolderScanner()`；实际依赖继续有默认值，现有调用无需改语义。
- 测试替身按请求 ID 提供 `waitUntilRequested` 和 `complete(requestID:with:)`；不能仅按 URL 标识，因为 A→B→A 有两次 A。

**步骤**

- [ ] 编写 R03-01～R03-06，手工控制完成顺序，验证最后有效意图获胜和原子目录发布。
- [ ] 运行 `swift test --filter FolderRequestRaceTests`，确认旧扫描能覆盖新结果的行为失败。
- [ ] 为 open(file)、openFolder、watcher rescan、菜单排序、工具栏排序统一请求入口；新的导航推进 epoch，同目录 rescan 推进 sequence。
- [ ] watcher 回调捕获它启动时的目录和 epoch；已停止 watcher 的排队事件不得变成当前目录的新 rescan。
- [ ] 每个 await 之后及最终 MainActor 发布前验证 token。取消用于节省工作，token 才是正确性防线。
- [ ] 将 pendingDirectory 与已发布 snapshot.directory 分开，成功后用 T1 的 apply 原子更新；失败保留有效快照并结束加载态。
- [ ] 排序不拿旧 items 覆盖较新的目录扫描；若 items revision 或 sortRevision 已变，针对最新快照重新计算，合并重复请求。
- [ ] 处理 `FolderSession.rescanPreservingCurrent(using:)` 旁路：迁移到协调入口或加等价门禁，不能留下一个不受保护的写入入口。
- [ ] 关闭窗口、teardown、清空会话时失效请求并停止 watcher；释放被替身阻塞的任务时不得再发布。
- [ ] 运行 `swift test --filter 'FolderRequestRaceTests|FolderDynamicsTests|OpenPathAndTrashTests|LifecycleEpochTests'`。
- [ ] 仅提交本任务改动，建议主题 `fix: reject stale folder and sort publications`。

### T3：让缓存、进行中任务与 UI 发布共享文件版本（#2）

**Files**

- 新增 `PicViewMac/Imaging/VersionedSource.swift`、`PicViewMacTests/Support/ControlledImageWork.swift`、`PicViewMacTests/SourceReplacementRegressionTests.swift`。
- 修改 `DecodeCache.swift`、`DecodeCoordinator.swift`、`DimensionProbe.swift`、`ViewerViewController.swift`、`FolderItem.swift`、`FolderScanner.swift`、`FolderSnapshot.swift`；根据接线需要扩展 `ThumbnailPipeline.swift`。
- 扩展 `CacheIdentityTests.swift`、`DecodeCoordinatorTests.swift`、`SourceFileIdentityTests.swift`。

**Interfaces**

- `VersionedSource: Hashable, Sendable`：`url: URL`、`versionToken: String`；`static capture(_ url: URL) -> VersionedSource`，只调用现有 `SourceFileIdentity.read(at:)`。
- `DecodeRequestContext: Sendable`：`source: VersionedSource`、`generation: Int`、`pageIndex: Int`。
- `VersionedDecodeEvent: Sendable`：`context: DecodeRequestContext`、`event: DecodeEvent`；`DecodeCoordinator.show` 的事件回调升级为此类型，并迁移所有调用点和测试。
- `DecodeCacheKey` 保留 url、version、pageIndex、level。动画帧仍另外区分 frameIndex。
- Viewer 用“source + pageIndex + 当前解码级别需求”标记 requested/displayed 状态；纯索引变化不修改这些状态。
- `FolderItem` 增加 `sourceVersionToken: String?`（默认 nil 兼容合成测试数据）；真实 scanner 在后台捕获并填写。快照的实际变化判断显式比较该字段和 pixelSize，不依赖 `FolderItem.==`。由此确保保留文件名、尺寸、mtime 的内容替换仍会发布 sourceReplacement；生产扫描中缺失/不可读身份走错误或失效状态，不把 nil 当作永久有效版本。

**步骤**

- [ ] 编写 R02-01～R02-06 和 R09-04（后者放在 `SourceReplacementRegressionTests.swift`）；假解码器先捕获 v1 输出后阻塞，再写入 v2，最后释放 v1，避免测试实际读到 v2 却声称是旧结果。
- [ ] 运行 `swift test --filter 'SourceReplacementRegressionTests|CacheIdentityTests'`，确认同路径旧图或旧尺寸失败。
- [ ] 请求开始捕获版本；预测 level 的 await 返回后先校验 generation，再修改 currentKey、取缓存或发布事件。缓存命中也必须受代次约束。
- [ ] 进行中的 dimension/preload/thumbnail 按版本和请求 ID 管理。旧完成只能清理自己的记录，不能把新版本任务置 nil。
- [ ] 解码/探测完成时再次比较实际版本；不一致则丢弃结果且不缓存为当前版本。保持源快照不变，不得以完成时的版本给旧产物重新命名。
- [ ] 在 UI 主线程接收 envelope 时再次校验当前意图、文件版本和生命周期；head、frame、failure 与换页结果都适用。
- [ ] 当前图生成抽屉缩略图时，绑定 displayed source 的版本，不能把旧 canvas bitmap 当作新文件预览。图库/抽屉已存在的 thumbnail 版本机制一并审查，不重复创建第二套算法。
- [ ] 同路径版本变化时取消或淘汰旧工作；动画 cache-hit 行为维持原合同，不因 envelope 改动丢掉后续帧。删除后重建同路径、原子替换、保留 mtime 的替换均覆盖。
- [ ] 运行 `swift test --filter 'SourceReplacementRegressionTests|CacheIdentityTests|CacheInvariantTests|DecodeCoordinatorTests|SourceFileIdentityTests|NativeInFlightReplacementTests|ThumbnailPipelineTests'`。
- [ ] 仅提交本任务改动，建议主题 `fix: carry source versions through decode publication`。

**边界说明：** stat 前后校验应覆盖普通编辑器保存与原子替换。它不是内容哈希或不可变文件快照，不能宣称可证明所有敌对写入时序下字节完全一致。如果需更强保证，另行评估固定文件描述符/数据源快照，不能在本轮热路径上散布整文件哈希。

### T4：尺寸探测状态机、失败负缓存与完成后的排序（#1、#8）

**Files**

- 新增 `PicViewMac/Imaging/DimensionStore.swift`、`PicViewMacTests/DimensionProbeLifecycleTests.swift`。
- 修改 `DimensionProbe.swift`、`FolderScanner.swift`、`FolderItem.swift`、`FolderBrowserViewController.swift`、`ViewerViewController.swift`。
- 扩展 `ImageSortTests.swift`、`CorruptImageNavigationTests.swift`。

**Interfaces**

- `DimensionState`：`unknown / loading / ready(CGSize) / failed`；状态存储以 T3 的 `VersionedSource` 为 key。
- `DimensionStore` actor：`dimensions(for: VersionedSource, consumer: UUID) async -> DimensionOutcome`、`cancel(consumer: UUID)`、`invalidate(_ source: VersionedSource)`、`trim(keeping: Set<VersionedSource>)`。
- initializer 注入 `readSize: @Sendable (URL) async -> CGSize?`，生产默认适配 `ImageHeaderProbe.pixelSize(of:)` 并在后台执行；测试替身可阻塞指定读取。取消一个 consumer 仅撤销其需求，所有 consumer 都离开时才取消底层工作；进行中记录按 source 与 requestID 清理。
- `DimensionOutcome`：`ready(CGSize) / unreadable / superseded`。superseded 不得写成当前版本的失败。
- `DimensionProbe.longEdge(of:)` 作为该 store 的适配；图库与尺寸排序注入同一个 store，避免各自读取相同 header。
- Browser 只保留一个可取消的尺寸批次任务，批次携带 folder epoch、items revision 和各 source；只把当前快照里仍匹配的结果合入。
- 默认最多 4 个并发 header 读取，按最多 128 项一个批次发布；二者为本方案建议初值，性能记录支持后可调。每批仅对实际变化项发布一次。

**步骤**

- [ ] 编写 R01-01～R01-05、R08-01～R08-04，测试探测调用数、状态转换、列表发布次数和最终顺序。
- [ ] 运行 `swift test --filter 'DimensionProbeLifecycleTests|ImageSortTests'`，确认坏图循环和完成后排序遗漏。
- [ ] 成功、失败和进行中状态均绑定版本；只处理缺失且允许探测的项目。同一版本多个消费者合并一个读取，整个目录不反复填充。
- [ ] 元数据合入按 source 身份查找当前条目，不能把旧数组直接 setItems，也不能只按路径回填已经替换的文件。
- [ ] 没有实际尺寸变化就不发布列表；失败更新留在 store 的状态中。避免 session 发布后又手动 reload 造成双重刷新。
- [ ] 去掉“URL 列表一变就清空所有失败路径”的策略。保留当前目录仍存在版本的负缓存，新版本重试；离开目录时按有界集合裁剪。
- [ ] 明确取消的是运行中的 Task，不能只 cancel 包装它的 DispatchWorkItem。退出图库后，纯布局消费者停止；如果当前排序仍需要尺寸，排序消费者可以继续，但不能复活隐藏 UI。
- [ ] 尺寸变化按当前有效 sortKey/direction 合并排序；采用第 3.4 节的未知值与 tie-break 规则；发布原因标为 metadata，保持当前身份和视口锚点。
- [ ] 限制批处理并发，取消前及真正读 header 前再次检查任务状态。错误不触发无条件定时重试。
- [ ] 运行 `swift test --filter 'DimensionProbeLifecycleTests|ImageSortTests|CorruptImageNavigationTests|FolderSnapshotRegressionTests|FolderRequestRaceTests'`。
- [ ] 仅提交本任务改动，建议主题 `fix: bound dimension probing and apply deferred sorting`。

### T5：真正的层级目录树与稳定导航根（#6）

**Files**

- 修改 `FolderTreeModel.swift`、`FolderTreeSidebarView.swift`、`FolderBrowserViewController.swift`、`docs/specs/viewer-ux-redesign.md` 第 9.4 节。
- 扩展 `FolderTreeTests.swift`、`FolderBrowserSidebarLayoutTests.swift`；新增 `PicViewMacTests/FolderTreeInteractionTests.swift`。

**Interfaces**

- `FolderTreeModel.setRoot(_ url: URL)`、`focus(on: URL)`、`setExpanded(_ expanded: Bool, for: URL)`；不要使用 toggle 表示来自 AppKit 的明确 expand/collapse 通知。
- Sidebar `update(root: FolderTreeModel.Node?, currentPath: String?)`，顶层返回上一级 action + root。
- 提供稳定 `FolderTreeItem` 引用或等价 identity wrapper；身份为 `folder(canonicalPath) / up(targetPath)`，不把可变 children/isExpanded 纳入身份。
- model 注入 `loadChildren: @Sendable (URL) async throws -> [URL]`；主线程只合并结果，子节点是否可展开采用未知/已知状态，避免对每个子节点同步再遍历。

**步骤**

- [ ] 编写 R06-01～R06-06，必须检查真正的 `NSOutlineView.numberOfRows`、`item(atRow:)` 和选择回调，而非仅检查展平模型。
- [ ] 运行 `swift test --filter 'FolderTreeTests|FolderTreeInteractionTests'`，确认重复行及折叠再展开的模型不同步。
- [ ] 顶层只提供操作项与 root；所有节点仅通过父子关系出现一次；选择回调从 outline 的实际 item 得到 URL。
- [ ] 使用稳定节点身份；`isApplyingModelState` 从 reloadData 之前开始，到展开和选中同步完成后结束，使用 defer 恢复，避免程序刷新触发导航。
- [ ] 每次真实 expand/collapse 都更新模型状态，与 children 是否已加载无关。再次展开已加载节点不重复枚举。
- [ ] 按第 3.2 节实现 stable root。深层 reveal 逐级加载缺失 ancestors；普通 metadata/sort 刷新不调用会自动展开焦点的导航方法。
- [ ] 向上扩展时挂接原子树而非丢弃；规范化包含关系按路径组件，处理根目录、符号链接循环、不可读目录和已删除目录。
- [ ] 异步 children 结果携带树生命周期和节点请求标记；新树、关闭或同节点新请求后丢弃旧结果。
- [ ] 更新旧规格及确实冲突的测试说明，保留首次进入时“不自动展示 /Users/... 全祖先链”的约束。
- [ ] 运行 `swift test --filter 'FolderTreeTests|FolderTreeInteractionTests|FolderBrowserSidebarLayoutTests|FolderBrowserSelectionTests'`，再完成人工 M01/M02。
- [ ] 仅提交本任务改动，建议主题 `fix: preserve folder navigation roots and outline identity`。

### T6：按操作原因滚入选择并保持滚动锚点（#10）

**Files**

- 修改 `GalleryGridView.swift`、`FolderBrowserViewController.swift`；根据几何需要修改 `GalleryLayout.swift`。
- 新增 `PicViewMacTests/GallerySelectionVisibilityTests.swift`；扩展 `GalleryReflowStabilityTests.swift`。

**Interfaces**

- `SelectionVisibilityPolicy`：`preserveViewport / revealCurrent`。
- `GalleryGridView.setCurrentIndex(_ index: Int?, visibility: SelectionVisibilityPolicy)`，默认保留视口。
- `GalleryViewportAnchor`：`identity: FileIdentity`、`offsetY: CGFloat`；`captureViewportAnchor() -> GalleryViewportAnchor?`、`restoreViewportAnchor(_:)`。
- `scrollCurrentIntoView()` 只在布局有效后最小滚动；保持 index→row 映射，T9 再优化可见查询。

**步骤**

- [ ] 编写 R10-01～R10-04，分别验证主动导航与被动刷新，包含实际 clipView bounds 和物化 cell。
- [ ] 运行 `swift test --filter GallerySelectionVisibilityTests`，确认末项不可见或草稿的被动刷新回拉问题。
- [ ] 按第 3.3 节传递 policy；去掉 reload 和同一索引同步中的无条件 scrollCurrentIntoView。
- [ ] 列表/几何改变前捕获锚点，布局后恢复；空列表、项删除及小于视口的内容使用合法夹取。
- [ ] 只请求新窗口需要的缩略图，保留滑块拖动期间的缓存暂停/结束恢复机制。
- [ ] 运行 `swift test --filter 'GallerySelectionVisibilityTests|GalleryReflowStabilityTests|FolderBrowserSliderTests|FolderBrowserLayoutTests'`。
- [ ] 仅提交本任务改动，建议主题 `fix: reveal explicit selections without stealing scroll position`。

### T7：按钮、菜单与快捷键统一模式路由（#11）

**Files**

- 修改 `PicViewMac/Viewer/ViewerViewController.swift` 中 `perform` 与 `toggleLeftColumn`，及实际声明菜单状态的现有调用点。
- 扩展 `FolderBrowserModeTests.swift`、`ChromeStateIndependenceTests.swift`。

**Interfaces**

- 复用现有 `toggleLeftColumn()` 和 `ViewerCommand.toggleThumbnailDrawer`；若保留旧命令名，注释明确其按模式操作当前左栏，避免多处再分支。
- 图像模式操作 drawerOpen；图库模式操作 treeSidebarVisible，两份偏好独立保存。

**步骤**

- [ ] 编写 R11-01～R11-03，参数化模式和原始 open/closed 组合。
- [ ] 运行 `swift test --filter 'FolderBrowserModeTests|ChromeStateIndependenceTests'`，确认按钮与命令路径不一致。
- [ ] 所有入口调用共同路由；菜单勾选、可用状态、提示和 accessibility 描述反映当前模式，模式切回时恢复对应左栏原状态。
- [ ] 重跑上述测试，并在真实激活窗口按默认 `⌘⇧T` 验证，避免只测直接调用 perform。
- [ ] 仅提交本任务改动，建议主题 `fix: route sidebar commands through the active viewer mode`。

### T8：给抽屉实际保留的图片设置预算与生命周期（#4）

**Files**

- 新增 `PicViewMac/Sidebar/DrawerThumbnailCache.swift`、`PicViewMacTests/DrawerThumbnailRetentionTests.swift`。
- 修改 `ViewerViewController.swift`、`ThumbnailDrawerView.swift`；扩展 `ThumbnailMemoryAuditTests.swift`、`DrawerSafetyTests.swift`。

**Interfaces**

- `@MainActor DrawerThumbnailCache`，`init(byteLimit: Int, countLimit: Int)`。
- `insert(_ image: CGImage, for source: VersionedSource)`、`image(for:) -> CGImage?`、`retainWindow(_ sources: Set<VersionedSource>)`、`removeAll()`。
- 可读 `retainedBytes / retainedCount` 采用实际行跨度；缓存记录 key 与图片一起存储。
- 建议初值：24 MiB、最多 128 项；可见 cell 自身持有正在显示的位图，cache 可淘汰其额外引用。窗口为可见行加前后各 2 行，先淘汰窗口外，再按 LRU 满足硬预算。
- 单张超过缓存预算时不入 cache，仍允许有界缩略图在当前 cell 展示。不能为了缓存命中率突破硬上限。
- 最多 4 个抽屉缩略图解码工作并行，待处理队列按当前窗口替换而不是随全目录增长；与现有共享管线并发控制合并，不叠加无限 Task。

**步骤**

- [ ] 编写 R04-01～R04-05，测试使用小的注入预算，避免为了证明上限创建数百 MiB 文件。
- [ ] 运行 `swift test --filter DrawerThumbnailRetentionTests`，确认空列表仍保留及总数增长问题。
- [ ] 替换 Viewer 的无界字典；每次存入、窗口变化、列表更换和内存压力时执行预算与身份检查，避免只在新图投递时裁剪。
- [ ] 抽屉关闭/图库占用左栏时取消抽屉请求并清空其 UI cache；共享 ThumbnailPipeline 自己的有界缓存保留以支持重开命中。空目录、切目录、窗口关闭清理 cell image/layer.contents 与重用池残留。
- [ ] 请求捕获 source、窗口生命周期与 requestID；迟到结果既不插回 cache，也不修改被复用 cell；旧完成不清掉新请求状态。
- [ ] 记录 viewer cache、cell 引用、管线缓存、在途数量，避免仅查看 NSCache 指标就宣称全路径有界。
- [ ] 保留超大图占位与当前图 proxy 复用策略，禁止缩略图请求退化为邻图全分辨率解码。
- [ ] 运行 `swift test --filter 'DrawerThumbnailRetentionTests|ThumbnailMemoryAuditTests|DrawerSafetyTests|ThumbnailRequestTests|SourceReplacementRegressionTests'`，再运行第 8 节内存场景。
- [ ] 仅提交本任务改动，建议主题 `fix: bound drawer image retention and reject late deliveries`。

### T9：缓存图库几何，让投递成本取决于可见窗口（#5）

**Files**

- 修改 `GalleryGridView.swift`、`GalleryLayout.swift`。
- 新增 `PicViewMacTests/GalleryPerformanceTests.swift`；扩展 `GalleryAuditTests.swift`、`GalleryReflowStabilityTests.swift`。

**Interfaces**

- 几何 key：`itemsRevision / aspectsRevision / layoutKind / effectiveWidth / thumbnailSize`；宽度使用与布局相同的有效宽度和一致的舍入规则。
- 维护缓存 `rows`、index→row、URL/identity→index，以及递增的 `geometryBuildCount` 测试计数。
- `GalleryLayout.visibleRows(in:of:)` 用有序 row 的 y 范围二分定位，再遍历可见区；复杂度目标 `O(log N + V)`，V 为窗口内项目数。
- `noteDelivered` 只更新目标可见 cell、版本化图片缓存和窗口内保留集合；不能因为像素到达增加 geometry revision。

**步骤**

- [ ] 编写 R05-01～R05-04；先断言纯投递不重建几何、可见查询不遍历所有 rows，再做耗时测量。
- [ ] 运行 `swift test --filter 'GalleryPerformanceTests|GalleryAuditTests'`，确认旧实现工作量随总数增长。
- [ ] 统一 layout、窗口计算、滚动定位复用同一几何缓存，避免不同宽度来源构造两套 rows。
- [ ] 集中定义失效：列表插删/重排、实际 aspect 变化、布局模式/宽度/尺寸改变；普通选择、同内容快照和缩略图投递不失效。
- [ ] 对相同回流事件合并无意义的重复 layout；无需以全表比较来判断每次是否变化，revision 由数据变更入口维护。
- [ ] 以第 8 节协议运行 Debug 结构测试和 Release 性能测试，记录优化前后分布，确认没有新增每次投递全目录 map/filter/stat。
- [ ] 运行 `swift test --filter 'GalleryPerformanceTests|GalleryAuditTests|GalleryReflowStabilityTests|ThumbnailMemoryAuditTests|FolderBrowserSliderTests'`。
- [ ] 仅提交本任务改动，建议主题 `perf: cache gallery geometry and bound delivery work`。

### T10：全量回归、超时复核与交付记录

**Files**

- 按证据扩展 `PicViewMacTests/Fixtures.swift` 与需要清理生命周期的具体测试；不先假定 `TilePlanAndRedrawTests.swift` 有 bug。
- 新增 `docs/release/2026-09-27-browser-correctness-verification.md`。
- 只有打包验证发现问题时才修改现有 release scripts。

**步骤**

- [ ] 完成所有针对性测试后，冻结代码 revision，记录工作区差异；停止其他测试进程，不与性能测量并发。
- [ ] 运行全量 Debug 测试并保存退出码和完整日志；全量失败不允许只跑过滤集后宣称全量通过。
- [ ] 对此前线程池问题，在冻结版本上执行一次正常全量；本轮若需关闭该疑点，再做两次独立进程全量复核，避免无目的不断重跑。
- [ ] 若再次卡住，在终止前保存测试进度、进程 sample、线程数、未完成 expectation、窗口/动画状态；只终止本次创建的进程。失败归属实际类与用例名。
- [ ] 用 `TilePlanAndRedrawTests` 独立运行和同进程可疑前置测试组合区分隔离问题、线程/动画泄漏、测试等待方式和产品逻辑；没有证据不大规模禁用动画或提高超时。
- [ ] 执行 Release 基准、M01～M12 人工流程及必要平台检查，记录通过/失败/未执行。
- [ ] 构建 app 和 DMG，执行真实产物验证；缺少 DMG、Metal 编译工具或最低系统实机时将相应项标为未执行，不把脚本退出 0 等同全部发布条件满足。
- [ ] 整理每个问题对应提交、测试名称、日志与人工验收结果；声明已知限制、尚未验证环境及缓存预算调节依据。
- [ ] 仅提交报告及确有必要的测试清理，建议主题 `test: document browser correctness and release verification`。

## 6. 永久回归测试矩阵

### 6.1 会话一致性与页面状态

| ID / 建议测试名 | 设置与操作 | 必须断言 |
|---|---|---|
| R07-01 `testInsertionKeepsRenderedIdentityAndOpenTargetAligned` | grid 原为 b,c；发布 a,b,c；触发显示 b 的 cell 双击 | grid 顺序等于 snapshot；打开 b 的身份与像素，不是旧下标 0 对应的 a |
| R07-02 `testAllSortEntrypointsPublishTheSameGalleryOrder` | 工具栏与菜单/快捷键分别切升降序，包含非当前项插入 | grid、session、导航前后项、位置读数一致；当前身份保持 |
| R07-03 `testStaleInteractionCannotOpenReplacementAtOldIndex` | 捕获 b 的交互，删除 b 或换目录后再送达 | 不打开该旧 slot 的新文件；无越界；空列表无当前项 |
| R07-04 `testMetadataSnapshotUpdatesGeometryWithoutReopeningFile` | 相同 ids 回填新 pixelSize；FolderItem equality 仍相同 | metadata 确实被消费；解码次数不增加；隐藏图库不发起缩略图工作 |
| R09-01 `testBrowserRoundTripPreservesSecondTIFFPage` | 用两页颜色/尺寸可区分的 TIFF，显示第 2 页，进图库并释放尺寸结果，再返回 | pageIndex=1；实际显示第 2 页像素；没有第 1 页解码请求 |
| R09-02 `testRepeatedNotificationsDoNotRestartInflightImage` | 首帧被闸门阻塞时连续发布 metadata/sort | 同一 source/page 的有效主图请求只有 1 次；最终正确完成 |
| R09-03 `testPassiveRefreshPreservesViewportAndPlaybackIntent` | 合法宽图设置 zoom/center；动画分别暂停、播放，模式往返 | 视口按几何精度保持；暂停不自启动；无重复 animation clock。播放可暂停于隐藏阶段，返回恢复意图，不要求任意耗时后帧号完全相同 |
| R09-04 `testChangedVersionReloadsAndClampsPageToNewCount` | 同路径 3 页 TIFF 当前第 3 页，替换为 2 页后 rescan | 新像素；页码夹为 1；描述信息更新；失败替换展示当前版本错误，不展示旧图为新图 |

### 6.2 异步目录与版本竞态

| ID / 建议测试名 | 可控完成顺序 | 必须断言 |
|---|---|---|
| R03-01 `testLatestNavigationWinsOutOfOrderScans` | 请求 A，再 B；B 完成后 A 完成 | directory/items/current 全为 B；晚 A 不增加 snapshot revision |
| R03-02 `testSameFolderNewerRescanWins` | A1 的旧列表挂起；A2 带新增文件先返回，再完成 A1 | 新文件保留，旧列表不覆盖；selection 合法 |
| R03-03 `testABARejectsFirstVisitCompletion` | A1→B→A2，依次完成 A2、A1、B | 只保留 A2；只比较目录 URL 的实现必须失败 |
| R03-04 `testSortAndScanDoNotPublishAnObsoleteSnapshot` | 尺寸排序挂起；watcher 增删文件并切回文件名排序；最后完成旧排序 | 保留新成员和当前排序；不丢文件、不回退排序 |
| R03-05 `testClosedViewerRejectsLateScanAndWatcherEvent` | 关闭后释放扫描，另发送已停止 watcher 的回调 | 无新发布、无新扫描、无 UI 访问、无窗口复活 |
| R03-06 `testFailedNavigationKeepsAnAtomicPreviousSnapshot` | A 成功；B 扫描失败或无权限 | 仍为完整 A，展示 B 的失败提示；加载态结束；首次失败无伪造列表 |
| R02-01 `testSamePathReplacementInvalidatesHeadAndDimensions` | 64×48 红图变成 8192×256 蓝图，再换 32×24；逐次 show/probe | 内容、尺寸、版本全更新；暖命中只限同一版本 |
| R02-02 `testOldDecodeCannotBePublishedAsNewVersion` | v1 读出后阻塞，替换 v2、发新请求；晚交付 v1 | v1 不覆盖 v2、不进入 v2 key；UI envelope 标识不变 |
| R02-03 `testProbeInflightIsSeparatedByVersion` | v1 header 读取挂起，v2 请求先完成，再放行 v1 | v2 调用者拿到 v2；旧完成不清掉新任务/缓存 |
| R02-04 `testGenerationIsCheckedAfterProbeAndBeforeCacheHit` | A 的 probe await 挂起；B 缓存命中完成；再释放 A | currentKey/current image 仍是 B；A 不触发 late cache-hit publication |
| R02-05 `testQueuedUICompletionCannotResurrectOldFrameOrThumbnail` | envelope 排入主线程前发生替换/换页/清空；再交付 | head/frame/failure/thumbnail 全部按来源拒绝；无旧图闪回 |
| R02-06 `testVersionIdentitySurvivesAtomicReplaceAndPreservedMtime` | 临时文件原子替换、同尺寸保留 mtime、删除重建、软链接改指向 | 使用既有 inode/ctime 等身份识别变化；页码/level/frame key 仍相互隔离 |

### 6.3 尺寸探测与排序

| ID / 建议测试名 | 设置与操作 | 必须断言 |
|---|---|---|
| R01-01 `testCorruptVersionIsProbedOnceWithoutRepublishLoop` | 一张坏图，多次 reload；可控探测返回 unreadable | 每版本读取 1 次；failure 后无自发任务；无 metadata 列表发布 |
| R01-02 `testMixedFolderPublishesOnlyActualDimensionChanges` | 一好一坏，单批完成后连续刷新 | 各读 1 次；只发布一次实际尺寸变化；已知尺寸不重读 |
| R01-03 `testRepairedFileAtSamePathCanBeProbedAgain` | 坏图失败后原子替换正常图，不离开目录 | 新版本读 1 次并回填；旧负缓存不阻断；纯排序不重试旧版本 |
| R01-04 `testLateDimensionBatchCannotUpdateNewVisitOrClosedBrowser` | A 批次挂起，离开/关闭或 A→B→A 后释放 | 旧批次不更新当前 metadata、不建新 UI；批次任务可释放 |
| R01-05 `testProbeDemandAndConcurrencyAreBounded` | 普通网格文件名排序；再切自适应或尺寸排序；中途取消 | 无需求时 0 次 header；峰值≤4；相同版本合并；取消后未开始工作不执行 |
| R08-01 `testDimensionSortReordersWhenPendingSizesArrive` | a-big=120000 像素，z-small=1200，先选升序后回填 | z-small 在 a-big 前；当前文件身份保持 |
| R08-02 `testDelayedDimensionsRespectLatestSortPreference` | 探测中先改降序，再改文件名排序，最后完成 | 采用最终设置；工具栏/菜单两入口一致 |
| R08-03 `testUnknownAndEqualDimensionsHaveStableOrder` | 已知小/大、两个失败、两个同面积；升降序与重复刷新 | 失败均末尾；同面积与失败组自然名稳定；不会随机抖动 |
| R08-04 `testBatchMetadataMergeDoesNotRestoreDeletedOrOldVersionItems` | 批次中删除一项、替换一项、插入一项 | 不复活删除项、不把旧尺寸给替换项；新项下一批获得结果 |

### 6.4 目录树、可见选择与命令路由

| ID / 建议测试名 | 设置与操作 | 必须断言 |
|---|---|---|
| R06-01 `testOutlineRendersHierarchyOnceAndEveryRowNavigates` | A 下 B、C，root 展开，有上一级 | 实际行恰为 [上一级,A,B,C]；每个真实文件夹行选中后打开相应路径 |
| R06-02 `testCachedChildrenReexpandUpdatesModelAndView` | 展开→折叠→再次展开已缓存 children | 第二次不枚举；模型/实际行同步；子项仍可点击 |
| R06-03 `testChildNavigationKeepsRootAndSortKeepsExpansions` | A 下展开 B 及其后代，进入 B，分别两入口排序和尺寸回填 | root=A；兄弟可见；手动折叠状态不会被刷新改回 |
| R06-04 `testUpAndDeepRevealPreserveExistingSubtree` | 从多层子目录逐级上移，再从根上移；直接定位未加载深层后代 | 上一级目标正确；向上扩根保留旧展开；只枚举目标链所需层级 |
| R06-05 `testTreeContainmentHandlesPrefixesAndSymlinkCycles` | /a/b 与 /a/bc，软链接回祖先或指向外部，根 / | 不误认前缀；无无限展开；上一级动作身份与 folder 项不同 |
| R06-06 `testSlowOrFailedEnumerationDoesNotBlockOrResurrectTree` | provider 异步挂起/抛错，期间用户操作或换 root | 主线程可处理另一事件；失败可重试；旧 children 不灌入新树 |
| R10-01 `testExplicitNavigationRevealsFirstLastAndOffscreenItems` | 200 项，从 0 跳 199，再回 0；两布局与不同缩略图大小 | 目标 frame 与 viewport 相交且 cell 已物化；不只验证 currentIndex |
| R10-02 `testPassiveRefreshDoesNotPullScrollBackToSelection` | 选 0，手动滚到中部；回填尺寸、投递缩略图、同步同一选择 | scroll anchor 不变，误差≤1 pt；不会回到 0 |
| R10-03 `testReflowKeepsAnchorWhenSelectionIsOffscreen` | 选中项不在屏幕，拖滑块、收起树、resize | 顶部锚点及相对偏移保持；不回拉选中项；缓存无反复清空 |
| R10-04 `testDeleteAndEmptyStateUseValidScrollGeometry` | 删除当前末项、删除可见锚点、清空再填充 | 按策略选择后继；无越界/NaN/负 content size；空态合法 |
| R11-01 `testSidebarButtonAndCommandAreEquivalentInBothModes` | image/browser × 开/关 | 同样改变当前可见左栏，另一模式状态保持 |
| R11-02 `testModeRoundTripRestoresEachSidebarPreference` | image drawer 开；browser tree 关；来回切换 | 两状态独立，图像几何符合 pinned drawer 原约定 |
| R11-03 `testMenuStateMatchesActiveSidebar` | 切模式后读菜单/action 状态并执行 | 勾选、文案/提示、可用性和真实操作一致；实际按键另做 M07 |

### 6.5 内存与布局性能

| ID / 建议测试名 | 设置与操作 | 必须断言 |
|---|---|---|
| R04-01 `testDrawerCacheHonorsByteAndCountBudgets` | 注入 2 MiB/8 项；不同大小、带行对齐的 CGImage 循环插入 | 每次存入后 bytes≤预算且 count≤8；使用 bytesPerRow×height；超预算单张不入 cache |
| R04-02 `testScrollingRetainsOnlyBoundedWindowAndInflightWork` | 200/1000 个逻辑项目，滚动头中尾及返回 | 缓存/队列有界，不随经过项线性增长；可见图正确；峰值解码≤4 |
| R04-03 `testCloseEmptyAndLateCompletionReleaseDrawerReferences` | 关闭抽屉/切目录/清空 session 后释放所有旧请求 | UI cache=0，旧完成不能增回；cell/reuse pool 不留旧 image |
| R04-04 `testCacheBudgetDoesNotBreakOversizedPlaceholderPolicy` | 当前超大图已有 proxy，邻图超大，滚动 | 当前图复用 proxy；邻图不触发全图解码；占位可正常导航 |
| R04-05 `testMemoryPressureDropsNonessentialThumbnailReferences` | 模拟内存压力后重开抽屉 | 按既有内存压力机制释放；可见项可恢复；身份和当前主图不变 |
| R05-01 `testThumbnailDeliveriesDoNotRebuildGeometry` | 布局稳定后向窗口反复投递 1000 次 | geometryBuildCount 增量=0；纯投递的全列表扫描计数=0 |
| R05-02 `testEachGeometryInputInvalidatesOnce` | 分别改变宽度、布局、缩略图大小、items 顺序、aspect | 一轮合并布局后各增加 1 次；同值重复设置不增加；frames 正确 |
| R05-03 `testVisibleLookupWorkIsIndependentOfFolderSize` | 同视口分别 1k/10k/50k 项，查询中部窗口 | 返回与慢参考算法一致；检查次数符合二分+可见范围，无全 rows 过滤 |
| R05-04 `testReleaseDeliveryAndReflowMetrics` | 执行第 8 节基准 | 输出原始样本、p50/p95/max 与计数；符合结构门槛并给出同机前后比较 |

## 7. 测试实现方法与数据管理

### 7.1 分层，避免测试只证明自己

1. **纯逻辑测试**：session 选择策略、sort、版本 key、request gate、预算、可见区索引；速度快，精确断言。
2. **控制器集成测试**：真实 Viewer/Browser + 可控 scanner/decoder/header provider；测事件次数、状态和 MainActor 投递。
3. **AppKit 结构测试**：真实 NSOutlineView、NSScrollView、可见 cell、布局与复用，不能用模型里的“visibleCount”替代实际行。
4. **真实文件测试**：少量 PNG/TIFF/GIF、真实替换、watcher 增删改；验证系统 API 与注入替身一致。
5. **人工/产物测试**：激活窗口中的真实点击、键盘、菜单、焦点、Finder 打开及打包版本。

所有新回归测试必须有能在旧行为上失败的观察点。只断言取消标记、私有变量值、测试专用计数而不观察最终输出，不足以证明竞态解决。

### 7.2 可控异步与超时

- 使用 actor/continuation 驱动的请求闸门，显式等待“请求已注册”，再释放指定 requestID。
- await 等待时让出执行器；不能在 MainActor 上通过 semaphore.wait 或阻塞 sleep 等待 MainActor 自己完成。
- continuation 在成功、取消和测试失败清理中均只 resume 一次；teardown 释放全部悬挂请求。
- 单个可控状态测试建议 2 秒失败上限，真实 ImageIO/watcher 集成建议 10 秒；上限是失败保护，不是制造顺序的办法。
- 真实 watcher 只断言最终稳定状态及有界扫描次数，不要求底层恰好发一个系统事件。
- 测试坏图循环时优先断言任务队列归零、读取次数固定。可另加 1.2 秒真实时间 smoke test 对照历史现象，但它不能是唯一证据。
- 对 source superseded、请求失效、失败负缓存至少记录测试可读取的计数；生产日志默认不逐文件刷屏。

### 7.3 Fixtures

- 复用 `Fixtures.makeScratchDirectory`，每个测试独立路径；不能改仓库自带 fixture。
- 生成红/蓝等可区分的小图片，检验像素用固定色块内部采样，避免压缩边缘与色彩转换带来的误差。
- 生成或确认 multipage TIFF 的每页不同；必须从公开显示状态或实际渲染图确认页像素。
- 8192×256 之类的宽图用于比例和版本回归；50k 布局测试使用内存 FolderItem，不创建 50k 张真实大图。
- 真实大量目录扫描基准单独 opt-in，日常回归用可控 scanner。权限失败用抛错 provider 保证可复现，真实无权限目录只作为补充。
- 同路径版本测试至少有原子 replace 和原地重写两类；时间戳相同的场景显式控制 mtime，不靠快速连续写碰时间分辨率。

### 7.4 AppKit 与全局状态清理

- 复用 `TestAppKit.ensureApplication` / `presentOffScreen` 进行结构测试。
- 每个测试关闭窗口，停止 watcher、动画和 Task，移除通知 observer，释放 delegate/closure 引用，清理临时文件。
- 修改全局排序时使用 `SharedSettingsScope.preservingSort`；修改其他设置也要恢复。不能依赖用例排序或前一个测试创建 NSApp。
- 真实按键、first responder、key window、鼠标 double-click 使用激活可见窗口单独验收。离屏窗口直接调用 callback 不能冒充操作系统事件分发测试。
- AppKit 用例默认按现有串行方式运行；独立纯逻辑测试可并行，先验证共享设置隔离，不对整个 suite 直接打开并行。

## 8. 性能、资源与体验验收

### 8.1 Release 布局与投递基准

固定同一台机器、系统、SDK、提交、显示缩放和窗口条件，记录调试器是否附加。测试视口建议 1024×768 pt，缩略图 160 pt，同时覆盖两种布局及 1k/10k/50k 项。

分开测量：

- 首次几何构建（允许随 N 增长）。
- 热几何下窗口内 thumbnail delivery（不允许随 N 全表增长）。
- 连续滚动可见查询与 cell 复用。
- 缩略图滑块连续变化、停止后的补图。
- 窗口 resize / 左栏折叠后的几何重算。

每组先预热，至少 5 轮、每轮 1000 次热投递；报告原始样本文件、p50、p95、最大值、geometryBuildCount、扫描行数、物化 cell 数、缩略图请求数。冷首次构建不能混进热投递统计。

**硬门槛：**

- 1000 次纯 thumbnail delivery 不增加 geometryBuildCount。
- 热投递不遍历整个 items/aspects/rows，也不对整目录 stat。
- 可见查询与物化数量取决于视口；50k 项不能实例化 50k 个视图。
- 滑块拖动不触发源分辨率解码；结束后允许一次合并后的清晰度请求。
- 明确记录缓存 miss 与真实工作量，避免通过未布局、空视口或取消全部请求获得虚假的快。

**建议体验目标，需同机测量确认：**

- 50k 项的热投递 p95 控制在 2 ms 内，且明显低于旧基线；该数值是目标，不能作为不同 CI 硬件统一的脆弱单测阈值。
- 完整滚动/交互的主线程关键路径尽量小于 60 Hz 的 16.7 ms 帧预算；120 Hz 设备另看 8.3 ms，不用“单个函数变快”代替真实滚动体验。
- 首次布局仍若超预算，再基于测量评估增量几何或后台预计算，不在本轮预先增加复杂度。

### 8.2 内存稳定性

先用注入预算做确定性缓存测试，再做 Release 真窗口场景：

1. 分别打开 200、1000 个普通图片的目录，抽屉从头滚到尾再返回，重复 3 轮。
2. 记录 UI cache bytes/count、可见及复用 cell 的位图引用、pipeline retained bytes、在途工作数和进程 footprint。
3. 关闭抽屉、切换图库、清空目录、关闭窗口；等待自己创建的工作全部结束，再取样。
4. 重开重复同一流程，观察是否随轮数持续增加，而非只看某个瞬间 RSS。
5. 对 16-bit/有行对齐图片检验计费，对超大图检验占位/代理路径。

**通过标准：** UI cache 始终服从注入/生产预算；关闭或清空后的 UI 专属引用归零；进行中任务与队列有上限；进程内存经过暖机进入平台区间，不因反复遍历线性增长。系统分配器可能保留页，因此不要求 RSS 在 close 后立即回到启动值，也不以该现象直接判断泄漏。

24 MiB/128 项/4 并发是初始建议，报告中记录调节原因。如果共享管线已有更严格限制，采用更严格者；不得把每层预算简单相加当作真实唯一图片占用。

### 8.3 人工测试清单

| 编号 | 操作 | 验收 |
|---|---|---|
| M01 | A 有 B/C，B 有 D；进入 B/D，折叠展开，点击所有可见行 | 根稳定、无重复/死行、高亮和内容一致 |
| M02 | 根内上一级、跨根上一级、从 Finder 打开外部目录；切两种排序入口 | 父目录语义正确，外部重置正确，排序不折叠 |
| M03 | 快速交替多个目录，夹杂空目录、不可读目录和慢目录 | 不出现标题为 B 但内容为 A；失败可恢复 |
| M04 | Finder 在当前目录新增/重命名/删除；随后双击、Return、前后导航 | 可见项目和打开目标一致；删除偏好不变 |
| M05 | TIFF 第 2 页以非默认合法缩放进入图库，等缩略图完成，再返回 | 页码、像素和视口正确；动画暂停状态另测 |
| M06 | 同路径用不同尺寸/颜色覆盖当前图和非当前图，含原子保存 | 主图、尺寸、抽屉、图库最终一致，无旧像素回闪 |
| M07 | 两种模式下分别点击左栏按钮、菜单和按 ⌘⇧T | 操作当前左栏；切模式保留独立状态 |
| M08 | 选首图滚到中部，等待元数据；再按最后一张；拖滑块及 resize | 被动刷新不抢位置；主动导航可见；无白闪/跳回 |
| M09 | 大目录快速滚动及反复开关抽屉/图库，Activity Monitor 观察 | 无持续 CPU/IO 空转，无内存随遍历累计增长 |
| M10 | 放入 corrupt/truncated 文件，再把坏图修复 | 有错误状态、可继续导航，新版本能重试，旧失败不自循环 |
| M11 | 最低支持系统与当前 SDK 对应系统；浅/深色、Retina、全屏和分屏 | 无布局越界、可用性崩溃或原生控件回归；没有设备则标未执行 |
| M12 | 多窗口分别浏览/排序/关闭；真实焦点下键盘导航 | 活动窗口收到动作；共享排序按既有设计一致，各窗口 current 不串台 |

M12 是探索性验收；若发现新增缺陷，记录复现与独立范围，不在报告中倒推为早已确认的问题。

## 9. 执行命令与结果记录

以下命令供实施者使用；本方案编写阶段并未执行它们。每个任务先执行对应过滤集，最后统一全量。代码有变化时不要使用旧构建的 `--skip-build` 输出作为新代码证据。

### 9.1 环境与针对性回归

```bash
git rev-parse HEAD
git status --short
swift --version
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
sw_vers
swift test --filter 'FolderSnapshotRegressionTests|FolderRequestRaceTests|SourceReplacementRegressionTests|DimensionProbeLifecycleTests'
swift test --filter 'FolderTreeInteractionTests|GallerySelectionVisibilityTests|DrawerThumbnailRetentionTests'
swift test --filter 'FolderBrowserModeTests|GalleryReflowStabilityTests|FolderBrowserSliderTests'
```

新测试类须先由相应任务创建。过滤测试输出必须含实际执行数量，不能把“匹配到 0 个测试”的 exit 0 当通过。

### 9.2 全量与稳定性

在 bash 或 zsh 中：

```bash
mkdir -p /tmp/piclight-browser-verification
set -o pipefail
swift test 2>&1 | tee /tmp/piclight-browser-verification/swift-test.log
```

需要关闭间歇超时疑点时，固定同一 revision，再运行两次，分别保存 `swift-test-2.log`、`swift-test-3.log`，每次记录 exit code 和用例数。若代码发生变化，重新标记版本，不混用结果。

定位时：

```bash
swift test --filter TilePlanAndRedrawTests
swift test --filter 'TilePlanAndRedrawTests|ToolDockIdempotentAnimationTests|AnimationLifecycleTests'
swift test --filter 'MetalParityTests|MetalFallbackTests|NativeInFlightReplacementTests'
```

第二行只是用于检查同进程相互影响的起点，不保证 SwiftPM 按所写顺序执行；需要特定顺序时使用明确的复现 harness。不要靠提高 30 秒超时掩盖线程阻塞。

### 9.3 Release 与打包

```bash
swift test -c release --filter GalleryPerformanceTests
scripts/build-release.sh
scripts/make-dmg.sh
scripts/verify-release.sh PicViewMacTests/Fixtures/static.png
```

打包脚本会重建 `dist/PicLight.app`，应在隔离执行目录使用。若 dist 有多个历史 DMG，给 `DMG` 环境变量指定本次产物的准确绝对路径再验证，不能验证到旧文件。

发布验证必须确认：macOS minimum 14.0、构建 SDK 标记至少 26、编译后的 metallib、签名、系统依赖、DMG 内容与挂载后的 acceptance runner。不得用 `PICLIGHT_ALLOW_SOURCE_SHADER=1` 的开发回退当作正式 Metal 产物通过。

### 9.4 报告模板

每轮在验证报告记录：

| 字段 | 内容 |
|---|---|
| Revision | commit SHA；若有未提交改动，附 diff 记录 |
| Environment | macOS、硬件、Swift、Xcode、SDK、scale、Debug/Release |
| Test command | 完整命令、开始/结束时间、exit code |
| Coverage | 实际用例数、通过/失败/跳过；问题编号→测试名 |
| Baseline failure | 旧版本可重复失败的观察值及日志 |
| Fixed result | 新版本通过值、最终像素/身份/事件数 |
| Performance | 原始样本、分位数、工作计数、峰值与稳态内存 |
| Manual | M01～M12 各自通过/失败/未执行及理由 |
| Limitations | 未运行平台、未稳定复现问题、文件快照保证边界 |
| Artifacts | 日志、sample、必要截图、app/DMG 对应 revision |

测试数量以实际结果为准，不把历史 810 作为本轮必须相等的数字；新增永久测试后数量应合理变化。

## 10. 完成标准、风险与回退

### 10.1 可以称为“修复完成”的条件

- [ ] 11 项问题都有永久自动化测试；第 6/11 项还有真实 AppKit/按键验证。
- [ ] P0 复现均无法在修复版本重现，且不是通过隐藏错误、空列表或取消所有请求规避。
- [ ] 目录、grid、selection、打开目标和实际像素一致；同路径版本替换和迟到回调有明确覆盖。
- [ ] 树和滚动符合第 3 节约定，旧规格/测试的冲突已同步说明。
- [ ] 现有删除偏好、页码、动画、viewport、超大图、Metal 和滑块回流的相关回归通过。
- [ ] 针对性测试与一轮完整全量通过，所有失败和未执行项公开记录；间歇测试问题未确认解决时单独保留。
- [ ] 缓存硬上限与布局工作量通过结构性测试，Release 基准有同机前后对照。
- [ ] 本轮发布前的人工与产物检查有记录；无法执行的平台不标为通过。
- [ ] 每个提交边界清楚，不夹带别人的未审阅草稿；最终 git diff 与报告对应。

### 10.2 主要回归风险

| 风险 | 防范方式 |
|---|---|
| 抑制 onCurrentChanged 后真正换图不加载 | 同身份新版本、首帧进行中、失败重试、空态单独测试 |
| 全部 onItemsChanged 都 reload 导致额外探测/闪烁 | 单一快照订阅、reason 分类、实际变化判断 |
| 全局 generation 互相取消无关工作 | 目录 epoch、扫描 sequence、排序 revision 与图像 generation 分职责 |
| 为保持页码错误复用旧图 | 显示请求必须含版本和页码；旧 envelope 绝不重新贴标签 |
| 修滚入可见破坏自由滚动 | 主动 reveal 与被动 preserve 的双向反例测试 |
| 目录树 value identity 随 children 改变 | 稳定引用/身份 wrapper，真实 outline 操作测试 |
| 缓存降低后滚动出现反复解码 | 窗口预取、管线复用、计数与体验同时测量 |
| 只优化 rows 仍有 O(N) 热路径 | 检查 visibleRows、URL 查找、map/filter/stat 的实际访问计数 |

### 10.3 回退策略

- 每个任务独立提交，后续任务依赖关系见第 5 节。回退共享契约时连同消费者一起回退，避免接口半迁移。
- T9 性能优化若引入几何错误，可以独立回退，同时保留 T1–T8 正确性。
- T8 的预算值可在保持硬上限的前提下调整；不能回退到无界字典作为长期解决。
- T5 稳定根属于行为变化，出现交互争议时可以单独调整根策略，但层级去重和身份点击修复必须保留。
- 不通过禁用 watcher、取消所有缩略图、忽略失败测试、永久放大超时或吞掉错误实现“通过”。

## 11. 计划自审结果

- 覆盖：原报告 1–11 均映射到任务和测试；间歇全量超时单独处理，没有当作已确认产品缺陷。
- 边界：明确区分 FileIdentity 的选择身份与 SourceFileIdentity 的内容版本；已有 FolderItem equality 不能替代 metadata diff。
- 接口：T1 提供快照，T2 提供目录请求标记，T3 提供文件版本上下文；T4/T8 复用这些接口，T6/T9 共享几何与视口约定。
- 行为冲突：旧第 9.4 节根策略、尺寸失败值位置和被动刷新滚动策略均已明示，没有暗中改变产品语义。
- 证据：报告数值作为历史观察；新增测试与 Release 指标待执行；本次文档没有将未执行的验证标为通过。
