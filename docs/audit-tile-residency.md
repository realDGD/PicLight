# Tile residency audit — the six suspected defects

Scope: the tile-texture cache and warm-upload path added for large images
(`MetalImageRenderer`, `ImageCanvasView`, `ViewerViewController`, `NativeDetailScheduler`).
Method: read the production code, then write a test that *fails* if the suspicion is real — the
guard tests run twice, once with fault injection that restores the pre-fix path (which must fail the
invariant, proving the test detects the bug) and once on the shipping path. Nothing outside this
subsystem was touched: no gutter work, no new large-image architecture, no UI.

Image for the real-image runs: `万萝图.png`, 48000×32000, 1.929 GiB, SHA-256 unchanged before and
after every run (`119b1ec4…84fb5d`).

## 1. Audit matrix

| # | Suspicion | Verdict | Evidence |
| --- | --- | --- | --- |
| A | One tile uploaded twice when the draw path and the warm queue race | **Confirmed** | Fault-injected legacy path: 2 textures created for one key, 65536 bytes billed for a 32768-byte tile, the key appended to the LRU twice. Fixed path: 1 creation, 1 billing, 1 in-flight skip. |
| B | A mip-variant upload in flight during a variant switch resurrects the dropped flavour | **Confirmed** | Fault-injected: after `dropTileTextures(of: .mipmapped)` during an in-flight mip upload, the entry is resident again and billed. Fixed path: not resident, 0 bytes, `staleDiscarded == 1`. |
| C | `protectedTileKeys` written unlocked on the main thread, read under the cache lock | **Confirmed** | Code: `public var` wrote from `nativeTiles.didSet`, read in `evictTileTexturesIfNeededLocked`. Fixed with a locked setter; TSan clean on a stress test (400 setter calls against a 24-tile background uploader) and on the real viewer path. |
| D | Hits counted across both callers, so a pan report overstates draw-path hits | **Confirmed** | One `hits` counter for both callers. Split into `foregroundHits` / `backgroundHits` (and `foregroundUploads` / `backgroundUploads`, `inFlightSkips`, `staleDiscarded`, `duplicateWarmSkips`, `textureCreations`). Test: a warm hit leaves `foregroundHits` unchanged. |
| E | Billing an estimate rather than the driver's allocation | **Confirmed, with a twist** | `allocatedSize` *is* available and is page-rounded, so it is larger than the surface: 64×64 base 32768 (surface 16384), 64×64 mipmapped 32768 (estimate 21845 — the mip chain fits inside the padding), 512×37 edge 147456 (surface 75776), 512×512 production 1064960 (surface 1048576, one page more). The cache now bills `allocatedSize`; the estimate stays for planning and is labelled an estimate. |
| F | `nativeDetailCacheCountForTesting` reported the drawn tile count | **Confirmed** | The property returned `nativeDetailTileCount`. Now `nativeDetail.cache.count`; a test asserts it equals the cache's own count and `diagnostics.cpuCacheTiles`, and the E4 trace prints the corrected value. |

## 2. The seven invariants

1. **One upload per tile key.** The in-flight set admits a single uploader per key; the loser is told
   to keep drawing the proxy rather than blocking the main thread.
2. **No stale insertion.** An upload that began before a policy change (generation bump) is discarded
   on completion and counted in `staleDiscarded`.
3. **Billed once.** `sum(entry cost) == tileTextureBytes`, each resident entry billed exactly once, at
   `MTLTexture.allocatedSize` and never below the surface size.
4. **LRU consistency.** `Set(order).count == order.count` and `Set(order) == Set(resident keys)`.
5. **Protection.** Protected (visible) tiles survive budget eviction; after unprotecting, the budget
   applies again and the bytes come back down to it.
6. **Attribution.** Hits and uploads are counted for the caller that caused them.
7. **Honest diagnostics.** The reported cache count is the cache's, not the draw list's.

## 3. Changes

- `MetalImageRenderer`: in-flight set, texture generation, warm-queue set, private
  `protectedTileKeys` with a locked setter, split counters, `textureCreations`, `byteCost(of:)` using
  `allocatedSize`, `TileTextureDiagnostics` struct with an LRU-consistency field, locked test hooks.
- `ImageCanvasView`: uses `setProtectedTileKeys`, returns the diagnostics struct.
- `ViewerViewController`: split GPU counters, `gpuTextureCreations`, `gpuLruConsistent`,
  `nativeDetailCacheCountForTesting` reads the cache.
- Tests: `PicViewMacTests/TileTextureInvariantTests.swift` (7 tests) + one added to
  `WarmResidencyTests`; the fault-injection switches live behind lock-protected setters.

## 4. Test results

| Run | Result |
| --- | --- |
| Full suite (`swift test`) | **455 tests, 0 failures**, 122 s; plus the 7 invariant tests and the added residency test |
| TSan (`--sanitize=thread`, tile + residency + native-detail suites) | **24 tests, 0 failures, no race reports** |
| ASan (`--sanitize=address`, decoder + tiles + residency + orientation + policy) | **44 tests, 0 failures, no heap errors** |

## 5. Real image: residency and the 0.8 → 1.2 → 0.8 switch (E4, windowed)

Physical scale 0.8 → 1.2 → 0.8 → 1.2, samples ~2.5 s after each switch:

