# 超大图片（1.9 GB PNG）加载与 Metal 加速探索报告

日期：2026-09-17 · 基线 commit：`123d943` · 机器：MacBook Air M4 (Mac16,12)，16 GB，macOS 27.0 (26A428)，Xcode 27
测试图片：`/Users/dgd/Downloads/万萝图/万萝图.png`

> 本文件是探索结论，**不是** 已实施的修改。所有生产改动等结论确认后再决定。

---

## 0. 安全与可重复性

源文件全程只读，未覆盖 / 重编码 / 改 metadata / 移动 / 删除：

```
before: 119b1ec43ff69abd2a489a0a3a49bcdf69c99c31755a2df81882af8be084fb5d
after : 119b1ec43ff69abd2a489a0a3a49bcdf69c99c31755a2df81882af8be084fb5d
size=2071102933  mtime=Dec 11 19:42:40 2025  mode=-rw-r--r--
```

- 仓库 `123d943` 工作区保持 clean；所有实验代码在 `/tmp/piclight-bench/`，未进 Git，未提交源图片。
- 1.9 GB 源文件从未被写入；派生产物只写入 `/tmp`（`/tmp/piclight-bench/assets/downsample-8192.bmp`、`/tmp/piclight-bench/clones/*.png`，后者是 APFS COW clone，不额外占盘）。

### 工具与可重复命令

| 工具 | 位置 | 说明 |
| --- | --- | --- |
| `picbench` | `/tmp/piclight-bench/PicBench/` | 直接编译 `123d943` 的 `Imaging/*.swift` + `Metadata/MetadataReader.swift`（`git archive` 导出，vendored 到 `vendor/`），因此测的就是生产解码路径 |
| `p1_probe` | `/tmp/piclight-bench/p1_probe.swift` | Phase 1：元数据 + PNG IHDR/chunk 走查 + Metal 上限 |
| `renderbench` | `/tmp/piclight-bench/renderbench/main.swift` | Phase 7/8：CGContext vs Metal 的渲染器对比 |
| 计时/内存 | `Probe.swift` | `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`；内存用 `task_info(TASK_VM_INFO)` 的 `phys_footprint`；峰值用 `getrusage.ru_maxrss`；能量用 `task_info(TASK_POWER_INFO_V2).task_energy`（nJ）；外部交叉验证用 `vmmap` / `footprint` / `sample` |

```bash
# 构建
cd /tmp/piclight-bench/PicBench
swiftc -O -swift-version 6 vendor/*.swift Probe.swift main.swift -o picbench

# 核心命令（原文，可直接复现）
./picbench create "<PNG>" --draw 3200 --repeat 2      # 生产路径：CreateImageAtIndex + 画到 1600x1000pt 的 Retina canvas
./picbench thumb  "<PNG>" 2048 --imm 1                # 缩略图 2048（同理 64/256/4096/8192/16384/48000）
./picbench thumb  "<PNG>" 4096 --imm 0 --drawLong 4096
./picbench orient "<PNG>"                             # 生产 decodeFirstDisplayableFrame（含 orientation 判断）
./picbench ci     "<PNG>" --ctx mtl --scale 0.08533   # Core Image 缩到 4096 后真实渲染
./picbench ci     "<PNG>" --ctx mtl --noScale --render 1920x1080   # 原尺寸裁一块 1080p
./picbench crop   "<PNG>" --row 0     --rows 1000 --draw 2000      # 区域解码（顶部）
./picbench crop   "<PNG>" --row 16000 --rows 1000 --draw 2000      # 区域解码（中部）
./picbench subsample "<PNG>" 8                        # kCGImageSourceSubsampleFactor
./picbench pipeline  "<PNG>" --prev <clone> --next <clone>         # 生产 DecodeCoordinator + preload
./picbench cachesem  "<PNG>"                          # DecodeCache 成本模型 / NSCache 行为
./picbench texup     "<PNG>" 16384                    # 解码 + 上传成 Metal texture
./picbench cancel    "<PNG>" fixtures/static.png      # Task.cancel 后底层是否真的停
./picbench drawseq   "<PNG>"                          # 同一 CGImage 不同目标尺寸的 draw 序列（缓存行为）

# Phase 2 应用基线（带临时 instrumentation 的副本，非生产树）
PICLIGHT_TTI_BENCH="<PNG>" /tmp/piclight-bench/app-bench/.build/release/PicViewMac

# Phase 7/8 渲染器对比
cd /tmp/piclight-bench/renderbench && swiftc -O main.swift -o renderbench
./renderbench /tmp/piclight-bench/assets/downsample-8192.bmp zoom  cg    --seconds 20
./renderbench /tmp/piclight-bench/assets/downsample-8192.bmp zoom  metal --seconds 20
./renderbench /tmp/piclight-bench/assets/downsample-8192.bmp idle  metal --on-demand --seconds 30
./renderbench "<PNG>" pan cg --lazy --seconds 20      # 真实 lazy 巨图 + 当前渲染器
```

