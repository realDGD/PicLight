# 动画回归输入

`composite`、`finite`、`short-delay` 和 `poster-default` 沿用 2026-10-19 的独立播放器实验输入，源目录为 `.superpowers/sdd/2026-10-19-sdanimatedimageplayer/`。小图均为 96×64；前者包含局部帧、透明度及 disposal/blend。时长和循环预期直接写在测试中。

`.rgba` 是独立解码器导出的 straight RGBA：GIF 来自 Pillow、WebP 来自 libwebp/Pillow、APNG 来自 FFmpeg。测试转换为 premultiplied RGBA 后逐字节比较。没有使用已发现 alpha OVER 错误的 Pillow APNG 输出。

`poster-default.apng`：独立封面不参加动画，动画三帧为 40/80/120 ms。

`poster-offset-{rgba,rgb,palette,16bit}.apng`：以 Python 标准库 struct/zlib 手工编码 PNG/APNG 块；32×24 画布，独立蓝色封面，第一动画帧是 (5,3) 的 9×7 红色矩形，第二帧向右下各移动 1。第一帧 dispose=PREVIOUS、blend=OVER。动画循环次数为 2。RGB、带 PLTE/tRNS 的调色板、RGBA8、RGBA16 分别检查透明画布与位深，预期位置和颜色由测试中的常量决定。

这些输入用于像素与语义回归，不代表所有编码器、色彩配置、硬件或 macOS 版本都已实测。
