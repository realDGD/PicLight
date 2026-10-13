# Agent note：文件夹访问记录与恢复

Status: implemented

日期：2026-10-13。范围为本地功能清单 3.5.1 的 B 批文件夹功能；基线 `7661068`，当前分支 `feat/viewer-ux-redesign`，交付包为 0.1.0 / Build 4。入口和用户行为以[文件夹访问说明](../../../docs/folder-access.md)为主要说明位置。

## 决定与理由

[FolderAccessStore](../../../PicViewMac/Folder/FolderAccessStore.swift)使用版本化书签快照保存目录，实际解析和读取结果决定状态。当前独立应用没有 App Sandbox，保存普通书签；实际沙盒运行环境才创建安全作用域书签。不能把“有路径”“有书签”写成系统授权已生效，也不能因 `startAccessingSecurityScopedResource()` 返回 false 就跳过实际读取检查。

安全作用域访问只在开始成功时结束。记录持有其 Scope，扫描保留操作引用；移除记录释放 store 的引用，已经开始的扫描结束后释放自己的引用。恢复、重新选择和删除使用代际，迟到的读取结果不能重新加入已移除记录。书签过期时刷新，目录移动时更新路径；损坏的持久化数据在普通刷新时保留，等待用户明确添加记录修复。参考 [Apple 访问生命周期说明](https://developer.apple.com/documentation/Foundation/NSURL/startAccessingSecurityScopedResource%28%29)。

[ViewerViewController](../../../PicViewMac/Viewer/ViewerViewController.swift)统一处理文件打开、文件夹打开和监听重扫。父目录扫描失败仍尝试解码明确打开的文件；失败不写成空目录，也不依赖会被图片解码清掉的错误标签。看图和网格共用[恢复条](../../../PicViewMac/Viewer/FolderAccessBannerView.swift)，提示开关只控制自动权限引导。

恢复重试保留原来的文件选择；选中上级目录后同步已恢复的子目录记录状态。目录切换和窗口关闭会使旧结果失效；失败期间停止监听，避免持续失败反复弹窗。手动选择只接受原目录或其上级，位置不可用时可明确改到另一位置。记录重新选择到新位置时，已打开窗口按相对目录和原文件名恢复。

[管理窗口](../../../PicViewMac/Settings/FolderAccessViewController.swift)独立于六个固定大小的设置页，保存选中记录的身份而非旧行号。移除后不自动选中另一条记录，避免用户误操作。移除不删除文件，也不撤销 macOS 完全磁盘访问；系统权限指南是独立说明入口。

## 取舍与边界

没有将应用改为沙盒发行，普通书签符合当前独立包的运行模式；只保存字符串路径无法处理目录移动，因此采用书签解析与真实读取检查。没有把管理列表塞进固定 560×560 的设置页，以保留其布局和可操作性。没有实现递归图片合并或自动重开上次目录。

沙盒后端的注入测试证明书签状态及 Scope 开始/结束配对；本次没有交付或实际运行沙盒应用，不能据此声称沙盒图片解码、TCC 受限目录或跨发行身份的完整访问链已验收。以后启用 App Sandbox 时还需验证解码与缩略图在记录移除时的访问生命周期。

## 本次证据

按用户要求先实现，再集中验证。日志保存在本地 `.superpowers/sdd/2026-10-13-folder-access/`，不作为未来版本的通过证据。

| 检查 | 实际结果 |
| --- | --- |
| 初次相关回归 | 96 项，1 个路径拼写断言失败；`/var` 与 `/private/var` 指向同一目标，修正比较方式。 |
| 相关回归重跑 | 97 项，零失败，包含 14 项新增文件夹检查。 |
| 最后状态同步复查 | `swift test --filter 'FolderAccess\|SettingsWindow'`，20 项，零失败；新增上级目录恢复子目录状态的检查，本批共 15 项文件夹检查。 |
| 最终应用包 | Build 4 构建退出 0；27 项包检查通过、零失败；DMG 未重建。 |
| 原生 Build 4 使用 | 添加/取消、三项网格、退出重启恢复、重新选择取消、目录改名后的错误与书签恢复、指南显示、移除保留文件。退出后个人偏好按字典恢复并确认一致。 |

回归使用的实际过滤器：

```sh
swift test --filter 'FolderAccess|AFeatureBehavior|FolderSession|FolderSwitchRace|FolderDynamics|SamePathReplacement|EmptyWindowOpen|SettingsWindow|FileAssociation|ViewerInputRouting|FolderBrowserMode'
swift test --filter 'FolderAccess|SettingsWindow'
```

未跑全量回归；没有修改真实完全磁盘访问或 TCC 权限。本次应用包的最终构建与检查记录见[实施计划](../../../docs/superpowers/plans/2026-10-13-folder-access.md)。

## 后续维护与交接

本次提交涵盖文件夹访问代码、15 项专项检查、用户说明、本记录与实施计划。参考截图和本地功能清单仍位于被忽略的 `new_feature/`；`dist/` 应用包、本地验证日志及个人偏好备份不纳入源码提交。

恢复任务先核对分支与工作区，再读拥有状态的 `FolderAccessStore` 和共用扫描入口 `readFolder`。新增权限行为时保持实际读取结果、明确打开目标和请求代际一致；新增沙盒发行模式时补齐完整解码与缩略图访问生命周期的原生验收。普通提交不重复运行已经通过且源码未变的 Swift 回归。