---

## 1. 图片属性

| 项目 | 值 |
| --- | --- |
| file size | 2,071,102,933 B = **1.929 GiB** |
| UTType | `public.png` |
| dimensions | **48000 × 32000** |
| pixels | **1,536,000,000**（1.536 Gpx） |
| PNG IHDR | bitDepth 8，colorType 6（RGBA），**interlace 0（非 Adam7）** |
| PNG chunks | IHDR×1, pHYs×1, **IDAT×1976（1,975.1 MiB 负载，单流）**, IEND×1；无 tEXt/iCCP |
| zlib | CM=8 deflate，window 32768，无预设字典 |
| depth / color model | 8 bit / RGB（hasAlpha=true，非 float，非 indexed） |
| color space | ImageIO 报 `kCGColorSpaceSRGB`，无 ICC profile 名 |
| orientation | **1 = `.up`** |
| 理论 RGBA8 | 6,144,000,000 B = **5.722 GiB** |
| 理论 RGBA16 | 11.444 GiB |
| 压缩率 | 1.536 Gpx ÷ 1.93 GiB ≈ 3.0× vs RGBA8 |
| 单 Metal texture | **不可能**：48000 与 32000 均 > 16384（上限由运行时断言给出，见 Phase 9） |

Metal：Apple M4，`maxBufferLength` 8.88 GiB，`recommendedMaxWorkingSetSize` 11.84 GiB；支持 Apple4–Apple9 全部 family。

> 环境提示：整轮测试期间机器上还有别的进程占用 4.5–8.5 GB swap（`vm.swapusage`）。这会让 5.7 GiB 级别的分配出现换页/压缩，报告在相关处在数字旁标注。

---

## 2. Baseline（PicLight `123d943`，真实 AppKit 应用，走 Finder 同一条 open 路径）

时间轴（T0 = `FileOpenCoordinator.open`，来自 instrumented 副本；两次运行一致）：

```
T+ 0.000  T0 用户发起打开                footprint  12 MiB
T+ 0.209  canvas draw #1（image=nil）     —— 只是背景
T+ 0.227  [bg] sidebar 300px 缩略图开始
T+ 0.237  T1 CGImageSourceCreateWithURL
T+ 0.245  T2 source 创建完成
T+ 0.246  T2 descriptor/属性完成
T+ 0.246  T3 即将 CGImageSourceCreateImageAtIndex
T+ 0.246  T4 CGImage 返回（lazy！）
T+ 0.247  T5 ViewerState.apply(head:) —— UI 认为已经有图了
T+ 0.257  canvas draw #2 image=yes zoom=0.0186，draw() 本身 0.000 s
T+ 18.967 [bg] thumbnail(300) 结束        = 18.7 s 后台解码
T+ 20.1   第一次真正的栅格化结束（主线程被阻塞约 19.6 s）
T+ 21.742 [bg] navigator preview(336px) 开始
T+ 42.046 [bg] navigator preview 结束     = 20.3 s 又一次全量解码
```

