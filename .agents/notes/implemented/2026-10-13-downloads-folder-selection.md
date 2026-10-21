# Agent note：用户文件夹前置授权与设置背景

Status: implemented

日期：2026-10-13。在 `feat/viewer-ux-redesign`、提交基线 `49bc39a` 的已有未提交设置改版上继续。用户要求 Downloads 使用文件夹授权面板并加入授权列表，同时修正看图分类及内容区与系统背景的色差。随后用户纠正：面板应默认打开用户文件夹，并要求用户授权用户文件夹。用户此前要求暂不测试，本次沿用：只编译与更新预览包，不进行回归或真实权限操作。

## 行为与实现

- [FolderAccessStore](../../../PicViewMac/Folder/FolderAccessStore.swift)用标准化路径判断 Downloads 及其下级位置是否已有有效覆盖记录。此判断不读取目录、不检查文件权限、不预先解析受限目录中的符号链接。已保存的书签按现有生命周期恢复。
- [ViewerViewController](../../../PicViewMac/Viewer/ViewerViewController.swift)在扫描、监听和发布新图片前执行前置检查。Downloads 缺少有效覆盖记录时，Store 返回当前用户文件夹（当前用户的主目录）作为授权目标。[原生目录面板](../../../PicViewMac/Settings/FolderAccessViewController.swift)默认打开该目录，标题“授权用户文件夹”，按钮“授权并继续”；确认后调用原有 Store 添加所选目录记录，由授权通知恢复仍然有效的打开请求。只选用户目录的下级目录不满足此次授权范围。
- 取消不保存记录，不继续读取 Downloads；保留手动恢复入口。关闭自动提示同样不会退回直接读取目录。选择结果晚到、切换目录或关闭窗口仍检查请求代次，不让旧结果替换当前浏览内容。
- 目录监听原来在 `beginFolderRequest` 就调用 `open(O_EVTONLY)`，早于权限恢复。现在先停止旧监听，在通过前置检查、持有访问 scope 后再监听与扫描。
- [FolderTreeModel](../../../PicViewMac/Gallery/FolderTreeModel.swift)及[文件夹浏览控制器](../../../PicViewMac/Gallery/FolderBrowserViewController.swift)使用同一判断，避免为了子目录标记而提前枚举 Downloads。点击未授权目录的展开入口转到文件夹授权流程；确认后继续浏览。
- [设置卡片与分类条](../../../PicViewMac/Settings/SettingsPaneScaffold.swift)去掉分别混出的不透明中性灰。卡片继承窗口实际背景，分类条和选中区只叠加轻量提示，避免与系统桌面着色形成大片色差。原有固定位置、静态边框和按钮输入保留。

## 范围与当前证据

这一前置策略针对当前用户的 Downloads 需求，不声称覆盖所有受 macOS 保护的位置。真实读取失败、失效书签和完全磁盘访问仍沿用原来的恢复与系统权限边界。没有修改 TCC 数据、真实默认应用或现有授权记录。

`swift build` 已执行，退出 0；日志为 `.superpowers/sdd/2026-10-13-downloads-panel/build.log`。这是编译证据，不是新流程的权限验收。未运行 XCTest、未访问真实 Downloads、未点击原生面板授权、未检查亮暗模式或桌面着色的实际显示效果。旧设置改版的 12/31 项检查不作为本次权限改动的回归证据。

本轮修改前的 8 个输入文件及 SHA256 保存在 `.superpowers/sdd/2026-10-13-downloads-panel/before/` 与 `manifest.json`，保留此前稳定版本的恢复依据。

当前交付包为 `dist/PicLight.app`，**0.1.0 / Build 14**，已包含用户文件夹目标修正。`BUILD_NUMBER=14 bash scripts/build-release.sh` 已执行，退出 0；Release 编译耗时 14.38 秒，Metal、图标编译与脚本内 ad-hoc 签名检查完成。日志为 `.superpowers/sdd/2026-10-13-user-folder-selection/release-build-14.log`。未运行 XCTest、原生权限流程或独立应用包检查，未启动新包，未更改真实授权或已安装应用。

原 Downloads 目标版本为 **0.1.0 / Build 13**。`BUILD_NUMBER=13 bash scripts/build-release.sh` 已执行，退出 0；日志 `release-build-13.log`。两轮均未执行 DMG 检查，`dist/` 中的旧 DMG 不属于本轮新产物。

打包前发现旧 `dist/PicLight.app` 已不在该位置；只读检查安装目录显示 **Build 12**。本轮没有覆盖 `/Applications/PicLight.app`，没有启动新包验证权限或背景，也没有提交、推送。

用户文件夹目标修正前的 5 个源码/文档输入、SHA256 和原 Build 13 应用包保存在 `.superpowers/sdd/2026-10-13-user-folder-selection/`。前一段关于安装目录的读取属于 Build 13 阶段证据，本次没有重新检查或更改已安装应用。
