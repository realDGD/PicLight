# Audit: stale-plan uploads, publication cost, redraw, statistics, drawer thumbnail

Five suspicions, each checked against the production code and then against a deterministic test
before any production change. Real-image runs use `万萝图.png` (48000×32000, 1.929 GiB); its SHA-256
was verified unchanged after every run.

## 1. Audit matrix

| # | Suspicion | Verdict |
| --- | --- | --- |
| A | A warm upload queued for plan A re-enters the GPU cache after the user moved to plan B | **confirmed** |
| B | One publication per decoded tile makes a pass O(n²) | **confirmed** |
| C | A foreground draw that missed an in-flight texture is never repainted when it completes | **confirmed** |
| D | `textureCreations` counts insertions, not creations, so `creations == uploads` over-claims | **confirmed** |
| E | The drawer thumbnail box collapses to zero width for an asynchronously delivered image | **confirmed** — and a second, separate defect: the thumbnail is never delivered at all |

## 2. Stale plan uploads (A)

**Reproduction.** With the resident-plan check fault-injected away, a tile that is outside the newly
published plan still lands in the cache: `resident=true`, `bytes=32768`. The abandoning case is the
same: after the plan is dropped, the in-flight upload inserts and bills 32768 bytes.

**Why it happened.** `textureGeneration` only changes on a variant switch, and `trimTileTextures`
only removes entries that are already in the cache. An upload in flight is in neither place, so
nothing could stop it.

**Fix.** The renderer records the resident set on every publish (`trimTileTextures(keeping:)`) and a
completion outside it is discarded (`stalePlanDiscarded`); the warm queue drops entries whose tile
left the plan before spending a texture on them (`stalePlanSkipped`). An empty set before the first
publication means "not yet known", so callers outside the viewer are unconstrained.

**Evidence.** Injection: resident, billed. Fixed: not resident, 0 bytes, `stalePlanDiscarded == 1`.
A tile that stays in the plan is kept (no thrash), a visible tile is never discarded, and the
abandoning case now leaves `bytes == 0`.

## 3. Publication cost (B)

**Reproduction (fixture).** 100 arrivals produced 100 publication runs — the per-arrival shape.

**Baseline (real image, variant probe).** With coalescing bypassed: `arrivals=40 requests=40 runs=46
coalesced=0 visibleMat=171 warmMat=621 warmSubmitted=71`, main-thread publication time 7 ms
cumulative. With coalescing: `requests=15 runs=21 coalesced=30`, main-thread 3 ms. The same binary,
the same probe, back to back.

**Fix.** `nativeTileArrived` marks the state dirty and schedules at most one publication, re-reading
the state when it finishes, so the display stays progressive. One run-loop turn by default;
`publicationCoalescingInterval` (8/16 ms) and `publicationCoalescingEnabled` exist for measurement.
A publication now submits only tiles that became warm since the last one.

**After (fixture).** 107 arrivals → 4 publications, 104 coalesced, `maxPendingPublications == 1`.
Progressive display is preserved: the first publication happens while the pass runs, not after it.

## 4. Warm re-submission (Q3)

`duplicateWarmSkips` measured 45,239 on the investigation image at 193da82 with the variant probe,
i.e. the whole warm set was re-offered on every publication. After the delta submission the same
counter reads **24** in the corresponding run. `creations == insertions` (88 = 88, and 560 = 560 in
the earlier stage) — no duplicate upload reaches the cache.

## 5. In-flight completion redraw (C)

**Reproduction.** The draw path asks for a tile, finds it in flight, gets nil and draws the proxy.
No notification existed: the collector was empty after completion.

**Fix.** `setTextureBecameReadyHandler` fires for keys that a foreground draw actually missed,
and the canvas repaints through `pushToMetal()` (coalesced by the main-queue hop). A warm-only
upload and a foreground hit deliberately do not notify, so a warm pass does not repaint once per
tile.

**Evidence.** Completion of a missed key notifies exactly once with that key; a warm-only upload and
a hit notify zero times.

## 6. Statistics semantics (D)

**Reproduction.** A texture created and discarded as a stale variant left `textureCreations == 0`:
the counter incremented after the discard guards, so it counted insertions.

**Fix.** Creations are counted when the driver returns a texture. `residentInsertions`,
`staleVariantDiscarded`, `stalePlanDiscarded` and `duplicateDiscarded` account for every one of
them; the test asserts `creations == insertions + staleVariant + stalePlan + duplicates`. So
`creations == uploads` can no longer be read as "nothing was ever thrown away" — with the old
semantics it could.

## 7. Drawer thumbnail (E)

