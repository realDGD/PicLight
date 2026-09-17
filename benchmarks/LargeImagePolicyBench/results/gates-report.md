# Policy gate results (A/B/C/D + E-series) — spec v2 @ 6dc67d5

Date: 2026-09-17 · Machine: MacBook Air M4, 16 GB, macOS 27.0 · Source image: 万萝图.png 48000×32000, SHA-256 unchanged
Harness: `/tmp/piclight-bench/` (`PicBench` = vendored production decoder + counters; `minbench`, `probebench`,
`gen` for fixtures; `app-bench` = instrumented app copy). All results also in `/tmp/piclight-bench/results/gates-*.txt`.
No production code was written. No repo/spec file was modified.

---

## Gate A — materialization mechanism (decides §5.1)

Fixtures: incompressible PNGs (real inflate+Paeth work), a JPEG, a compressible 12000×9000, the giant.
"first_draw" = the renderer's first draw of the delivered object; a decode inside it is the failure mode.

### A-series, ≤8192 class (canvas 3200 px long edge)

| input | mode | delivered_in | first_draw | 2nd draw same size | peak footprint | CPU | energy | layout |
|---|---|---|---|---|---|---|---|---|
| noise 8192×5461 PNG | A1 lazy+cache flags | 0.482 s | **0.507 s (decode)** | 0.002 s | **0.214 GiB** | 1.02 s | 5416 mJ | `.last` |
| " | A2 native thumbnail | 0.504 s | 0.062 s | 0.002 s | 0.502 GiB | 0.63 s | 3194 mJ | premultipliedFirst |
| " | **A3 bg materialize** | 0.498 s (materialize 0.495 s) | **0.058 s** | 0.003 s | 0.337 GiB | 0.63 s | **3020 mJ** | premultipliedLast |
| noise 6000×4000 PNG | A1 | 0.254 s | **0.279 s** | 0.002 s | 0.136 GiB | 0.59 s | 2915 mJ | `.last` |
| " | A3 | 0.267 s | 0.038 s | 0.002 s | 0.174 GiB | 0.35 s | 1745 mJ | premultipliedLast |
| noise 4032×3024 PNG | A1 | 0.132 s | **0.152 s** | 0.002 s | 0.097 GiB | 0.35 s | 1598 mJ | `.last` |
| " | A3 | 0.136 s | 0.028 s | 0.002 s | 0.104 GiB | 0.22 s | 1093 mJ | premultipliedLast |
| photo 4032×3024 JPEG | A1 | 0.038 s | **0.030 s (no decode)** | 0.002 s | 0.096 GiB | 0.11 s | 552 mJ | noneSkipLast |
| " | A3 | 0.059 s | 0.028 s | 0.002 s | 0.099 GiB | 0.11 s | 580 mJ | premultipliedLast |

**Verdict A (≤8192): A3 as the spec proposes.** Evidence:
- A1 pays the whole decode **inside the renderer's first draw** (0.15–0.51 s for PNGs; in the app that draw runs on
  QuartzCore's queue with the main thread blocked). JPEGs are the exception (0.030 s) — the stall is format-dependent.
- A1 with cache flags does **2× the work**: 0.482 s at create *and* 0.507 s at draw (CPU 1.02 s vs A3's 0.63 s;
  energy 5416 vs 3020 mJ). The create-time work is not reusable by the draw.
