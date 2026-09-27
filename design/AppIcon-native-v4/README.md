# PicLight · 原生图标 v4（独立审阅文件）

本版按最新反馈去掉浅色与深色的蓝色底板、额外雾化、手绘双层玻璃边框。保留手套、手电筒及黄色光束；图标蒙版和外缘高光由 Apple 渲染。

> **接入状态（2026-09-27 定稿）**：**v4 是最终采用的出厂图标。** 文档装在 `Resources/AppIcon/PicLight.icon/`，`scripts/build-release.sh` 用 `actool` 编译成 `Assets.car`，`Resources/AppIcon/build-icons.sh` 从同一份文档重打 10 档 `.icns`（与 `exports/PicLight-native.icns` 逐字节相同，`cmp` 通过），`scripts/verify-release.sh` 33 项检查全过（其中 10 项是图标）。中途曾按要求试装 v3（transparency），比对后切回 v4；v3 文档仍留在 `design/AppIcon-transparency-v3/`，切换命令见 `Resources/AppIcon/README.md`。
>
> 实测补充：v4 的静态导出（`preview/native/*.png`）与 v3 的三份文档在 `ictool --export-image` 下几乎一致——v3 的底板透明度（0.05/0.18/0.45）不参与扁平化（三份导出 SHA-256 完全相同），`specular`、`translucency`、`refractivity` 与玻璃层只在系统实时合成时生效。因此这两版的差别只能在桌面/Dock 上看，PNG 不能作为判据；同时系统设置 → 外观 →「图标与小组件样式」必须留在"默认"，否则图标不会跟随浅色/深色。

## 先看效果

- `preview/01-native-light-dark.png`：默认彩色与系统 Clear 的浅色、深色效果。
- `preview/02-macOS26-27.png`：相同文件分别由 26、27 两代渲染器导出。
- `preview/03-small-sizes.png`：256、128、64、32、16 像素的实际尺寸。

预览使用 Apple `ictool`，不是图像生成器绘制的玻璃效果。PNG 导出是静态结果，不能代替桌面背景实时合成的验收。

## 文件

| 文件 | 用途 |
| --- | --- |
| `PicLight.icon/` | macOS 26 / 27 原生 Icon Composer 文档 |
| `preview/native/*.png` | 两代、六种外观的 1024 × 1024 导出 |
| `exports/PicLight-native.icns` | 此版的静态 ICNS，10 个尺寸、16–1024 px |
| `exports/PicLight.iconset/` | 上述 ICNS 的 PNG 源文件 |
| `legacy-unchanged/PicLight.icns` | 旧版参考还原图标，逐字节保留上一版文件 |
| `legacy-unchanged/PicLight-reference.appiconset/` | 保留的旧版资产目录 |
| `verification/compiled/Assets.car` | Apple 资源编译结果，尚未放进应用 |

## 本次材质设置

- 默认浅色背景：中性近白 `R=G=B=0.985`。
- 默认深色背景：中性近黑 `R=G=B=0.065`。
- 没有自绘 `glass.svg`、背景图片、模糊滤镜或额外雾化叠层。
- 仅两个前景图层：手套/手电筒 PNG 和光束 SVG。前景的绘画颜色和比例保留。
- 前景未重复附加玻璃高光、透明材质或投影。外框由 Icon Composer 的系统渲染器生成。

## 系统设置与实际限制

用户期望：26 跟随系统设置；27 的背景比系统更实一档以保持可读性；25 及以下保持原样。

Apple 的 **图标外观** 与 **系统 Liquid Glass 透明度滑块** 是独立机制。此 `.icon` 支持系统选择 Default、Dark、Clear Light/Dark、Tinted Light/Dark。系统 Clear 是透明图标入口；默认彩色外观的背景仍按 Apple 的底板规则渲染，不能把近白色误称为真正透明。

Apple 在 WWDC26 的 Icon Composer 问答中明确说明：Clear 图标玻璃不响应系统透明度滑块。因此，仅靠 `.icon` 无法实现“26 跟随那个玻璃滑块”，也无法实现“27 自动比滑块高一档”。本包没有读取私有设置、模拟系统档位或伪称实现自动映射。

25 及以下的旧文件已保留。未来接入时，还需验证资源选择规则：Xcode 可从新 `.icon` 自动生成旧系统回退资源，不能假定随包附带旧 `.icns` 就一定优先显示旧图标。此次不修改应用，故尚未实施或验证按系统版本选择不同图标。

依据：

- [Apple WWDC26 · Icon Composer for Beginners Group Lab，34:37](https://developer.apple.com/videos/play/wwdc2026/8012/?time=2077)
- [Apple · Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [Apple · Change Appearance settings on Mac](https://support.apple.com/guide/mac-help/change-appearance-settings-mchlp1225/mac)

## 验证与重新导出

```sh
python3 design/AppIcon-native-v4/build-icons.py
```

脚本只写此目录。使用 Xcode 27 自带的 `ictool`、`actool`、`swiftc` 和 macOS `iconutil`。记录见 `verification/report.md`。

已进行资源编译、两代六种外观渲染、ICNS 解包与像素尺寸检查、预览目视检查。未在 macOS 14/15/26 独立设备上安装验收，也没有进行 App Store 上传或桌面透明度滑块联动测试。后者不属于 Icon Composer 可实现的行为。

这版只调整原生文档材质配置，没有重新绘制主体。主体沿用上一版内置图像生成工具生成的透明 PNG；光束沿用 SVG。没有采用生成器绘制的玻璃背景或边框。