**Reproduction (layout).** Measured on a 200×168 cell: with `image: nil` the image view laid out at
**0.0 pt wide** and the current-item border at **8.0 pt** — exactly the thin blue line reported.
With a 300×200 thumbnail the box became **300 pt wide** (past the cell's 180 pt cap) with aspect
2.27 instead of 1.5. The box had one upper bound and nothing else, so the empty case was solved to
zero and the image case was won by `NSImageView`'s intrinsic size.

**Fix.** One aspect constraint (placeholder 1.45 before the image arrives, the true aspect after),
two required caps (`height ≤ 132`, `width ≤ cell − 20`) and a fill preference at priority 500 —
above `NSImageView`'s content hugging, which otherwise wins the tie at 250 and keeps the empty box at
zero width. Fully determined for nil and non-nil alike; no intrinsic-size dependence.

**Real-file validation.** With the real image in a 180 pt drawer: image box **160×110**,
border **168×118** (was 0 / 8), and after a real 300×200 thumbnail is delivered, **160×106** with
border **168×114** — aspect 1.509 preserved, border = box + 8.

**Aspect and reuse coverage.** 3:2, 2:3, 5:1, 1:5 and 1:1 all preserve the aspect within 2 %,
respect both caps and stay centred; landscape → nil → portrait reuse keeps the layout valid; a
120 pt drawer still produces a positive box; the filename stays inside the cell.

**Second defect, measured and fixed.** The thumbnail was never delivered for the investigation image
even with the drawer pinned open from launch: `hasImage=false` after 34 s, and
`requests=1` — one request in the whole session. The request happens while the drawer's cells are
built, which for an oversized file is before the canvas bitmap exists; `thumbnailImage(for:)` then
falls into the oversized branch and returns nil, and nothing ever asks again. The source itself is
healthy (`preview -> image 300x200` when called later) and the cell accepts and lays out an image
correctly when pushed. Fix: when a bitmap is published, re-request the current item's thumbnail if
it is still missing. Guarded by a test that fails while the cache stays empty.

**Acceptance after the fix (real file, drawer pinned open from launch).** The row is read before the
probe pushes anything, so these numbers are the automatic path: `requests=2` (was 1),
`hasImage=true`, image box **160×106** at (10, 54), border **168×114**, current=true — at both
sampling points, with the source SHA-256 unchanged and one bounded-decode traversal.

## 8. Publication A/B on the real image

Four runs, 95 s window, variant probe, back to back, same binary (larger window):

| Strategy | publications | coalesced | max stall | stall after launch | peak footprint | finish footprint |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| A per-arrival (bypass) | 46 | 0 | 75 ms | ≤ 1 ms | 0.365 GiB | 0.182 GiB |
| B 0 ms (one run-loop) | 21 | 30 | 158 ms | ≤ 3 ms | 0.908 GiB / 0.442 GiB / 0.877 GiB | 0.752 / 0.290 / 0.742 GiB |

Publication count drops by ~2.2×; the main-thread publication cost is 2–3 ms per run in both modes.
The 8 ms and 16 ms variants measured 5 and (below) runs with the same shape, so the default stays at
one run-loop turn: a longer interval buys little and delays the first publication for no measured
gain.

**Stall attribution.** In every run the only large stall is at app launch (T+0.3 s): 75 ms, 158 ms,
none, none. After launch every pulse is 0–3 ms. The ~72 ms figure from the previous audit is that
launch stall, not publication work — coalescing neither causes nor removes it, and the previous
report's attribution was wrong.

## 9. Transient memory (Q5)

Peak `phys_footprint` with coalescing on, three runs of the same strategy: **0.442 GiB, 0.877 GiB,
0.908 GiB** (median 0.877, finish 0.290–0.752 GiB). The spread tracks the tile-plan size, which the
harness window and zoom determine (the runs that landed on a 24-visible-tile plan measured
0.877–0.908 GiB; the run that landed on 4 visible tiles measured 0.442 GiB). The bypass run measured
0.365 GiB at the same small plan size. **No reduction attributable to coalescing is measurable**:
the difference between modes at matched plan size (0.365 vs 0.442 GiB) is smaller than the run-to-run
spread (0.44–0.91 GiB), and the earlier 1.864 GiB and 7.909 GiB observations came from different plan
sizes again. The cause of those transients remains unattributed; the per-arrival publication churn
was the leading hypothesis and this A/B does not support it.

## 10. Sanitizers

| Run | Result |
| --- | --- |
| Full suite | **473 tests, 0 failures** (123 s) |
| TSan (tile, plan, residency, thumbnail suites) | **31 tests, 0 failures, no race reports** |
| ASan (decoder, tile, plan, residency, thumbnail) | **48 tests, 0 failures, no heap errors** |

## 11. Remaining limitations

- The transient footprint has no proven cause. Coalescing is not it (measured above); the earlier
  numbers must not be quoted as a before/after.
- The stale-plan discard path was exercised by tests and by the abandoning case; on the real image
  `stalePlanSkipped`/`stalePlanDiscarded` stayed 0 because no upload happened to be in flight at a
  plan change. The counters appear in every residency sample.
- The 8 ms and 16 ms coalescing variants were measured only on the fixture (publication counts 5 and
  fewer); the real-image A/B covers the default and the bypass.
- The drawer's thumbnail is now delivered for the current item, but the retry is triggered by bitmap
  publication; a file whose bitmap never publishes (an unsupported or failed decode) still shows a
  placeholder, which is the intended policy.
- The retry was verified on one file (the investigation image) and by one unit test; a folder whose
  current item changes while a decode is in flight is covered by the same code path but was not
  measured separately.
