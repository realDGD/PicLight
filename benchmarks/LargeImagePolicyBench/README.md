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

Proxy magnification (D6) compares nearest against linear against ground truth — the original pixels:

```bash
.work/minbench /path/to/photo --width 4032 --height 3024 --magnify 4
.work/minbench "$PICLIGHT_BENCH_FIXTURES/noise-8192x5461.png" --width 3200 --height 2000 --magnify 6
.work/minbench /dev/null --pattern lines --pattern-size 2048 --width 2048 --height 1280 --magnify 4
```

Decision: linear magnification (`results/gates-D6.txt`) — nearest is both further from ground truth and visibly blocky.

### E — policy gaps

```bash
.work/picbench cacheplan                                   # E3 working set / eviction of the on-screen entry
.work/picbench drawseq  "$PICLIGHT_BENCH_GIANT"             # which redraws re-decode
.work/picbench thumb    "$PICLIGHT_BENCH_GIANT" 1024        # one bucket's cost
.work/picbench cancel   "$PICLIGHT_BENCH_GIANT" "$PICLIGHT_BENCH_FIXTURES/noise-4032x3024.png"
```

### E4 — app-level acceptance (traversals, energy, main-thread stall)

```bash
benchmarks/LargeImagePolicyBench/run-e4.sh            # measures 123d943 (pre-change baseline)
benchmarks/LargeImagePolicyBench/run-e4.sh <rev>      # measures any revision, e.g. after implementation
```

`run-e4.sh` exports the revision into `.work/e4-app/`, overlays the temporary instrumentation from
`instrumentation/PicViewMac/`, builds, opens the image through the production path, and prints:

```text
full_stream_traversals   how many times the whole compressed stream is read (baseline 4, target 1)
open_energy_mJ           energy for the whole open (baseline 136.6 J, target <= ~70 J)
main_thread_stall_max_ms max main-queue ping latency (baseline 20.9 s, target p95 < 100 ms)
peakRSS / peakFootprint  memory (RSS stays ~2-2.7 GiB because the source is mmapped)
```

Animation frame path (E5) uses the same harness with a fixed measurement window:

```bash
PICLIGHT_BENCH_SECONDS=20 benchmarks/LargeImagePolicyBench/run-e4.sh 123d943 "$PICLIGHT_BENCH_FIXTURES/anim-1000.gif"
```

(`bench/gen make anim-1000.gif` produces a 1 MPixel, 30-frame, 40 ms-delay GIF; `PICLIGHT_BENCH_SECONDS` switches the
summary loop from "after three draws" to a fixed window, which is required for playback.) Baseline:
`results/gates-E5-animation.txt` — 15.9 fps against a 25 fps nominal, p95 frame period 121 ms, 249 mJ per drawn frame,
main-thread ping p95 98 ms.

It needs a logged-in GUI session (the app opens a real window) and hashes the source image before and after the run.
The instrumentation is deliberately kept as an overlay rather than a patch so it cannot drift with unrelated edits,
and it is never merged into the production tree.

## Results

| file | content |
| --- | --- |
| `results/gates-report.md` | decision report: every gate, its numbers, and the verdict |
| `results/gates-A.txt`, `gates-A-oversized.txt` | materialization runs (`<=8192` class and oversized class) |
| `results/gates-B.txt` | preload/cache policy runs |
| `results/gates-C.txt` | dimension-probe runs |
| `results/gates-D.txt` | minification/shimmer runs |
| `results/gates-D6.txt` | proxy magnification: nearest vs linear against ground truth |
| `results/gates-E5-animation.txt`, `-trace.txt` | animation frame path: cadence, ping, energy |
| `results/gates-E4-baseline.txt` | instrumented-app baseline (traversals, energy, main-thread stall) |

Frozen policy outcomes (spec §17.5): A3 materialization, B3 preload/cache (768 MiB), C2 dimension probe, mandatory
mipmapped minification, linear proxy magnification, view-sized bucket formula, resize debounce policy, animation
non-regression baseline. Nothing policy-level is left open; the only remaining gate is E4's post-implementation run
(`run-e4.sh <rev>`), which measures the change itself.
