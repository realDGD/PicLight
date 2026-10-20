# Agent Note：有界动画播放与 main 接入

Status: implemented

## 问题

旧查看器用 30 Hz Timer 推进帧索引，每次单独开 ImageIO 源解码。错过目标帧后等待精确帧会扩大画面停留，完整解码缓存又会随动画尺寸和帧数增长。APNG 的独立封面也不能作为动画第零帧。

## 决定

- 以文件有效帧时长和循环信息建立单调时间轴。缺帧不移动起播时间、不提前显示未来帧；优先显示不晚于目标且比已显示帧新的最新就绪帧。暂停才冻结时钟。
- 后台单个串行 ImageIO 源顺序推进合成依赖，完成颜色处理、上传和 mip 生成。大动画采用三个复用槽；仅完整帧缓存不超过 8 MiB、256 帧且符合预算的小动画整段缓存。
- 帧租约覆盖当前画面和 GPU 使用期，GPU 完成后才能覆写槽。切图、同路径替换、空列表和窗口关闭停止生产并阻止旧请求发布。文件身份与缓存键包含文件版本。
- APNG 的独立封面首动画帧由 fcTL/fdAT 重建，保留偏移、透明画布、颜色属性和高位深。后续合成仍交给 ImageIO；扫描、原生面板和应用包声明包含 `.apng`。
- 无 Metal 或不支持的位深走有界 Quartz；普通播放不读回 GPU，显式帧复制可读回当前租约。
- Homebrew 维护 Cellar 中的应用本体，安装说明创建 `/Applications/PicLight.app` 到稳定 opt 路径的入口。不会建议用户 Applications 目录，不覆盖已存在的应用，也不在此次合并执行安装。

实现入口：[帧缓冲](../../../PicViewMac/Imaging/AnimationFrameBuffer.swift)、[时间轴](../../../PicViewMac/Imaging/AnimationTimeline.swift)、[APNG 首帧](../../../PicViewMac/Imaging/APNGFirstFrame.swift)、[查看器](../../../PicViewMac/Viewer/ViewerViewController.swift)。安装步骤见[安装指南](../../../docs/release/unsigned-installation.md)。

## 替代方案与代价

保留旧的定时器加逐帧解码不能解决源帧时间轴和重复解码；为所有大动画整段缓存会扩大内存。当前方案允许落后时跳过已经过期的上传，但仍推进需要的合成依赖。80 MiB 是可控纹理池与 staging 预算，ImageIO 工作位图、内部合成和系统资源另计，不能称为整个进程的内存上限。

## 合入范围

从已包含 CLT/Homebrew 的 main 单独移入动画代码及必要的文件身份、缓存和关闭清理依赖。没有复制功能分支的设置、目录权限、文件夹浏览器或其他界面改动；原工作区保留。

## 验证依据

本轮在单独从 main 创建的集成工作区运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --filter 'AnimationMainIntegrationTests|AnimationTimelineTests|AnimationFrameBufferTests|AnimatedFormatRegressionTests|AnimationConversionTests|AnimationLifecycleTests|SupportedImageTypesTests|DecodeCoordinatorTests|CacheIdentityTests|MetalFallbackTests.testSwitchFromMetalToSixteenBitHidesTheOldSurface'
```

选中 60 项，60 项通过、0 失败、0 跳过，测试执行 10.518 秒。包括 GIF/APNG/WebP 的时长与循环、独立像素预期、三槽租约和预算、有限循环和暂停、APNG 独立封面及子矩形/调色板/16 位、关闭释放、同路径替换、关闭旧帧流和 Metal→Quartz 隐藏旧表面。窗口生命周期测试创建但不显示窗口。

CLT 的 XCTest 尝试因缺少 XCTest 模块失败，保留失败记录后改用现有 Xcode 运行上述测试；没有修改 Xcode 或全局工具链选择。应用构建另在禁止读取 Xcode 和额外 Metal 编译工具链的外层沙箱中执行 Formula 的 `install`（内部为 `bash scripts/build-release.sh`），并将 `prefix` 重定向到临时目录。CLT Release 编译、应用打包和 Formula 的 8 个断言通过，未安装到真实 Cellar 或 Applications。

`bash scripts/make-dmg.sh` 成功。对实际应用包完成 15 组定向检查：严格签名、资源与 manifest 一致、APNG 类型声明、图标、系统动态库、最低系统版本、Metal 实际渲染与 mip、删除应用副本的 shader 源后仍可加载编译库、缓存库的动画 compute pipeline，以及只读挂载 DMG 的内容；原 Xcode 与旧应用的 11 个保护文件和全局工具链选择均未改变。安装链接命令在临时目录验证已有应用时失败并保留原目录。

没有运行全量测试，也没有显示窗口或抢占焦点。先前 Build 16 功能分支的实际窗口测量只作历史证据，不能当作本次 main 的新窗口成绩。其他 macOS/GPU 和本次 main 的真实屏幕流畅度仍需对应条件下验证。
