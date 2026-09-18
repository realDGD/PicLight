# Audit: direct-request generation, source metadata, stop-and-purge, thumbnail retry

The previous round guarded the *scheduled* publication path. This round examines the *direct* path
(`updateNativeDetail` → `nativeDetail.request` → publish) plus the queued thumbnail retry. Every item
was confirmed by inspection and then by a deterministic test before production code changed; the real
image (`万萝图.png`, 48000×32000, SHA-256 unchanged) was used for validation, not as proof.

## 1. Audit matrix

| # | Suspicion | Verdict |
| --- | --- | --- |
| A | The direct publication reads the **current** generation instead of the plan's | **confirmed** |
| B | An old source's request can read the new source's orientation / colour space | **confirmed** |
| C | A stale request can start a pass after the plan was cleared and `stopAndPurge` ran | **confirmed** |
| D | One detail generation is insufficient (needs source/plan/bitmap generations) | **not reproduced** |
| F | A queued thumbnail retry survives a current-item change | **confirmed — as redundant work, not a correctness fault** |

## 2. Direct-publication generation reproduction

Inspection, before any test: `updateNativeDetail` called `setDetailPlan(plan, source:)` (bumping the
generation) and then created a task capturing only `plan` and `url`; `publishCachedTiles` read
`detailPublicationGeneration` **when the task ran**, i.e. after the request. So a task belonging to
generation *G1* that resumed after the user panned read *G2*, compared *G2* with *G2*, and applied the
abandoned plan's sets as if they were current — the guard added last round could not see it.

Test: the direct task is suspended by a hook before it reads anything, the viewport pans, then the
task is released. Observed on the unfixed code: the stale counters stayed at 0 (both
`staleDirectRequestSkips` and `staleDirectPublicationDiscards` were 0, because neither existed) and
the test's containment assertions for the canvas and the resident set failed.

## 3. Scheduled vs direct publication paths

| | Scheduled (tile arrival) | Direct (plan change) |
| --- | --- | --- |
| Trigger | `nativeTileArrived` → `schedulePublication` → `runScheduledPublication` | `updateNativeDetail` → task → `request` → `publishCachedTiles` |
| Before the fix | generation captured at task start, before the scheduler reads | generation read **after** the request, when publishing |
| After the fix | unchanged (already captured) | captured with the plan, on the main actor |
| Gate | before the apply inside `refreshPublishedSets` | before the request **and** before the apply |

Both now pass an immutable captured generation into `refreshPublishedSets`, which is the only place
that compares it.

## 4. Generation capture fix

`updateNativeDetail` captures `generation`, `colorSpace` and `orientation` on the main actor at the
moment the plan is created, and `publishCachedTiles(for:source:generation:)` takes the generation as
a **required parameter**, so no caller can read it late. The task checks the generation before
calling `nativeDetail.request` (counted as `staleDirectRequestSkips`) and again before publishing
(`staleDirectPublicationDiscards`), which is also what stops a request that became stale *while
queued* from starting a pass after `stopAndPurge`.

## 5. Source metadata snapshot audit

`colorSpace` came from `viewerState.currentImage?.colorSpace` and the orientation from
`viewerState.descriptor?.orientation` — both read **inside** the task, after the source may have
changed. A request for source A could therefore be decoded with source B's orientation and colour
space: a mismatch that would silently rotate or mis-colour the tiles.

## 6. Orientation / colour-space identity fix

Both values are captured with the plan (from the same `bitmap` and `descriptor` the plan was built
from) and passed to the request as immutable arguments. The test asserts that no snapshot for the old
source ever carries different metadata; the snapshot list is also what makes the failure
attributable (`source == A && orientation != orientationA`).

## 7. Stop-and-purge ordering audit

The plan-cleared path (`setDetailPlan(nil)`, `publishNativeTiles([], [])`, `Task { await
nativeDetail.stopAndPurge() }`) raced with any direct task still pending: the actor receives the
`request` and the `stopAndPurge` in arrival order, and a request that arrives after the purge starts a
fresh pass for a plan nobody wants. Measured on the unfixed code: after `stopAndPurge`, the abandoned
request left textures resident (`publishedResidentKeysForTesting` non-empty) and no counter moved.

## 8. Old-request suppression

The pre-request gate is what prevents the pass from starting at all; the post-request gate prevents
its publication. Both are covered by tests: the abandoned plan neither changes the canvas nor hands
the renderer a resident set from the previous plan, and the dropped-plan case leaves nothing
resident. A request for the current plan still applies normally (0 skips, 0 discards).

## 9. Thumbnail current-retry audit

`finishThumbnailRequest` started a queued retry when a placeholder came back, checking only that
*some* bitmap existed — not that the item was still the current one. With A current, a retry queued,
and the user switching to B, A's nil completion found `viewerState.currentImage != nil` (B's) and
started another A request, which for an oversized file returns a placeholder again: redundant
decoding, no incorrect pixels. Classified as wasted work, fixed as such: the queued entry is always
consumed, and the retry is dropped (counted `retryDroppedNotCurrent`) when the item is no longer
current. The one-request-per-URL invariant, `maxConcurrentPerURL == 1`, and URL-based row identity
are unchanged (all existing thumbnail tests still pass).

## 10. Automated tests

| Suite | Added |
| --- | --- |
| `DirectRequestGenerationTests` | 4: abandoned direct publication discarded (canvas containment + resident subset + counter), old source never carries new metadata, dropped plan leaves nothing resident, current plan still applies |
| `ThumbnailRequestTests` | 1: queued retry dropped after the user moves on |
| Full suite | **488 tests, 0 failures** (135 s) |

## 11. TSan / ASan

TSan: **39 tests, 0 failures, no race reports**. ASan: **51 tests, 0 failures, no reports**.

## 12. Real-file validation

`万萝图.png`, drawer from launch, rapid pan, and six next/previous item switches, 100 s window:

| Reading | Value |
| --- | --- |
| Direct-path stale counters | `requestSkips=0`, `publicationDiscards=0` |
| Scheduled stale publications | `stalePublications=0`, 40 publication runs |
| Thumbnail | `requests=2`, `maxConcurrentPerURL=1`, `staleDeliveriesIgnored=0`, `retryDroppedNotCurrent=0` |
| GPU residency | 126 tiles / 127 MiB resident, 20 synchronous uploads |
| Traversals / memory | 1 bounded decode, footprint at finish 0.606 GiB, peak sampled 0.679 GiB |
| Source image | SHA-256 unchanged |

The real image hit none of the races, which is expected — the deterministic tests are the correctness
evidence, and this run only shows the guards do not disturb normal behaviour. One diagnostics defect
was found *by* this run: `publicationStats.generation` was declared but never written, so the mark
printed `generation=0`; it is now populated and asserted to advance (≥ 2 after a pan).

## 13. Remaining limitations

- The real image exercised neither the stale-request skips nor the stale-publication discards
  (all zero); those paths rest on the deterministic tests.
- `D` was not reproduced: the single monotonic generation covers viewport, source, disable and bitmap
  changes, and both paths now capture it, so no split into source/plan/bitmap generations was made.
- The metadata-mismatch test asserts absence of a mismatch in the recorded snapshots; it does not
  compare decoded pixels between orientations, so a *different* future defect in the same area would
  need its own pixel-level check.
- Thumbnail retry dropping is verified in one scenario (switch away while a retry is queued); a folder
  where the item returns to current before the completion lands was not measured.
