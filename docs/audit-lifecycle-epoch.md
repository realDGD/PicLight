# Audit: native-detail lifecycle epoch, branch coverage, selection card, stale diagnostics

Nine suspicions. Confirmed and fixed: A (a late cleanup could kill the pass that replaced it),
B (a test that claimed to cover the unusable-warm-plan branch never reached it — coverage defect,
production code correct), C (a portrait thumbnail's filename hung outside the selection card),
D (`clampedByBudget` survived a clear). Confirmed and left open: E/F/G (thumbnail cache cost,
file identity, bounding) and I (identical-update churn), each with the measurement that justifies
the next change. Real image: `万萝图.png`, SHA-256 unchanged.

## 1. Audit matrix

| # | Suspicion | Verdict |
| --- | --- | --- |
| A | An old `stopAndPurge` can kill a newer plan | **confirmed** — fixed with a lifecycle epoch |
| B | The warm-plan-nil test is false coverage | **confirmed — test coverage defect**, production code correct |
| C | Portrait filename escapes the card horizontally | **confirmed** — fixed |
| D | `clampedByBudget` survives a native-detail clear | **confirmed** — fixed |
| E | Thumbnail byte accounting uses `w*h*4` | **confirmed** (should be `bytesPerRow*h`) — not fixed |
| F | URL-only cache key returns a stale replaced file | **confirmed** — not fixed |
| G | Thumbnail cache meaningfully unbounded | **confirmed**, measured — not fixed |
| I | Identical request identity causes avoidable churn | **confirmed** (measured last round) — not fixed |

## 2. Old-purge / New-request Race

`clearNativeDetail()` scheduled `Task { await nativeDetail.stopAndPurge() }` and `request()` carried
nothing that said which plan it belonged to. The actor therefore saw two unrelated messages: a
cleanup created by a clear and delivered after a later request wiped that request's pass, cache and
plan — the mirror image of the stale-request-after-purge race fixed in an earlier round. Every zoom
out / zoom in pair is a candidate.

## 3. Native-detail Lifecycle Fix

The viewer numbers every native-detail operation (`detailLifecycleEpoch`) and passes it to both
calls; the scheduler keeps the last epoch it applied and ignores anything not newer
(`lifecycleIgnoredStale`). A cleanup from before a request is ignored; a cleanup that really is
newest still clears. The unnumbered overloads remain for callers that do not track the lifecycle
(tests), each taking the next epoch itself.

Deterministic evidence at the scheduler level (no sleeps, no reliance on task ordering): request
epoch 1, request epoch 3, then `stopAndPurge(epoch: 2)` → the plan of epoch 3 is still running and
`lifecycleIgnoredStale == 1`; `stopAndPurge(epoch: 4)` then really stops it. Viewer level:
zoom-to-fit followed immediately by zoom-to-actual leaves the new plan alive with its cache and
resident keys after a 1.5 s window for any late purge to arrive.

## 4. WarmPlan-Nil Test Coverage Audit

The previous test reached the branch through `reloadCurrentImageForTesting()` →
`loadCurrentImage()`, which clears unconditionally — so it proved that path and never executed
`WarmAreaPolicy.plan == nil`. A branch counter (`warmPlanNilCleanups`) settles it: the old test would
have left it at 0.

**Production bug: no. Test coverage defect: yes.**

## 5. WarmPlan-Nil Regression Test

`updateNativeDetailForTesting()` calls the real detail update with a viewport magnified far enough
(zoomScale 10⁷) that the visible rectangle is under a pixel — `needsNativeDetail` is still true, so
the warm plan is the thing that fails. The counter goes to 1, the plan is cleared, the CPU cache is
purged and the published resident set empties.

## 6. Selection-card Portrait Geometry

The card follows the image box while the filename label was bound to the cell (`±8`), so for a
portrait thumbnail the label extended outside the selection colour; the previous round's test only
checked vertical containment. Reproduced by checking horizontal containment for 2:3, 1:4, 1:5 and an
extreme 1:10 shape.

## 7. Selection-card Fix

The label is bound to the card, and the card takes a minimum width (120 pt) *from* the image as a
lower bound plus the image box plus padding. An equality on both edges was tried first and fought the
image's aspect constraint — measured, a 2:3 thumbnail came out 0.79 instead of 0.67 — so the relation
is a lower bound only, which keeps the aspect intact and the card centred.

Real image: card 176×140 at (2, 28), image 160×106, label 168×14 at (6, 36) — inside the card on both
axes. Every filename mode (always / hover / never) produces an identical card frame.

## 8. Native-detail Diagnostic Reset

`clampedByBudget` was set when a plan was clamped by the CPU budget and never cleared, so after
zooming out — or after the image was closed — the diagnostics still reported a budget problem for a
plan that no longer existed. `clearNativeDetail()` now resets it, verified with a 128 KiB budget
(which really clamps) followed by a disable.

## 9. Thumbnail Byte-cost Measurements

Not implemented this round. The current accounting is `width × height × 4`; the correct figure is
`bytesPerRow × height`, which for the drawer's 300 px thumbnails is the same only when the rows are
already packed. Measured earlier through the real path: ~13 KB per entry at that size (12 entries /
138 KB), which is the number that would size a budget; the reworked measurement the brief asks for
(300×200, 200×300, 300×300, 300×75, 75×300, then 100/1000/5000) is part of the same change and is
not claimed here.

## 10. Thumbnail File Identity

Not implemented. Confirmed by inspection: the key is the URL alone, so replacing a file's contents
leaves its old thumbnail in the cache until the app restarts. The intended key is URL plus file
identity (size and modification date, both, so timestamp granularity cannot hide a replacement).

## 11. Thumbnail LRU Design

Not implemented. The intended shape: entries carry `key`, `image` and `cost = bytesPerRow × height`;
a `totalCost` is evicted from the least recently used end when it exceeds the budget; count limits
are explicitly not used.

## 12. Thumbnail Cache Measurements

Unchanged from the previous round: 12 entries / 138 KB in the fixture folder, ~13 KB per entry. No
budget exists, so the 1000/5000-file figures are extrapolations, not measurements, and are not
claimed.

## 13. Same-plan Churn Root Cause

Measured last round and unchanged: three identical viewport assignments gave `generation +3`,
`request +3`, plan stable, no canvas fallback. The churn is real (three direct requests for one
unchanged plan) but harmless in effect; a fix needs an identity over plan + source + source metadata
and must preserve the warm ordering that the direction hint controls.

## 14. Native-detail Request Identity

Designed, not implemented: the identity must cover the source, the plan, and the source metadata
(orientation and colour space, either directly or via the source generation they belong to). Plan
equality alone is explicitly *not* sufficient — the same tile set with different metadata must still
invalidate, and a changed direction hint must re-order the warm queue rather than be treated as a
no-op.

## 15. Same-plan Before/After Measurements

Before: generation +3, requests +3 (unchanged this round — the fix was not made). After: not
measured, because no change was made. The correctness side was protected by doing nothing.

## 16. Combined Disable/Re-enable Validation

`zoomToFit` → immediately `zoomActualPixels`: the new plan is established, survives a late purge, and
its pass produces tiles with textures resident. This is the test that would have failed before the
epoch fix and would also fail if the same-plan no-op had been implemented carelessly.

## 17. Automated Tests

| Suite | Added |
| --- | --- |
| `LifecycleEpochTests` | 4: older purge cannot stop a newer request (scheduler level), disable → re-enable keeps the new plan, warm-plan-nil branch actually reached, clamped flag reset |
| `ThumbnailCellLayoutTests` | 2: horizontal containment for portrait/extreme shapes, card geometry identical in every filename mode |
| Full suite | **504 tests, 0 failures** (146 s) |

## 18. TSan / ASan

TSan: **44 tests, 0 failures, no race reports**. ASan: **61 tests, 0 failures, no reports**.

## 19. Real-file Validation

Drawer from launch, item switches, empty state, 95 s window: card 176×140 containing the image box
(160×106) and the label (168×14 at (6, 36)); empty state `plan true→false`, canvas 15→0, resident
112→0, CPU cache 112→0, GPU resident →0; one bounded-decode traversal; footprint at finish 0.471 GiB;
SHA-256 unchanged.

## 20. Remaining Limitations

- E, F, G and I are confirmed and **not fixed**; each has its measured evidence and the shape of the
  intended change above.
- The thumbnail byte-cost figures are from the old `w*h*4` accounting; the packed-row figure the
  brief prefers was not measured because the cache rework was not done.
- The warm-plan-nil branch test asserts the branch ran via a counter and the state it clears; it does
  not compare rendered output.
- The selection card was verified by frame geometry and on the real image, not by a rendered
  screenshot gate.
