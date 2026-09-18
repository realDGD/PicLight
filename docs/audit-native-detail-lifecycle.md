# Audit: native-detail lifecycle, thumbnail retry/cache, selection-card geometry

Six suspicions. Four are confirmed and fixed (A, B, C, E); two are confirmed by measurement and
deliberately left for a single follow-up change (D, F). Real-image work uses `万萝图.png`
(48000×32000); SHA-256 unchanged.

## 1. Audit matrix

| # | Suspicion | Verdict |
| --- | --- | --- |
| A | No current item leaves native-detail state behind | **confirmed** — 12 resident textures, 12 cached tiles after the last item went away |
| B | `WarmAreaPolicy.plan == nil` leaves the old plan and pass alive | **confirmed** |
| C | A successful thumbnail completion leaves `thumbnailRetryQueued` set | **confirmed** |
| D | Thumbnail cache unbounded / stale after a file is replaced | **confirmed** (both parts), measured, **not fixed this round** |
| E | Selection background covers the whole row | **confirmed** — card was 164 of 168 pt |
| F | Identical plan/source still bumps the generation | **confirmed as churn** (generation +3, **requests +3**), no canvas fallback; **not fixed** |

## 2. Empty-current Native-detail Audit

`loadCurrentImage`'s missing-item branch cleared the canvas image and returned: the plan stayed set,
the scheduler's pass kept running, its tile arrivals kept scheduling publications, and its textures
stayed resident. Measured before the fix: `plan=true`, 12 resident textures, 12 CPU-cached tiles,
and a stale arrival still advanced the publication counter.

After the fix (`clearNativeDetail()`): real image, last item removed while native detail was active —

| | before | after (1 s) | after (4 s) |
| --- | --- | --- | --- |
| plan | true | false | false |
| canvas tiles | 15 | 0 | 0 |
| published resident keys | 112 | 0 | 0 |
| CPU cache tiles | 112 | 0 | 0 |
| GPU resident tiles | — | 0 | 0 |

## 3. Warm-plan Nil-path Audit

`WarmAreaPolicy.plan == nil` (degenerate geometry) published an empty draw list and returned, leaving
the previous plan and its pass running. It now takes the same disable path. Verified with a
zero-zoom viewport: plan cleared, CPU cache purged, resident set empty.

## 4. Unified Disable/Cleanup Fix

One owner, `clearNativeDetail()`: cancel the debounce, invalidate the generation (via
`setDetailPlan(nil, source: nil)`), clear the plan and draw list, clear the warm submission state,
reset the motion hint, and stop-and-purge the scheduler. Four call sites now use it — missing current
item, unusable warm plan, proxy-resolves-the-screen, and the new-image path — instead of four
hand-written variants, two of which were incomplete.

## 5. Thumbnail Retry-state Audit

`finishThumbnailRequest` returned from the success branch *before* consuming
`thumbnailRetryQueued`, contradicting its own comment. A retry queued for "this item had no bitmap
yet" could therefore survive a successful completion and fire later against a request that had
already been answered. Any completion now consumes the queued entry first. Verified with a request
for an uncached file that succeeds: `retryQueued` goes 1 → 0, and `maxConcurrentPerURL` stays 1.

## 6. Thumbnail Cache Lifecycle Audit

By inspection: `thumbnailCache: [URL: CGImage]` — no byte budget, no count limit, no LRU, no folder
cleanup, and the key is the URL alone, so a replaced file keeps its old thumbnail.

Measured per-entry cost through the real request path: **~13 KB per entry** at the drawer's 300 px
thumbnail size (12 entries / 138 KB in the fixture folder; a folder of 5000 files would extrapolate
to roughly 65 MB, which is the basis for a budget rather than a guess).

Not fixed this round, on purpose: the two parts need one change (key the cache by URL plus file
identity, and bound it), and doing half of it — bounding without identity, or identity without
bounding — would leave the other defect in place.

## 7. Selection-background Geometry Reproduction

`selectionBackground` was bound to the cell (`leading +6 / trailing −6 / top +2 / bottom −2`), so it
was a row background by construction. Reproduction before the fix: for a 3:2 thumbnail the card drew
164 pt of a 168 pt row — the band of empty selection colour in the screenshot.

## 8. Selection Geometry Fix

The card wraps the image box plus padding plus a fixed filename slot (`thumbnailHeight` 132,
`filenameSlotHeight` 18, `cardPadding` 8), so it hugs the content and cannot jump when the filename
is hidden on hover. Real image, row 0: image 160×106, border 168×114, **card 176×140 at (2, 28)**,
label 168×14 at (6, 36) — the label inside the card, and 140 = 106 + 8 + 8 + 18 exactly.

## 9. Same-plan Generation/churn Measurement

Three identical viewport assignments, measured through the real viewer:

```
SAMEPLAN generationDelta=3 requestDelta=3 planStable=true tilesBefore=5 tilesAfter=5 sawEmptyCanvas=false
```

So a repeated identical update does not merely bump the generation: it starts three direct requests
for a plan that has not changed. It caused no visible fallback (`sawEmptyCanvas=false`, tiles
unchanged), which is why it is classified as churn rather than a correctness bug. A safe fix has to
keep the generation's meaning — an update that changes bitmap or source metadata must still
invalidate in-flight work — so it needs an explicit equality contract over
plan + source + bitmap/metadata identity. Not attempted here.

## 10. Automated Tests

| Suite | Added |
| --- | --- |
| `NativeDetailLifecycleTests` | 6: missing item clears everything (+ stale arrival does not publish), unusable plan clears, arrivals without a plan do not publish, successful completion consumes the retry, cache growth measurement, identical-update measurement |
| `ThumbnailCellLayoutTests` | 4: card wraps content for five aspects, hover stability, async arrival, cell reuse |
| Full suite | **498 tests, 0 failures** (142 s) |

## 11. Resource Measurements

- Native detail after the last item is removed: CPU cache 112 → **0** tiles, GPU resident 112 →
  **0** keys, canvas 15 → **0**.
- Thumbnail cache: 12 entries / 138 KB for the fixture folder, ~13 KB per entry.
- Identical-update churn: 3 extra direct requests for one unchanged plan.

## 12. TSan / ASan

TSan: **38 tests, 0 failures, no race reports**. ASan: **45 tests, 0 failures, no reports**. One
run of the ASan set failed `WarmResidencyTests/testPublicationsHappenDuringThePassNotAfterIt`, which
passes in isolation: a timeout under the sanitizer's batch load, not a memory report. Its wait budget
was raised (the assertion is about ordering, so a generous wait is correct) and the set is clean.

## 13. Real-file Validation

`万萝图.png`, drawer from launch, item switches, and the last item removed while native detail was
active: card 176×140 hugging a 160×106 thumbnail with the label inside it; empty state all zeros as
tabulated above; SHA-256 unchanged.

## 14. Remaining Limitations

- D (thumbnail cache budget and file identity) and F (identical-plan churn) are confirmed and **not
  fixed**; each needs one change that this round did not make.
- The thumbnail cache measurement covers one fixture folder (12 entries); the 5000-file figure is an
  extrapolation from the measured per-entry cost, not a measurement.
- The selection card was verified by frame geometry and on the real image, not by a rendered
  screenshot (`judge` was not used for this UI change).
- The `E` fix changes the visual size of the selection highlight for every shape; only the geometry
  contract is asserted.