关键点：`draw()` 只花 0.000 s，因为视图是 layer-backed——真正的栅格化发生在 QuartzCore 的 `CA::CG::Queue`，主线程阻塞在 `CA::Transaction::commit()` → `CABackingStoreGetFrontTexture` → `_dispatch_sync_f_slow`。`sample` 抓到了完整栈：

```
CA::CG::Queue (serial)
  CA::CG::DrawImage::draw_image
    CA::Render::copy_image → create_image_by_rendering
      CGContextDrawImageWithOptions
        ripc_AcquireRIPImageData → img_data_lock → img_interpld_read
          IIOImageProviderInfo::copyImageBlockSetWithOptions
            PNGReadPlugin::copyImageBlockSetStandard
              PNGReadPlugin::DecodeUncomposedFrames / DecodeFrameStandard
                png_read_row_indexed → png_read_IDAT_data → inflate (libz)
```

同时另一条线程 `com.apple.root.utility-qos.cooperative`：

```
ThumbnailPipeline.thumbnail(for:maxPixelSize:) → makeThumbnail
  CGImageSourceCreateThumbnailAtIndexEx → IIOImageSource::createThumbnailAtIndex
    CGImageCreateCopyWithParametersNew → CGContextDrawImage → …同样的 PNG 解码栈
```

### Baseline 汇总

| 指标 | 实测 |
| --- | --- |
| 元数据 + 创建 CGImage（lazy） | **~10–36 ms** |
| UI 收到 image（T5） | **0.21–0.52 s** |
| 第一次真正画出像素 | **~19.6 s**（主线程全程冻结，beachball） |
| 首次打开期间的总解码工作 | canvas 栅格化 ~20 s + sidebar 300px ~19 s + navigator preview ~20 s ≈ **~60 s** |
| 峰值 `phys_footprint` | **5.86 GiB**（ImageIO 位图） |
| 峰值 RSS (`ru_maxrss`) | **7.79 – 8.99 GiB** |
| 结束后 footprint | 1.45 GiB |
| 峰值 CPU 占用 | 单核饱和（cpu/wall ≈ 1.0） |
| 互动的真实帧率 | **~0.05 fps**（20 s 一帧，见 Phase 7） |

---

## 3. ImageIO 微基准（独立可执行，不经过 UI；同一张图）

| Method | Output | Time | Peak footprint (charged) | Peak RSS | 是否产生完整尺寸 bitmap |
| --- | ---: | ---: | ---: | ---: | --- |
| `CreateImageAtIndex`（无 options，生产路径） | 48000×32000 lazy | **返回 19 ms**（decode 0 ms） | 43 MiB | 0.12 GiB | 否（直到 draw） |
| 上者 + draw 到 3200×2133 | — | **18.5 – 20.9 s** | **5.761 GiB** | 4.4 – 7.7 GiB | **是：5.86 GiB 的 `Image IO` 区域** |
| `CreateThumbnailAtIndex` 64 | 64×43 (0.01 MiB) | **17.96 s** | 0.060 GiB | 2.00 GiB | 否（流式） |
| `CreateThumbnailAtIndex` 2048 | 2048×1365 (10.7 MiB) | 18.4 – 18.8 s | 0.098 GiB | 2.03 GiB | 否 |
| `CreateThumbnailAtIndex` 4096 | 4096×2731 (42.7 MiB) | 18.5 – 19.2 s | 0.193 – 0.231 GiB | 2.12 – 2.17 GiB | 否 |
| `CreateThumbnailAtIndex` 8192 | 8192×5461 (170.7 MiB) | 18.1 s | 0.756 GiB | 2.69 GiB | 否 |
| `CreateThumbnailAtIndex` 16384 | 16384×10923 (682.7 MiB) | 18.4 s | 2.844 GiB | 4.78 GiB | 否 |
| `CreateThumbnailAtIndex` 48000（原尺寸） | 48000×32000 (5859 MiB) | 18.96 s | **7.453 GiB** | 4.90 GiB | **是（最差）** |
| `SubsampleFactor=4` + `ShouldCacheImmediately` | 12000×8000 (366 MiB) | create **18.07 s** + 首次 draw **17.95 s** | 0.769 GiB | 3.43 GiB | 是（小尺寸） |
| `SubsampleFactor=8` | 6000×4000 (91.6 MiB) | 18.52 s + 18.44 s | **0.225 GiB** | 2.35 GiB | 是（小尺寸） |
| `cropping(to: rows 0..1000)` + draw | 48000×1000 | **16.86 s** | **5.734 GiB** | 5.44 GiB | **是（整张！）** |
| `cropping(to: rows 16000..17000)` + draw | 48000×1000 | 16.72 s | 5.734 GiB | 6.46 GiB | 是（整张） |
| Core Image，Mtl context，scale→4096 | 4096×2731 | **25.85 s**（第二次 7.74 s） | **11.862 GiB** | 5.81 GiB | 是 + 额外 |
| Core Image，Mtl context，原生裁 1920×1080 | 1920×1080 | **17.42 s**（第二次 0.001 s） | 5.809 GiB | 7.68 GiB | 是（整张） |

