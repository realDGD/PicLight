# LargeImagePolicyBench

Policy benchmark harness for the large-image (bounded decode + on-demand Metal) design.
It answers the A/B/C/D policy questions that `docs/superpowers/specs/2026-09-17-large-image-bounded-metal-design.md`
requires to be resolved by measurement rather than preference, and it reproduces the numbers in
`results/gates-report.md` and spec §17.5.

**This is not part of the production target.** It is a standalone tool with its own build script; nothing here is
linked into `PicViewMac` and `Package.swift` is untouched.

## Safety rules

- The investigation image (`万萝图.png`, ~1.9 GiB) is opened **read-only** and is never committed. Its SHA-256 is
  verified before and after runs.
- All test images are generated into a temp directory. Nothing large is ever added to Git.
- The harness re-derives the production imaging sources from Git at build time instead of copying them into the
  tree, so it always measures the same decoder the app ships and there is no second copy to drift.

## Build

```bash
benchmarks/LargeImagePolicyBench/build.sh          # uses HEAD
benchmarks/LargeImagePolicyBench/build.sh <rev>    # measure a specific revision
```

This extracts `PicViewMac/Imaging/*.swift` and `PicViewMac/Metadata/MetadataReader.swift` from the given revision
into `.work/vendor/` and builds four binaries into `.work/`:

| binary | role |
| --- | --- |
| `picbench` | decode/materialization/cache/preload gates (A, B, E) |
| `gen` | generates the fixture set (incompressible PNGs, JPEG, adversarial solid giants) |
| `minbench` | offscreen minification-quality gate (D) |
| `probebench` | folder dimension-probe gate (C) |

Environment overrides:

```bash
PICLIGHT_BENCH_GIANT=/path/to/huge.png      # default: the investigation image
PICLIGHT_BENCH_FIXTURES=/path/to/fixtures   # default: /tmp/piclight-bench/fixtures
```

## Fixtures

```bash
.work/gen list
.work/gen make noise-8192x5461.png      # decisive A/D member: incompressible, real inflate+Paeth work
.work/gen make noise-8192x8192.png
.work/gen make noise-7000x7000.png
.work/gen make noise-6000x4000.png
.work/gen make noise-4032x3024.png
.work/gen make photo-4032x3024.jpg
.work/gen make grad-12000x9000.png
.work/gen make solid-12000x12000.png    # adversarial: a few MB on disk, but oversized
.work/gen make solid-8192x8192.png
.work/gen tiny 5000 /tmp/piclight-bench/folders/small5000
```

Why incompressible fixtures: a solid or highly compressible PNG decodes almost instantly and hides the failure mode
a benchmark is looking for (a decode landing inside the renderer's first draw). A JPEG of the same dimensions decodes
roughly ten times faster than a PNG, so results are always reported per format.

## Gates

### A — materialization (spec §5.1)

```bash
.work/picbench matbench "$PICLIGHT_BENCH_FIXTURES/noise-8192x5461.png" --mode a1   # lazy + cache flags
.work/picbench matbench "$PICLIGHT_BENCH_FIXTURES/noise-8192x5461.png" --mode a2   # native-sized thumbnail
.work/picbench matbench "$PICLIGHT_BENCH_FIXTURES/noise-8192x5461.png" --mode a3   # background materialize
```

`--pause-publish S` / `--pause-draw S` hold the process so `vmmap`/`footprint` can be sampled in each phase.
Decision: A3 (see `results/gates-A.txt`).

### B — preload/cache (spec §13)

```bash
.work/picbench preloadbench --set normal --workload 0,1,2,3 --canvas 4096 --dwell 0.6
.work/picbench preloadbench --set big3   --workload 0,1,2   --canvas 4096 --dwell 0.8
.work/picbench preloadbench --set mixed  --workload 1,2,3   --canvas 4096 --dwell 0.6
.work/picbench cacheplan
```

`preHit` counts navigations served by an entry a *preload* stored; speculative CPU/energy are measured inside each
preload task, so work completed after cancellation is included. Decision: B3 with a 768 MiB budget
(`results/gates-B.txt`).

### C — dimension probe (spec §14)

```bash
.work/probebench /tmp/piclight-bench/folders/small5000 --policy c1        # eager
.work/probebench /tmp/piclight-bench/folders/small5000 --policy c2        # on-demand
.work/probebench /tmp/piclight-bench/folders/mixed     --policy c4        # deliberately UNSOUND two-way filter
```

`c4` exists to demonstrate the failure: a folder containing a 2.5 MB file that *is* oversized
(`solid-12000x12000.png`) and a 148 MB file that is *not* (`noise-8192x5461.png`). Decision: C2, byte size only
orders probes (`results/gates-C.txt`).

### D — minification quality (spec §9.4)

```bash
.work/minbench /path/to/photo --width 3200 --height 2000 --scales 1,1.7,3.7,11.3
.work/minbench /dev/null --pattern checker --scales 1.7,3.7,11.3
```

Reports RMSE against the Quartz `.high` reference, two-frame shimmer (sub-pixel offset), retained detail, GPU time.
Use **non-integer** minification ratios: at exact powers of two a 1-px checkerboard degenerates to flat grey and
bilinear accidentally equals a box filter. Decision: mipmaps unconditional (`results/gates-D.txt`).

### E — policy gaps

```bash
.work/picbench cacheplan                                   # E3 working set / eviction of the on-screen entry
.work/picbench drawseq  "$PICLIGHT_BENCH_GIANT"             # which redraws re-decode
.work/picbench thumb    "$PICLIGHT_BENCH_GIANT" 1024        # one bucket's cost
.work/picbench cancel   "$PICLIGHT_BENCH_GIANT" "$PICLIGHT_BENCH_FIXTURES/noise-4032x3024.png"
```

E4 (app-level traversal/energy/stall) needs the instrumented app copy described in `results/gates-report.md`; the
baseline is captured there and re-measured after implementation.

## Results

| file | content |
| --- | --- |
| `results/gates-report.md` | decision report: every gate, its numbers, and the verdict |
| `results/gates-A.txt`, `gates-A-oversized.txt` | materialization runs (`<=8192` class and oversized class) |
| `results/gates-B.txt` | preload/cache policy runs |
| `results/gates-C.txt` | dimension-probe runs |
| `results/gates-D.txt` | minification/shimmer runs |
| `results/gates-E4-baseline.txt` | instrumented-app baseline (traversals, energy, main-thread stall) |

Frozen policy outcomes (spec §17.5): A3 materialization, B3 preload/cache (768 MiB), C2 dimension probe, mandatory
mipmapped minification, view-sized bucket formula, resize debounce policy. Open, non-blocking: proxy magnification
(D6) and animation frame-path stall (E5).