- A2 is not needed for ≤8192 (1.5× A3's peak footprint, different layout) and is prohibited for oversized.
- Extra finding: on the giant, `shouldCache`+`shouldCacheImmediately` were **non-deterministic** — 0 ms create in one
  run, 20.6 s create in another — so the spec's prohibition on relying on those flags is reinforced, not weakened.

### A-series / A5, oversized class

| input | mode | peak footprint | notes |
|---|---|---|---|
| grad 12000×9000 (1.9 MB file) | A1 native | 0.456 GiB | bitmap 412 MB |
| " | A2 native thumbnail | **1.204 GiB** (2.6×) | |
| " | A3 native materialize | 0.806 GiB (1.8×) | |
| giant 48000×32000 | A1 lazy+cache flags | **5.78 GiB** | 3 full decodes: 20.6 s create + 19.0 s draw + 18.1 s draw = 51.3 s CPU, **214 J** |
| giant | A2 native thumbnail | 7.453 GiB (measured earlier) | |
| giant | A3 native materialize | not run — arithmetic 2×5.86 GiB ≈ 11.7 GiB; the 2× ratio is confirmed by the 12000×9000 row |

**Verdict A (oversized): keep the ≤8192 bounded thumbnail and the prohibition on native materialization.** The
arithmetic sum (source bitmap + destination copy) exceeds what a 16 GB machine can hold without heavy swap; the
largest *measured* native-materialize transient (5.78 GiB from A1's own bitmap) already forced 2.6 GiB of swap.

---

## Gate B — preload / cache policy (decides §13.2)

Per-task accounting (CPU and energy measured inside each speculative task, so post-cancellation work is included).
`preHit` = navigations served by an entry a *preload* stored.

**normal set** (4032 PNG, 4032 JPEG, 6000 PNG, 8192 PNG; sequential 0→1→2→3, dwell 0.6 s):

| policy | lat p50 | hits | preHit | decodes | spec CPU | total energy | peak |
|---|---|---|---|---|---|---|---|
| B0 no preload | 0.151 s | 0 | 0 | 4 | 0 | 4648 mJ | 364 MiB |
| B1 2-neighbour, 384 MiB | 0.038 s | 3 | 3 | 1 | 0.81 s | 4731 mJ | 365 MiB |
| B2 cost-aware 384 MiB | **0.022 s** | 3 | 3 | 1 | 0.84 s | 4329 mJ | 365 MiB |
| B3 768 MiB | 0.036 s | 3 | 3 | 1 | 0.81 s | 4573 mJ | 366 MiB |
| B4 lower-level preload | **0.169 s** | **0** | **0** | 4 | 1.50 s | **9803 mJ** | 182 MiB |

For ≤8192 images preload is **energy-neutral** (4731 vs 4648 mJ) because the same decode happens either way; it only
moves it earlier and cuts navigation latency 4–7×.

**big3 set** (native bitmaps 256 + 170.7 + 196 = 622.7 MB, i.e. above the 384 MiB budget; sequential 0→1→2):

| policy | lat p50 | preHit | decodes | spec CPU | total energy | note |
|---|---|---|---|---|---|---|
| B0 | 0.546 s | 0 | 3 | 0 | 9271 mJ | |
| B1 | 0.062 s | 1 | 2 | 3.40 s | 17099 mJ | pays 3.4 s CPU / 14.9 J for an entry that is evicted before use |
| B2 | 0.056 s | 1 | 2 | 3.50 s | 16807 mJ | the cost gate cannot prevent the eviction of what it did preload |
| **B3 (768 MiB)** | 0.065 s | **2** | **1** | **1.07 s** | **9000 mJ** | energy-neutral vs B0 *and* 8× lower latency |
| B4 | 0.568 s | 0 | 3 | 3.46 s | 18790 mJ | strictly harmful |

**Verdict B: B3 (enlarged cache, ~768 MiB) + the oversized-preload prohibition.** B1/B2 are rejected *in the
budget-busting regime*: they burn ~1.8–2× B0's energy preloading entries that NSCache evicts before they can be used.
B4 is falsified outright (0 preload hits, latency worse than no preload, 2.1× B0's energy on the normal set).
B0 loses 4–7× latency for zero memory benefit.

Supporting cache measurements (E3, `cacheplan`):
- bounded design working set (8192 + 2×4096 = 256 MB) → **all entries retained** under 384 MiB.
- native 8192×8192 ×3 (768 MB) → all retained (NSCache tolerates overshoot; do not rely on it).
- current 8192×8192 + neighbour 8192×5461 (426.7 MB, just over budget) → **the current on-screen entry was evicted**
  while the neighbour survived. Order-dependent eviction of the visible image is the failure to design out.
- memory-pressure purge keeps the current entry (existing semantics work).
- cancelled giant decode: 62.8 J / 19.4 s still consumed → oversized preloads must never be started.

---

## Gate C — dimension/oversized detection (decides §14)

| scenario | policy | cost | probes | misclassified |
|---|---|---|---|---|
| 5000 small PNGs | C1 eager | 0.373 s | 5000 | 0 |
| " | C2 on-demand (20 visible) | 0.002 s | 20 | 0 |
| " | C3 byte filter | 0.380 s | 5000 | 0 (no file was above threshold) |
| 30 giant clones (APFS COW) | C1 eager | 0.002 s | 30 (0.71 ms each) | 0 |
| 30 giant clones | C2 | 0.001 s | 20 | 0 |
| mixed (5 files incl. adversarial) | C3 one-way (>64 MB ⇒ oversized) | ~0 | 3 | **2/5** |
| mixed | C4 two-way (unsound) | ~0 | **0** | **5/5 (never probed)** |

**Byte size is unsound in both directions** — the two adversarial fixtures prove it:
`noise-8192x5461.png` is **148 MB but not oversized**; `solid-12000x12000.png` is **2.5 MB but oversized**.

**Verdict C: drop C3. Use C1 or C2 (both sound).** Header probing costs 0.08 ms/file for small files and 0.71 ms for
1.9 GB files (warm page cache); 5000 files = 0.373 s, which is acceptable if it stays off the main thread (the app
already does this in `FolderScanner` for dimension sorting). C2 is ~200× cheaper still but needs async coordination.
Byte size may be used only to *order* probes, never to decide.

---

## Gate D — minification quality / mipmaps (decides §9.4)

Offscreen, deterministic. `shimmer` = RMS between two sub-pixel offsets (aliasing instability, lower is better);
`rmse_ref` = RMS against the Quartz `.high` area-average render. Sanity check: at scale 1.0 both Metal variants match
Quartz (rmse 0.32), so the harness itself is not biased.

Real 8192×5461 photo (this is a detail-rich image; the reference's own shimmer is high, so compare ratios):

| minification | variant | rmse_ref | shimmer | shimmer vs Quartz | detail | GPU ms |
|---|---|---|---|---|---|---|
| 1.7× | Quartz `.high` | 0 | 11.41 | 1.00× | 22.8 | – |
| 1.7× | D1 bilinear no-mip | 11.55 | 17.42 | **1.53×** | 39.0 | 1.24 |
| 1.7× | D2 mipmapped | **6.67** | **11.90** | **1.04×** | 25.0 | 1.23 |
| 3.7× | D1 | 12.01 | 20.85 | **1.93×** | 30.0 | 2.62 |
| 3.7× | D2 | **6.19** | **9.21** | **0.85×** | 13.2 | 0.51 |
| 11.3× | D1 | 8.16 | 11.89 | **2.61×** | 7.05 | 1.15 |
| 11.3× | D2 | **2.88** | **4.01** | **0.89×** | 2.46 | 0.49 |

1-px checkerboard (pathological): D1 shimmer 4.5–54.7 vs reference 0.47–1.32 (up to **41×**), D2 0.76–13.1.

**Verdict D: mipmaps are mandatory, not optional.** D1 is 1.5–2.6× the current Quartz path on real content (up to 41×
on pathological content) with inflated high-frequency detail — a visible regression against today's renderer. D2 is at
parity or better and is *faster* on the GPU (smaller mips are cache-friendlier). Cost: +33 % texture memory
(227 vs 170.7 MiB at 8192) and 3–7 ms one-time generation.

---

## Gate E1 — bucket base formula (decides §5.3)

Computed over 5 real window geometries × 5 image shapes (E1a = `max(canvasW,canvasH)`; E1b = displayed-image size):

- **E1a can never undersample** (its requirement is ≥ E1b's by construction).
- E1a's extra density is **zoom headroom before a level change** (which costs a full ~18 s decode): 2.1–8.2 texels/px
  at Fit vs E1b's 1.5–2.0 — i.e. E1a tolerates 2–8× zoom, E1b only ~1.5×.
- Memory difference: identical at full screen (both hit the 8192 ceiling); up to **16×** in short-wide windows
  (E1a 8192 = 170.7 MB vs E1b 2048 = 10.7 MB; footprint 0.756 vs 0.098 GiB); 4× in the default window.

**Verdict E1: keep E1a (the spec's formula).** My earlier "over-allocation" reservation is refuted by the data: the
extra density buys zoom headroom, and without a cheap level-upgrade path (none in this iteration — every level change
is a full stream decode) headroom is worth more than 10–160 MB of bitmap. E1b is only advisable once a cheap upgrade
path exists.

---

## Gate E2 — resize / backing-scale level stability

Derived from measured costs (no new run needed):
- With R4, **only oversized sources have levels**; a ≤8192 source is always native → resize/backing-scale changes are
  free for it.
- For oversized sources, crossing a bucket boundary (e.g. default window 4096 → full screen 8192) requires a new
  bounded decode: **18.1–18.5 s, uncancellable** (measured for every bucket). An "immediate recompute on resize"
  policy therefore risks multi-second freezes during a window drag.

**Recommendation: debounce (~300 ms after resize ends) + upgrade only when the current bucket is undersampled
(texel/px < 1) + never during an active drag; keep showing the current bitmap until the new one is ready.** This is a
UX policy decision that the data constrains but does not uniquely determine; it must be written into §9.5/§5.3.

---

## Gate E4 — app-level budget (baseline captured; pass/fail needs the implementation)

Instrumented `123d943` app copy, opening the giant with drawer + navigator visible:

| metric | baseline |
|---|---|
| full-stream traversals | **4** (canvas rasterization ×2, navigator preview ×1, sidebar 300 px thumbnail ×1; a plain open without the forced redraw = 3) |
| open energy | **136.6 J** |
| main-thread stall (max pulse latency) | **20.9 s** |
| peak RSS | 6.885 GiB |
| peak footprint (sampled at finish) | 5.17 GiB (true peak 5.86 GiB measured earlier) |
| time to published image (T5) | 0.239 s (the image is lazy — that is the trap) |

Post-fix targets: traversals **== 1**, main-thread stall p95 **< 100 ms**, open energy **≈ one bounded decode
(~60 J)**, no `Image IO` region > 1 GiB, RSS expected to stay ~2–2.7 GiB (mmapped source).

---

## Gate D6 — proxy magnification

Proxy = high-quality downsample of the source; rendered at N× and compared against the original pixels (truth).

| case | magFilter | RMSE vs truth | blockiness | detail (Laplacian) |
|---|---|---|---|---|
| photo, 4× | nearest | 24.61 | 0.0218 | 15.50 |
| photo, 4× | linear | **22.90** | **0.0000** | 2.26 |
| investigation proxy, 6× (= the real 5.86 source px per texel) | nearest | 34.49 | 0.0563 | 13.69 |
| " | linear | **31.78** | **0.0013** | 1.93 |
| fine lines, 4× | nearest / linear | 112.56 / 112.52 | 0.0010 / 0.0000 | 0.16 / 0.06 |
| 1-px checkerboard, 4× | nearest / linear | 112.50 / 112.50 | 0.0000 / 0.0000 | 0.06 / 0.06 |

**Verdict: linear magnification.** Nearest loses on every measured axis — it is further from ground truth *and* adds
2.2–5.6 % hard-edge pixels (a visible block grid). Its higher Laplacian is the grid, not detail. No content class
measured favours nearest. The lever at high zoom is a level upgrade, not the filter.

## Gate E5 — animation frame path

1 MPixel, 30-frame GIF, 20 s window, instrumented app:

| metric | measured |
|---|---|
| frames drawn | 313 → **15.9 fps** (nominal 25 fps at the 40 ms GIF delay) |
| frame period | p50 56 ms, p95 121 ms, max 137 ms, stdev 29.5 ms |
| main-thread ping | p50 26 ms, **p95 98 ms**, max 107 ms |
| energy | 78.1 J over 20 s = 3.9 W = **249 mJ per drawn frame** |
| memory | footprint 0.185 GiB, RSS 0.280 GiB |

**Verdict: frame decoding stays off the main thread and does not blow up memory, but the animation path is not free
(64 % of nominal speed, ~4 W, ping p95 at the 100 ms boundary).** Recorded as a non-regression baseline; giant
animations stay out of scope for this iteration.

## Net changes the data implies for spec v2

1. **§5.1**: keep A3; add "cache flags are non-deterministic and must not be used" (measured 0 ms vs 20.6 s on the
   same input) and "materialization must be observable, not a self-reported flag" (A6 test).
2. **§13.2**: pick **B3** with a bounded budget (~768 MiB) — and record that B1/B2 are *energy-harmful* above the
   budget (1.8–2× B0) while B4 is strictly harmful. §13's "unresolved" can be closed.
3. **§14**: **drop C3** as unsound in both directions; choose C1 or C2; byte size only orders probes.
4. **§9.4**: mipmaps become **unconditional** (D1 falsified: 1.5–2.6× worse than the current Quartz path on real
   content, up to 41× on pathological content).
5. **§5.3**: keep E1a; document the 16× worst-case waste in short-wide windows as accepted (it buys zoom headroom).
6. **New**: §9.5 must state the resize/debounce policy (E2) — currently absent.
7. **Closed after the first pass**: proxy magnification (D6 → linear) and the animation frame-path check (E5 →
   baseline recorded, non-regression required). Only E4's post-implementation run remains, and it is inherently a
   property of the change itself.

## Reproduce

```bash
cd /tmp/piclight-bench/gen && ./gen make noise-8192x5461.png      # decisive A/D fixtures
cd /tmp/piclight-bench/PicBench
./picbench matbench /tmp/piclight-bench/fixtures/noise-8192x5461.png --mode a1|a2|a3
./picbench cacheplan
./picbench preloadbench --set normal --workload 0,1,2,3 --canvas 4096 --dwell 0.6
./picbench preloadbench --set big3   --workload 0,1,2   --canvas 4096 --dwell 0.8
cd /tmp/piclight-bench/probebench && ./probebench <folder> --policy c1|c2|c3|c4
cd /tmp/piclight-bench/minbench  && ./minbench <image> --pattern checker --scales 1.7,3.7,11.3
cd /tmp/piclight-bench/app-bench && PICLIGHT_TTI_BENCH="<PNG>" ./.build/release/PicViewMac
```