`cacheImmediately: true/false` 对缩略图没有行为差异（缓存选项对这张图无效；同一 CGImage 的第二次 draw 也不会因此变快）。

### Phase 4：峰值到底来自哪里（硬证据）

缩略图 4096 进行到第 12 秒时 `vmmap -summary`：

```
mapped file    1.9G   1.4G     <- 1.93 GB 压缩源文件被 mmap 进本进程
MALLOC TOTAL  114.8M  49.3M    <- 所有堆分配合计 115 MB
phys_footprint: 193 MB
```

生产路径（CreateImageAtIndex + draw）进行到第 10 秒时 `footprint`：

```
Footprint: 5868 MB
    5859 MB   0 B   0 B   2   Image IO      <- 一个 5.7 GiB 的匿名 VM 区域
```

`vmmap` 单行：

```
Image IO  707b72c000-71e9a8c000  [  5.7G   5.7G   3.2G   2.6G] rw-/rwx SM=ZER PURGE=N
                                          ^virt  ^res  ^dirty  ^swapped
```

结论（实测，不是推测）：

* **缩略图/流式路径**：不产生完整 bitmap。真正的大块是「mapped file 1.4–1.9 GB」，即压缩源文件本身；所有 malloc 合计只有 115 MB。
* **生产路径**：ImageIO 分配一整块 5.86 GiB 的匿名区域（`SM=ZER`），其中 3.2 GiB resident、**2.6 GiB 被换出到 swap**（16 GB 机器上的必然结果）。峰值 RSS 在 4.4–7.7 GiB 之间波动正是换页程度不同所致。
* 压缩文件大小（1.93 GiB）与解码后位图（5.86 GiB）相差 3.0×，两者绝不能混用。

---

## 4. 瓶颈分解（`sample` 采样，3 s 窗口，两条解码线程并行）

按栈顶符号聚合（去掉内核等待）：

| 组 | 采样占比 |
| --- | ---: |
| PNG 行反滤波（`png_read_filter_row_paeth_neon`） | **~45 %** |
| zlib inflate（`inflate` + `libz` 内部符号） | **~43 %** |
| vImage 重采样（`vVertical_Shear_ARGB_8888`, `vHorizontal_Scale_ARGB_8888_SME_64x16`） | ~8 % |
| memmove / 其他 | ~4 % |

与时间侧的独立证据一致：**输出尺寸从 64 px 到 16384 px，耗时几乎恒为 17.9–19.2 s**（2048: 18.4 s；16384: 18.4 s；64: 17.96 s）。说明成本由「读完 1.93 GiB deflate 流 + 反滤波 1.536 Gpixel」决定，与输出大小无关。

吞吐：1.536 Gpx ÷ 18.5 s ≈ **83 Mpixel/s**；1.93 GiB ÷ 18.5 s ≈ **112 MB/s 压缩流**。

相对量级（对当前 1.9 GB PNG）：

