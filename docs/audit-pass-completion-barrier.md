# Audit: pass-completion barrier, tile-count semantics, source identity

Six items. Confirmed and fixed: A (a pass could finish before its emitted tiles were accepted),
B (a pending plan could then mislabel already-decoded tail tiles as stale) and C (the pass's
`produced` count undercounted for the same reason). Corrected: G (same-source warm reuse is
opportunistic, not guaranteed — the previous report overclaimed). Confirmed but deliberately not
fixed: F (same-path source replacement is covered by the lifecycle, not by cache identity).
Not measured this round: H (source-purge byte/pin invariants). Deferred: I (thumbnail cache) and
J (identical-request churn).

## 1. Audit matrix

| # | Suspicion | Verdict |
| --- | --- | --- |
| A | `passEnded` can precede live tile acceptance | **confirmed** — fixed with a barrier |
| B | A pending plan can make already-decoded tail tiles stale | **confirmed** — fixed |
| C | `produced` can undercount | **confirmed** — fixed, semantics split |
| F | Same-path replaced source can hit the old native tiles | **confirmed — lifecycle-safe by design**, not cache identity |
| G | Same-source disable → re-enable is guaranteed warm | **opportunistic only** — previous report corrected |
| H | Source-purge byte/pin invariants | **not measured this round** |
| I/J | Thumbnail cache, identical-request churn | **deferred** |

## 2. Pass-end / Tile-acceptance Reproduction

By inspection: every tile's `acceptDecodedTile` was its own unstructured `Task`, created on the
provider thread, while `passEnded` was awaited on the same detached task immediately after
`produce` returned. Nothing ordered those actor entries, so `passEnded` could run with tiles still
queued.

## 3. Pending-plan Tail-tile Reproduction

The consequence, also by inspection: `passEnded` clears `runningPlan` and starts `pendingPlan`,
which bumps `generation`. The queued tail tiles of the *old* pass then compared their token against
the new generation and were counted as `staleDecodedTilesDiscarded` — tiles the provider had decoded
successfully, reclassified as stale purely by actor scheduling order.

## 4. Acceptance Barrier Design

A per-pass outstanding counter, raised on the provider thread when a tile is emitted and lowered by
the actor when that tile is accepted. The producer's completion records `produced`/`failure` but
does not finish the pass; `maybeFinishPass()` runs after both events and finishes only when the
producer has stopped **and** the counter is zero. No waiting on the actor (which would deadlock
against the acceptance tasks it needs), no sleeps, and the ordering is a property of the state, not
of task arrival.

## 5. Pass Completion Fix

`producerFinished(token:produced:outstanding:failure:)` records the producer's outcome;
`acceptDecodedTile` decrements and calls `maybeFinishPass()`; `passEnded` is now only reachable
through it, so the pending plan starts strictly after the drain. A pass that is genuinely superseded
(by a purge) still drops its late tiles before they reach the cache — the barrier only orders
*normal* completion.

## 6. Tile-count / Stats Semantics

Split explicitly: `lastPassProduced` (tiles the provider emitted, counted on the provider thread),
`lastPassAccepted` (tiles that reached the cache), `staleDecodedTilesDiscarded` (tiles refused
because the pass was truly invalidated) and `tilesDelivered` (publishes). For a pass that completes
normally the test asserts `produced == accepted == 3` with `stale == 0`.

## 7. True-cancellation Regression

A purge during a pass still invalidates it: the tile emitted before the purge, accepted after it,
never reaches the cache and is counted stale. That distinction — real invalidation versus scheduling
order — is the point of the change, and both directions are tested.

## 8. Same-path Native-tile Identity Audit

`NativeTileKey` is `sourcePath + pageIndex + level + tileSize + x + y`: no size, no modification
date, no resource identifier, no source generation. A file replaced at the same path with the same
dimensions would hit the previous pixels. In the current flow a source change or a reopen goes
through `clearNativeDetail()` → `stopAndPurge()` (and now a source-scoped purge), so the stale entry
is gone before it can be read — the safety comes from the lifecycle, not from the key.

**Classified: lifecycle-safe by design, with an API risk.** A future caller that reuses the cache
across a file replacement without going through the lifecycle would read stale pixels. Adding a
source identity to the key is the right fix and is a wider change than this round; the same identity
type is needed by the thumbnail cache, so they should be designed together.

## 9. Native Source Identity Fix

Not applied (see §8).

## 10. Same-source Warm-reuse Ordering Matrix

The two legal orders give different results, which settles the question the previous report got
wrong:

| Order | Cache | Effect |
| --- | --- | --- |
| purge first, then a same-source request | cleared | cold: the pass re-decodes |
| same-source request first, stale purge ignored | kept | warm |

So same-source reuse is **opportunistic**: it happens when the request beats the purge to the actor,
not by contract. The code is right to keep the tiles (a same-source request must not purge them) and
the report must not claim a guarantee. A grace cache would be needed to make it one, and nothing in
the product asks for that yet.

## 11. Source-purge Cache Invariants

Not measured this round: the purge updates `entries`, `storedBytes` and `pinned` together and the
per-source tests pass, but the explicit invariants (`storedBytes == Σ cost`, `pinned ⊆ entries.keys`)
were not asserted. Recorded as an open verification item rather than claimed.

## 12. Thumbnail Deferred Status

Unchanged: cost should be `bytesPerRow × height`, the key needs file identity, eviction should be
byte-budgeted. The measured basis stays ~13 KB per entry at the drawer's 300 px size.

## 13. Same-plan Churn Deferred Status

Unchanged: three identical viewport updates still cost generation +3 and requests +3, with no canvas
fallback. Deliberately not mixed into this round's scheduler work.

## 14. Automated Tests

| Suite | Added |
| --- | --- |
| `SchedulerSnapshotTests` | 3: a pass waits for its tail before finishing, a pending plan starts only after the drain, a truly superseded pass still drops its late tiles |
| Full suite | **511 tests, 0 failures** (146 s) |

## 15. TSan / ASan

TSan: **37 tests, 0 failures, no race reports**. ASan: **34 tests, 0 failures, no reports**.

## 16. Real-file Validation

`万萝图.png`, zoom-to-actual then a six-step rapid pan, then the last item removed, 95 s window:
rapid pan completed with the plan active; empty state `plan true→false`, canvas 36→0, resident
182→0, CPU cache 256→0, GPU resident →0; one bounded-decode traversal; footprint at finish
0.232 GiB; SHA-256 unchanged.

`staleDecodedTilesDiscarded` is not printed by the app trace (the instrumentation mark for it was
added after this run), so **Q11 is answered by the deterministic tests only** — the real-file run
shows no abnormal growth of *anything it prints*, which is not the same measurement.

## 17. Remaining Limitations

- H's invariants are unasserted; F's stale-pixel risk is bounded by the lifecycle rather than by the
  key; G is opportunistic (corrected above).
- Q11 has no real-file measurement (see §16).
- I and J remain deferred with their evidence recorded.
- The barrier test drives the actor's bookkeeping directly; it does not decode real pixels, so it
  proves ordering, not image content.

## 18. Commit SHA

`3edfcce` (barrier fix), report commit follows, pushed to `perf/bounded-metal-design` with a clean
tree.
