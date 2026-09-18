# Audit: stale publications, thumbnail request state, delivery identity

Three suspicions, each checked against the production code and then against a deterministic test
before any production change. Real-image work uses `万萝图.png` (48000×32000, 1.929 GiB); SHA-256
verified unchanged.

## 1. Audit matrix

| # | Suspicion | Verdict |
| --- | --- | --- |
| A | A publication that was reading the scheduler when the plan changed still applies its result | **confirmed** |
| B | The thumbnail retry clears the in-flight flag and starts a second concurrent request | **confirmed** — five concurrent requests for one URL before the fix |
| C | Delivery uses the row number captured at request time, so a reorder writes into another file's row | **confirmed** |
| D | A completion for a previous current item needs its own generation | **not reproduced** — URL identity is sufficient |

## 2. Viewer stale-publication reproduction

`refreshPublishedSets` read the visible, warm and resident sets and then applied them with no check
that the plan was still current. The failure was observed before the fix even without the pause hook:
after a pan published the new plan, releasing the suspended publication changed the canvas tile set
again, and `stalePublicationDiscarded` stayed 0. The renderer's own stale-plan guard cannot help
here — the viewer hands it the previous resident set from above.

## 3. Publication generation fix

`detailPlan` and `detailSource` are now set together through `setDetailPlan`, which bumps
`detailPublicationGeneration`; every publication captures the generation when it starts and re-checks
it **immediately before the apply** inside the MainActor block, counting
`publicationStats.stalePublicationDiscarded` when it drops. The direct publication from
`updateNativeDetail` carries the generation it just set, so both paths share one contract.

Evidence (all deterministic, pause hook instead of timing):

- the abandoned publication no longer overwrites the canvas: every drawn tile is a member of the
  current plan, and the published resident set is unchanged;
- a publication for the current plan still applies, and nothing is counted as stale;
- a stale discard does not wedge the state machine: `publicationScheduled` is cleared on the same
  completion, and the next arrival publishes normally;
- same-generation arrivals still coalesce (100 arrivals → ≤ 12 runs, none dropped).

## 4. Coalescing regression check

Coalescing is unaffected because arrivals do not change the generation: the burst test still shows a
hundred arrivals collapsing into a handful of publications, `stalePublicationDiscarded` stays 0, and
the real image still measures `dupWarm` in the tens rather than the 45,239 of the pre-coalescing
build.

## 5. Thumbnail retry concurrency reproduction

`retryCurrentItemThumbnail` cleared `inFlightThumbnails[url]` and the guard in `requestThumbnail`
then admitted a second `Task`. Measured before the fix: `requests=5, active=5` for one URL while the
first request was still suspended — five concurrent decodes of the same thumbnail.

## 6. Thumbnail request state-machine fix

A request is the only thing that can clear its own in-flight flag. A retry that arrives while a
request is running is recorded in `thumbnailRetryQueued`; completion starts the queued retry only if
the result was a placeholder (nil) and the bitmap exists. Verified: while the first request is
suspended, repeated retries leave `requests` unchanged, `retryQueued` at 1, and
`maxConcurrentPerURL` at 1; after release the request still delivers its result. Once the thumbnail
is cached, a retry is a no-op.

## 7. Row-identity reproduction

`requestThumbnail` captured `index` and delivered with `drawer.updateThumbnail(at: index, …)`, which
resolves the index against whatever `items` holds at completion time. Reproduced: with `[A, B]`
reordered to `[B, A]`, delivering A's image to the captured row 0 puts A's image in B's row.

## 8. URL-based delivery fix

`ThumbnailDrawerView.updateThumbnail(for:image:) -> Bool` finds the item by URL and delivers there;
the viewer counts `thumbnailStaleDeliveriesIgnored` when the item is gone, and the image stays in
`thumbnailCache` so the provider serves it whenever that URL becomes visible again. Covered by tests
for reorder, insert, delete, a rebuilt folder, and for a cached thumbnail remaining usable after a
stale delivery was ignored.

## 9. Diagnostics

- Publication: `publicationGeneration` (on the stats struct), `stalePublicationDiscarded`, plus the
  existing arrivals/requests/runs/coalesced/materialised/submitted counters.
- Thumbnail: `active`, `retryQueued`, `maxConcurrentPerURL`, `staleDeliveriesIgnored`, and a per-URL
  request count for tests.

## 10. Automated tests

| Suite | Tests |
| --- | --- |
| `PublicationGenerationTests` | 4: stale plan discarded, current plan still applies, stale discard does not wedge, coalescing intact |
| `ThumbnailRequestTests` | 4: row-index hazard documented, URL delivery across a reorder, missing URL ignored + cache reused, insert/delete |
| `ThumbnailRequestStateTests` | 2: no second concurrent request, cached retry is a no-op |
| Full suite | **483 tests, 0 failures** (127 s) |

## 11. TSan / ASan

- TSan (publication, thumbnail, tile, plan, residency suites): **no data races reported**. Two tests
  failed initially because they asserted set equality after a pan, which a *deferred legitimate*
  publication may change under sanitizer slowdown; the assertion now checks containment of the canvas
  in the current plan, which is what the defect would violate, and the run is clean.
- ASan: a SEGV in `objc_release` during XCTest's own deallocation check turned out to be the drawer
  test fixture: an `NSWindow` with the default `isReleasedWhenClosed` released itself on `close()`
  while the table view was still referenced. That crash also reproduced in the **plain** suite, which
  is how it was found (the suite died with signal 11 after `ThumbnailDrawerTests`). With
  `isReleasedWhenClosed = false`: **ASan set 57 tests, 0 failures, no reports**, and the plain full
  suite passes.

## 12. Real-file validation

`万萝图.png`, drawer pinned open from launch, 78 s window, rapid-pan sequence at the end:

| Reading | Value |
| --- | --- |
| Drawer row 0 | `hasImage=true`, image 160×106 at (10, 54), border 168×114, current=true |
| Thumbnail requests | 2 (`requests=2`), `active=0`, `retryQueued=0` |
| `maxConcurrentPerURL` | **1** for the whole session |
| `staleDeliveriesIgnored` | 0 |
| Rapid pan (6 moves of 0.5–1.0 viewports) | `stalePublications=0`, publication runs 15 → 20, GPU resident 30 tiles (30 MiB), `sync=6` uploads |
| Stability | one bounded-decode traversal, footprint at finish 0.219 GiB, peak sampled 0.282 GiB, SHA-256 unchanged |

The rapid pan did not produce a stale publication on the real image (`stalePublications=0`): the
debounce and the coalescer mean a pan's publication usually completes before the next pan. The guard
itself is proven by the deterministic test, not by this run.

## 13. Remaining limitations

- `stalePublicationDiscarded` was 0 on the real image, so the discard path has no real-image
  observation; it is covered by tests only.
- The rapid-pan probe moves the viewport within one folder item. Rapid *folder* or *current item*
  switching was not exercised on the real file; the reorder/insert/delete folder cases are covered by
  the drawer tests instead.
- The ASan crash was in the test fixture, not production code. That conclusion rests on two
  observations: the crash also reproduced in the plain suite, and it disappeared with the fixture fix
  while the sanitized set went from crashing to clean.
- Transient peak footprint is unchanged as a target: this round made no memory claims.