| 环节 | 量级 |
| --- | --- |
| I/O（冷页，1.93 GiB） | 小；热页下几乎为 0（重复运行时间不变） |
| PNG inflate + 反滤波 | **~88 %**（决定性） |
| 位图分配（5.86 GiB） | 0 时间，但决定内存与 swap |
| orientation | **0**（本图 `.up`，代码走早退分支） |
| CGContext 栅格化/重采样 | ~8 %（vImage） |
| texture 上传 | 8192: 22 ms / 16384: 91 ms（可忽略） |
| Metal 渲染 | 中位 0.7–2.0 ms/帧 |

---

## 5. Renderer 对比（Phase 7 / 8）

固定条件：1600×1000 pt 视图、同一张已解码的 8192×5461 图（`downsample-8192.bmp`），驱动脚本每 1/60 s 更新一次视口。能量来自 `task_energy`（nJ）。

| Renderer | idle 30 s | 连续 zoom 20 s | 连续 pan 20 s | rotate 20 s |
| --- | --- | --- | --- | --- |
| CGContext（当前 `ImageCanvasView` 逻辑） | 1 帧, **57 mW**, CPU 0.35 s | **29.4 fps**, **4196 mW**, CPU 14.1 s | 59.2 fps, 119 mW | 59.0 fps, 114 mW |
| Metal 连续渲染 | 1796 帧 (59.9 fps), **34 mW**, GPU 4.7 % | 59.8 fps, **39 mW**, GPU 1.16 ms/帧 | 59.9 fps, 38 mW | 59.9 fps, 38 mW |
| Metal on-demand (`isPaused`+`setNeedsDisplay`) | **1 帧, 5.4 mW**, CPU 0.10 s | 60.0 fps, 38 mW | 60.0 fps, 42 mW | — |
| **当前渲染器 + 真实 lazy 巨图** | — | **0.05 fps**（20 s 一帧）, **4109 mW**, CPU 19.1 s | **0.1 fps**（20 s 一帧）, 4153 mW | — |

结论：

* 缩放（scale 连续变化）是 CGContext 的重负载：**4.2 W / 29 fps**，而同机 Metal 只需 **38 mW / 60 fps**（~110×）。平移/旋转因为 CA 能复用重采样结果，CG 侧也很便宜（~120 mW）。
* 对**这张真实巨图**，当前渲染器是 **~20 s 一帧、主线程全程冻结**，因为每次重栅格化都要重新解码 5.86 GiB。
* **on-demand 是纯赚**：交互性能与连续渲染完全相同（60 fps），静态 30 s 的能耗 5.4 mW vs 34 mW（6.3×），wakeup 1953 vs 9136。静态图片查看器没有理由连续渲染。
* Metal 完全不能改善**加载**：解码是 CPU 的 inflate/反滤波；纹理上传 8192 只要 22 ms、16384 只要 91 ms，相对 18 s 的解码是噪声。

---

## 6. 结论（只从数据出发）

| 方案 | 判定 | 依据 |
| --- | --- | --- |
| A. 保持现状 | **否** | 首次可见 ~20 s、主线程冻结、峰值 5.86 GiB footprint / 7.8–9.0 GiB RSS、互动 0.05 fps、每次重开重复付 18.5 s |
| B. ImageIO downsample（缩略图 API） | **部分成立（内存赢，时间不赢）** | 4096: 峰值 footprint 5.86 GiB → **0.19 GiB**（30×），时间 19.4 → 18.5 s（几乎不变）。且它真的不产生完整 bitmap（malloc 总计 115 MB）。作为「显示用位图」是当前 API 里最划算的 |
| C. 多级分辨率 | **内存/纹理上限需要，时间上无收益** | 2048/8192/16384/native 的**创建**耗时都是 17.9–19.2 s；先 2048 再 native = 18.4 + 19.4 = 37.8 s，比直接 native 更慢。它的价值是峰值内存（100 MiB / 774 MiB / 2.9 GiB）与「能否塞进一个 texture」 |
| D. Metal renderer | **是（交互层面）** | zoom 4196 mW→38 mW、29 fps→60 fps；on-demand idle 5.4 mW。纹理上传 22–91 ms，不解决解码 |
| E. Core Image + Metal | **否** | 首次真实渲染 25.85 s（比缩略图慢 40 %），峰值 footprint 11.86 GiB；连 1920×1080 的原生裁剪也要 17.42 s + 5.81 GiB（不做区域解码） |
| F. Tile renderer | **仅在有自定义解码器时可行** | 用 `CGImage.cropping(to:)` 取 1000 行仍要 16.86 s / 5.73 GiB —— 也就是「一个 tile = 一次全量解码」。CATiledLayer/Metal tile 不会自动带来随机区域 PNG 解码 |
| G. 新 decoder / backend | **唯一能改变「首次可见时间」的方向** | 所有 ImageIO 路径都是 Θ(整文件)；要 sub-second 首图只能靠可提前停止的流式解码或预先建好的金字塔缓存（侧车） |

