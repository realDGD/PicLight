# 预编译资源

日常 CLT 打包直接复用这些文件；更新命令集中在[安装与构建指南](../../docs/release/unsigned-installation.md)。

| 文件 | 输入 | 打包位置 |
| --- | --- | --- |
| `Assets.car` | `Resources/AppIcon/PicLight.icon/`；同时记录随包 `.icns` 的指纹 | `Contents/Resources/Assets.car` |
| `default.metallib` | `PicViewMac/Shaders/` | `Contents/Resources/PicViewMac_PicViewMac.bundle/Contents/Resources/default.metallib` |
| `manifest.json` | 源文件和产物 SHA-256、最低系统及编译参数、生成工具版本 | 只供构建校验 |

经典 `PicLight.icns` 已是预编译资源，继续存放在 `Resources/AppIcon/`，保留其完整 10 个尺寸。

当前 Metal 目标为 `air64-apple-macos14.0`，不按主程序的 arm64 / x86_64 架构分别缓存。图标按 macOS 平台、最低系统 14.0、名称 `PicLight` 编译。日常更换 Swift 工具链或 SDK 不会使缓存失效；资源输入、对应编译配方或目标配置变化才会失效。修改更新脚本的编译参数时，须同时递增对应的 `recipe`。

更新脚本先在临时目录完成所需编译，再一起替换缓存目录；编译失败保留原缓存，替换失败尝试恢复。编译期间源文件发生变化也会拒绝发布。打包时会在 Swift 编译前和编译后各检查一次，缺失、损坏或过期资源均会停止打包。脚本不自动调用资源更新、不下载工具链、不调整 `xcode-select`。

缓存随源码保存，不能只复制二进制文件或手工改指纹来绕过校验。哈希校验证明缓存与记录的输入一致，实际加载、签名和图标结构仍需对生成包分别检查；其他 macOS / GPU 的运行兼容性需要对应设备验证。