| Sample | visible | warm | CPU cache | GPU resident | creations = uploads | hits (fg) | stale | LRU |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | --- |
| switch 1 (1.2) | 45 | 25 | 70 (70 MiB) | 70 (71 MiB) | 70 = 70 | 87 | 0 | consistent |
| switch 2 (0.8) | 91 | 129 | 220 (220 MiB) | 141 (191 MiB) | 390 = 390 | 132 | 0 | consistent |
| switch 3 (1.2) | 45 | 125 | 220 (220 MiB) | 170 (172 MiB) | 560 = 560 | 223 | 0 | consistent |
| pan (1 viewport) | 35 | 75 | 220 (220 MiB) | 110 (111 MiB) | 580 = 580 | 293 | 0 | consistent |

- `creations == uploads` at every sample: no texture was created and thrown away on the real path.
- `stale == 0`: no upload happened to be in flight at the switch instants, so the discard path was
  not exercised here; the deterministic test covers it.
- Bytes stay inside the 192 MiB GPU budget at every sample (191 MiB peak, i.e. 100.3 % of budget
  before eviction settles).
- The one-viewport pan cost 20 new creations and 10 synchronous uploads for 70 new foreground hits:
  the tiles that became visible were already resident on the GPU.

## 6. Continuous drag: what the direction hint is worth

40 drag steps of half a viewport (1200 px) across the 48000-pixel source at physical scale 1.0,
uploader drained at a fixed number of tiles per step. Plan-level simulation, deterministic:

| Upload rate | Hint off | Hint on | Difference |
| --- | ---: | ---: | ---: |
| 8 tiles/step (uploader is the bottleneck) | 287 hits / 625 sync uploads (31.5 %) | 438 / 474 (48.0 %) | **+16.5 points, −151 synchronous uploads (−24 %)** |
| 40 tiles/step (queue keeps up) | 851 / 61 (93.3 %) | 848 / 64 (93.0 %) | −0.3 points, i.e. nothing |

The hint earns its place only when the uploader is the bottleneck. Reported as measured; it is not a
general speedup.

## 7. Where the first-visible latency goes

Per-tile GPU phases on the real image, measured on the decoded tile: context draw 0.25 ms,
`replace` 0.09 ms, texture create 0.01 ms — **0.35 ms per tile in total**. The first tile of a plan,
however, costs 1452 ms when the viewport is near the top of the image (y = 1760) and 9323 ms near the
middle (y = 15200), because a PNG row filter chain cannot reach row *n* without decoding rows
0…*n*−1. The latency is decode progress, not upload.

Main-thread stalls in the windowed probe run: max **72 ms** at T+34.9 s, 0.3 s after a 1.2 → 0.8
scale switch; next worst 12 ms; everything else ≤ 1 ms. The worst stall is the scale-change plan
publication on the main thread (plan rebuild + `publishNativeTiles` + `trimTileTextures` over ~220
keys), not a tile upload.

## 8. Two findings the audit's own counters produced (not fixed here)

1. **Per-arrival publication.** `nativeTileArrived()` is called for every decoded tile, and each call
   runs `refreshPublishedSets`, which materialises the visible, warm and resident sets and re-warms
   the whole warm set. `duplicateWarmSkips` reached 45 239 in an 86 s run (174 k in another), i.e.
   the same warm tiles are re-offered tens of thousands of times. The dedup absorbs it (no duplicate
   uploads — see `creations == uploads`), but the work is O(tiles²) per plan pass and each pending
   publication retains an array of tiles. Coalescing arrivals into one publication per run-loop turn
   is the identified fix; it changes publication timing, so it needs its own regression pass and was
   deliberately left out of this audit.
2. **Unstable transient footprint.** The same probe sequence produced `peakFootprint_sampled` of
   7.909 GiB in one run and 1.864 GiB in another (footprint at finish 0.69 / 1.37 GiB, no-probe
   baseline 0.987 GiB peak). The tile caches stayed inside their budgets throughout (CPU 220/256 MiB,
   GPU 191/192 MiB, LRU consistent), so the transient is outside them. The publish backlog in (1) is
   the only mechanism found that scales with pending work, but it is not proven. Also fixed on the
   harness side: `peakFootprintSeen` was written on the heartbeat thread and read unlocked in
   `finish()`, and it once reported 0.199 GiB for a run whose own pulse lines showed 3.5 GiB; it is
   now read and written under a lock.

## 9. Acceptance numbers (windowed probe run, 95 s)

`full_stream_traversals = 1` (bounded decode 8192), `peakRSS = 2.771 GiB`,
`footprint_at_finish = 1.367 GiB`, `peakFootprint_sampled = 1.864 GiB`,
`main_thread_stall_max = 72 ms`. The still-image run (3 draws, no probes) measured
`open_energy = 66.8 J`, `footprint_at_finish = 0.231 GiB`, peak RSS 2.088 GiB, stall max 528 ms — the
energy figure covers the open path only, which is why the windowed run's 287 J (95 s of continuous
tile work) is not comparable to it.

## 10. Not claimed

- The discard path was not exercised on the real image (no upload in flight at the switch instants);
  it is proven by the deterministic test only.
- The transient footprint has no proven mechanism, and the fix proposed in §8.1 is not applied.
- The direction hint is not a general speedup; it only helps a saturated uploader.