组合建议：**B（显示用 bounded bitmap）+ D（Metal on-demand renderer）+ G/P2 的侧车金字塔缓存** 是数据支持的方向；C 作为纹理/内存的配套；E、F 暂不投入。

---

## 7. 推荐的生产修改

### P0-1 主图解码改为「预算内 bounded bitmap」
- **收益**：峰值 footprint 5.86 GiB → 0.19 GiB（4096）或 0.10 GiB（2048）；消除 2.6 GiB 的 swap 写入；主线程冻结从 ~20 s 降到可接受范围（配合 P0-2）。
- **复杂度**：低。`ImageIODecoder.decodeOriented` 增加一条 `CreateThumbnailAtIndex(maxPixelSize: budget, transform: true, cacheImmediately: true)` 路径；`budget = ceil(max(canvasPixels, navigatorPixels) × 2)`。
- **风险**：几何语义。`ImageCanvasView.imagePixelSize` 直接取 `image.width/height`（`ImageCanvasView.swift:50-53`），`refit/setZoomToFit/setZoomToActualPixels/rotateClockwise` 与 `ViewerViewController.regenerateNavigatorPreview` 的 `applyNavigatorSize(for: CGSize(width: image.width, height: image.height))` 都依赖它；`ViewportState.actualPixelScale` 把 100 % 定义成「1 图像像素 = 1 显示像素」。因此**必须**把 `sourcePixelSize` 独立携带，否则 Fit / 100 % / pan / navigator / zoom % 全部错位。
- **数据**：§3 表；§4 证明时间几乎不变（所以这项不是性能优化，是内存与稳定性优化）。

### P0-2 不要让 native 巨图在 CA 队列上被缩放栅格化
- **收益**：这是那 19–20 s 主线程冻结的直接原因。`draw()` 只花 0 s，代价全在 `CA::Transaction::commit` 等 `CA::CG::Queue` 完成 `CGContextDrawImage` → 全量解码。
- **复杂度**：低（P0-1 之后自动缓解）。
- **风险**：画质（缩略图放大到 fit 显示时比 native 略软；可用 8192/16384 级别缓解）。
- **数据**：§2 时间轴、§4 栈；§5「真实 lazy 巨图 + 当前渲染器 = 0.05 fps」。

### P0-3 修正 DecodeCache 的成本模型
- **收益**：避免「缓存永远命中不了、却按 5.72 GiB 计费」的假象。
- **复杂度**：低。
- **风险**：无（纯记账）。
- **数据**：`DecodeCache.cost(of:)` 对这张图算出 **5.722 GiB**，是 384 MiB 预算的 **15.3×**；实测 `store` 后立刻 `head(for:)` 返回 **nil（立即被逐出）**；连放 3 个超大 entry 也全部逐出。注意被缓存的是 **lazy 引用**，所以「命中」也省不掉真正的解码。
  另：`DecodeTarget.maxPixelSize` 对单表示图片**完全无效**——`ImageIODecoder.selectIndex` 只在 `count > 1` 时用它（ICO 多尺寸），实测 `--target 4096` 返回的 head 仍是 48000×32000。

