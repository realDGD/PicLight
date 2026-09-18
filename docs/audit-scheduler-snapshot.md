# Audit: scheduler snapshot, token-before-cache, source-scoped purge, card width

Six items. Confirmed and fixed: A (a pass could decode with a later request's metadata), B (a
cancelled pass's tile entered the CPU cache), C (the previous source's tiles kept the budget after
an ignored stale purge), D (a long filename could push the card past the row). Classified: E (dual
epoch API) as an API footgun, not a production bug. Deferred with their measurements: F/G/H
(thumbnail cache cost, identity, bounding) and J (identical-update churn). Real image:
`万萝图.png`, SHA-256 unchanged.

## 1. Audit matrix

| # | Suspicion | Verdict |
| --- | --- | --- |
| A | A detached pass can read newer orientation/colour space | **confirmed** — fixed |
| B | A stale decoded tile can enter the CPU cache | **confirmed** — fixed |
| C | A stale purge leaves the old source's cache behind | **confirmed** — fixed (source-scoped) |
| D | A long filename can push the card outside the row | **confirmed** — fixed |
| E | Dual epoch authority is a production bug | **API footgun only** — production uses the numbered API |
| F/G/H | Thumbnail cost / identity / bounding | **confirmed, deferred** |
| J | Identical request churn | **confirmed, deferred** (optimization) |

## 2. Scheduler Metadata Snapshot Reproduction

Inspection of `start()`: `plan` and `source` are captured by the request, but the detached task
opened with `let space = await self?.currentColorSpace()` and
`let orientation = await self?.currentOrientation()` — the actor's values at *task start*. A pass for
source A that started after a request for source B therefore decoded A with B's orientation and
colour space. This is the same mismatch fixed on the viewer side last round, one layer down.

## 3. Metadata Snapshot Fix

`start()` captures `passColorSpace` and `passOrientation` on the actor, where the request that owns
the pass is the current one, and the task consumes only those values; the two actor-reading helpers
are gone. `runningMetadataForTesting` records what the running pass was started with, and a test
asserts each request's pass keeps its own metadata (`up`/sRGB then `right`/P3).

## 4. Stale Decoded Tile Reproduction

Inspection of the provider callback: `cache.store(tile)` ran first and
`Task { await scheduler.deliver(tile, token: token) }` second, with the token check inside `deliver`.
A cancelled pass's late tile therefore entered the CPU cache — displacing live tiles — even though
the token guard then refused to publish it.

## 5. Generation-before-Cache Fix

Tiles go through `acceptDecodedTile`, which checks the token first, counts a stale tile
(`staleDecodedTilesDiscarded`), then stores, then publishes through the existing `deliver` (which
owns in-flight bookkeeping and stats — an earlier version of this change double-counted
`tilesDelivered` and was caught by `NativeDetailTests`). The store moves into the actor hop that
already existed per tile, so no extra hop was added. Test: a live token stores the tile; a stale
token leaves the cache untouched and increments the counter.

## 6. Cross-source Cache Retention Audit

The lifecycle epoch means a stale purge is ignored — including the `cache.removeAll()` it carried.
So after a quick A → B switch the A tiles stayed in the cache, holding CPU budget for a source that
is no longer on screen. By design of the epoch fix, this was a cost, not a crash.

## 7. Source-scoped Cache Policy

`NativeTileCache.purge(exceptSourcePath:)` drops every tile whose key belongs to another source
(counted in `purgedForSourceChange`); a request for the same source keeps its tiles. Verified:
A → B removes A's tile and keeps B's; a second request for the same source keeps its warm tile, so
disable → re-enable stays warm.

## 8. Long-filename Selection Geometry

The card was bounded only from below (`≥ image + padding`, `≥ 120`), so the label's intrinsic width
could stretch it past the row. Reproduced with 100- and 200-character names, CJK, emoji and
space-less names across landscape, portrait and 1:10 shapes.

## 9. Selection Max-width Fix

A required maximum (cell width − 12) plus a low horizontal compression-resistance priority on the
label, so it truncates in the middle instead of pushing. Real image: card 168×136 at (6, 32),
`minX ≥ 0` and `maxX ≤ cell width`; the image box (152×102) follows the tighter cap and keeps its
aspect.

## 10. Lifecycle Epoch API Audit

Production call sites are numbered only: the viewer passes `epoch:` to both `request` and
`stopAndPurge`. The unnumbered overloads (which take the next epoch themselves) are used by tests,
so the two-authority hazard the brief describes — an unnumbered call advancing the scheduler's epoch
past the viewer's — cannot happen from production code today. It remains an API footgun: a future
caller could still mix them. **Production bug: no. Footgun: yes**, left as such because removing the
overloads would churn the existing scheduler tests for no behavioural gain.

## 11. Epoch Authority Cleanup

Not performed (see §10). Recommendation if it is ever revisited: make the unnumbered overloads
internal-and-test-only by naming, or have the scheduler own the epoch and return tokens to the
viewer.

## 12–14. Thumbnail Byte-cost / Identity / LRU

Deferred, unchanged from the previous round: cost should be `bytesPerRow × height` rather than
`w × h × 4`; the cache key should include file identity (size **and** modification date, since
neither alone survives fast replacement); eviction should be byte-budgeted rather than by count. The
measured cost basis stays ~13 KB per entry at the drawer's 300 px size (12 entries / 138 KB). No
budget value is proposed until the packed-row measurement exists, so the 1000/5000-entry figures are
not claimed.

## 15. Same-plan Churn

Unchanged and deferred: three identical viewport updates still give generation +3 and requests +3,
with no canvas fallback. The correctness side is untouched by leaving it alone.

## 16. Combined Scheduler Correctness Test

The three scheduler-level tests in §3, §5 and §7 are complementary and independent of timing: each
drives the actor directly (request epochs, a live versus stale token, and a source change) rather
than racing a real pass, so none of them can pass by luck of scheduling.

## 17. Automated Tests

| Suite | Added |
| --- | --- |
| `SchedulerSnapshotTests` | 3: per-request metadata snapshot, stale tile never cached, source-scoped purge with same-source reuse |
| `ThumbnailLongFilenameTests` | 1: five pathological filenames × four shapes, card and label contained |
| Full suite | **508 tests, 0 failures** (146 s) |

## 18. TSan / ASan

TSan: **35 tests, 0 failures, no race reports** (covering the detached-pass metadata capture, the
actor-delivered tile path and the cache source purge). ASan: **31 tests, 0 failures, no reports**.

## 19. Real-file Validation

Drawer from launch, item switches, empty state, 95 s window: card 168×136 at (6, 32) containing the
image box (152×102) and the label (160×14 at (10, 40)); empty state `plan true→false`, canvas 30→0,
resident 189→0, CPU cache 238→0, GPU resident →0; one bounded-decode traversal; footprint at finish
0.209 GiB; SHA-256 unchanged.

## 20. Remaining Limitations

- F/G/H and J remain open with their evidence and intended changes recorded; the packed-row cost
  measurement was not taken.
- The metadata-snapshot test asserts what each pass was started with, not decoded pixel output, so a
  different future metadata defect in the same area would need its own check.
- The card's new maximum width shrinks the thumbnail slightly for the real file (160 → 152 pt of
  image width) because the image box follows the card's cap; that is the intended trade for keeping
  the card inside the row.
- The epoch API remains dual (numbered in production, unnumbered for tests).

## 21. Commit SHA

`cdcd773` (fixes) and this report commit, pushed to `perf/bounded-metal-design`, working tree clean.