### P0-4 限制/复用「附加解码」
- **收益**：首次打开少掉两次全量解码。
- **复杂度**：低–中。
- **风险**：侧栏/导航器预览变模糊或延后。
- **数据**：App 基线里 sidebar 300 px 缩略图 = **18.7–19.9 s**（`ThumbnailPipeline.thumbnail(url:maxPixelSize:300)`），navigator preview = **20.3 s**（`preview(from: 48000x32000, maxPixelSize: 336)`）。两者都是全流解码；对 >N 像素的文件应当复用 P0-1 的那一份 bounded bitmap，或直接跳过。

### P1-1 Metal 渲染器 + on-demand 绘制
- **收益**：zoom 4.2 W → 0.04 W、29 fps → 60 fps；静态能耗 34 mW → 5.4 mW。
- **复杂度**：中（MTKView + 一个 textured quad + 变换矩阵 + mipmap；本报告的 `renderbench` 已有可用最小实现）。
- **风险**：色彩管理（纹理用 sRGB + premultiplied alpha；thumbnail 输出本身是 premultipliedFirst/BGRA，正合适）；16384 纹理上限要求上游先给 bounded bitmap（P0-1）；需要非 Metal 回退。
- **数据**：§5 表。

### P1-2 让「昂贵步骤」可取消 / 不阻塞主线程
- **收益**：切图不再有 19.4 s 的无效后台作业与 62.8 J 无效能耗；新图不被阻塞。
- **复杂度**：中。
- **风险**：需要在解码循环里插入检查点（ImageIO 没有提供取消接口）。
- **数据**：`Task.cancel()` 之后底层**继续跑满 19.4 s**，消耗 user 16.2 s + sys 2.1 s、**62.8 J**，峰值 footprint 仍到 5.76 GiB；同时另一线程的小图解码只花 3 ms（所以问题不是线程饥饿，而是主线程被 CA 事务阻塞）。

### P2-1 侧车金字塔缓存（sidecar proxy）
- **收益**：二次打开从 18.5 s 变成**亚秒级**。
- **复杂度**：中（缓存目录 + 命名 key + 失效策略）。
- **风险**：磁盘占用（一个 8192 代理约 170 MB）、缓存失效（用 path + size + mtime 做 key）、首次仍需 18 s。
- **数据**：8192×5461 BMP 的读回 = **0.12 s**；从 BMP 到纹理可用 = **0.337 s**；无缓存时同一份数据要 18.1 s。

### P3-1 自定义流式 PNG 解码器（唯一能真正压缩首图时间的路径）
- **收益**：可提前停止、边解边降采样，理论上 5 % 的流 ≈ 1 s 量级。
- **复杂度**：高。
- **风险**：需要自己实现 PNG 反滤波 + 增量 box filter，且要处理正确性/色彩管理。
- **数据**：所有 ImageIO 路径对输出大小不敏感（64 px 也要 17.96 s），区域裁剪要 16.86 s；而吞吐是 ~112 MB/s 压缩流，所以「只读 5 %」≈ 1 s。

### P3-2 tile rendering（仅在 P3-1 之后）
- **收益**：native 像素、有界内存。
- **数据**：CGImage 级 tile 不可行（每次 tile = 16.9 s / 5.73 GiB）；必须先有能随机访问行的自定义解码器。

---

## 8. 探查中得到的新想法（问题 10）

1. **侧车金字塔是最快的落地捷径**：首次打开后写一个 4096/8192 代理到 app 自己的 cache 目录，之后打开是 0.12–0.34 s 级别；「100 % 锐利」再按需解码 native。这条路径不改文件、不改格式，收益却是数量级的。
2. **不要用「原尺寸缩略图」**：`CreateThumbnailAtIndex(maxPixelSize: 48000)` 峰值 **7.45 GiB**，比生产路径的 5.76 GiB 还差。任何「拿一份完整位图」的做法都该设上限。
3. **`kCGImageSourceSubsampleFactor` 的低内存特性值得留意**：factor 8 得到 6000×4000、峰值 footprint 仅 **0.225 GiB**，是所有「拿到可绘制位图」方案里内存最低的；代价是 create 与首次 draw 各 18 s（合计 36 s）。若未来需要一个确定小的位图且不在意延迟，它比缩略图 API 更省内存。
4. **同一 CGImage 实例内存在栅格化缓存**：新 CGImage 首次 draw 18.5 s，同一实例再 draw 同一尺寸 3 ms、不同尺寸 ~2.3–2.6 s（且仍会瞬时分配 5.7 GiB）。因此「保住实例」能省掉重复的 18 s，但省不掉那一次 5.7 GiB 峰值，也帮不到重开/切回上一张。
5. **on-demand Metal 的 wakeup 反而更高但更省电**（1953 wakeups/5.4 mW vs 连续 9136/34 mW），说明 wakeup 计数不能当作能耗代理。
6. **测量方法学**：在本机 `rusage_info_v6` 的早期字段读出来是 0，且内核会写超过 SDK 结构体长度（触发 `__stack_chk_fail`）；`task_info` 的 `TASK_VM_INFO`/`TASK_POWER_INFO_V2` 用大堆缓冲才可靠。这是 macOS 27 SDK 与内核的 ABI 漂移，做性能台架时要绕开。

---

## 9. 两份数据的不一致与解释（要求 10）

* **Instruments/xctrace 未能录制**：`xctrace record --template "Time Profiler"/"Allocations"` 两次都报 `_lockKPerf: could not lock kperf. Likely another session just started.`，录制时长 0.6 s 即失败。因此没有 Instruments GUI 的数字；改用同类的命令行工具：**`sample`**（采样调用树，即 Time Profiler 的同类数据）、**`vmmap -summary`**、**`footprint`**、`ps`，加上进程内计数器。上面的栈与 45 %/43 %/8 % 分解来自 `sample`。
* **峰值内存三个口径不一致，原因明确**：
  * `phys_footprint`（macOS 计入内存压力的量）：峰值 **5.86 GiB**（生产路径）/ 0.19 GiB（4096 缩略图）。
  * `ru_maxrss`（resident，含 mmap 的源文件）：同一场景 **4.4–7.7 GiB**，波动来自源文件页与位图页各自被换出/压缩的程度。
  * 采样器时间序列：缩略图 4096 的 footprint 稳定在 **188 MiB**，而 resident 从 0.24 GiB 一路爬到 2.05 GiB——多出来的就是 mmap 的 1.9 GB 压缩文件，不是像素缓冲。
  结论：判断「峰值 bitmap」必须看 `phys_footprint` + `vmmap` 区域名；只看 `ps`/RSS 会把压缩文件页误算成解码缓冲。
* **能量口径**：`task_energy`（`TASK_POWER_INFO_V2`，nJ）在本机可用且读数合理（例如 3 M 次 sqrt 约 48 ms CPU → 10 mJ）；`powermetrics` 需要 sudo，本环境不可用；`rusage_info_v6` 的 `ri_billed_energy` 在本机读数为 0，因此未采用。
* **进程内采样器的局限**：500 Hz 采样可能错过瞬时尖峰（4096 缩略图那次采样峰值 231 MiB 而 `getrusage` 峰值 2.12 GiB），所以两个数都保留了。

---

## 10. 一句话总结

这张 1.536 Gpx 的 PNG 上，**时间由 PNG 解压（inflate + Paeth 反滤波，~88 %）决定，且与输出尺寸无关（64 px 也要 18 s）**；**内存由是否产生完整位图决定（5.86 GiB vs 0.19 GiB，30×）**；当前实现同时踩中两点——首次可见 ~20 s、主线程冻结、峰值 5.86 GiB footprint / 8–9 GiB RSS、互动 0.05 fps。ImageIO 缩略图接口能在**不增加时间**的前提下把内存降一个数量级；Metal 能把**互动**从 0.05 fps / 4.2 W 变成 60 fps / 0.04 W，但无法改善加载；Core Image 与基于 CGImage 的 tile 都更差（11.9 GiB / 每次 tile 全量解码）。要真正缩短首次可见时间，只有「可提前停止的流式解码」或「侧车金字塔缓存」两条路。
