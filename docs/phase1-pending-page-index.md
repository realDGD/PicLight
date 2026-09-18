# Phase 1 audit: same-path identity, cache invariants, pending page index

Phase 1 of the two-phase request. A (same-path replacement identity) is confirmed by inspection and
**not fixed** — the fix is the source-identity change the brief itself says to design for reuse
rather than rush. B (purge invariants) is unverified by test. C (pending page index) is confirmed
and fixed. Phase 2 has **not been started** (see the end).

## 1. Audit matrix

| # | Suspicion | Verdict |
| --- | --- | --- |
| A | A same-path replaced source can expose an old native tile | **confirmed** — fix deferred by design decision |
| B | Source-purge byte/pin invariants | **not verified by test** (implementation reads correct) |
| C | A pending plan loses its `pageIndex` | **confirmed** and fixed |

## 2. Native Same-path Replacement

`NativeTileKey` is `sourcePath + pageIndex + level + x + y + tileSize`: no file size, modification
date, resource identifier or source generation. Safety therefore rests entirely on the lifecycle:
every source change and reopen goes through `clearNativeDetail()` → `stopAndPurge()` (or the
source-scoped purge). The previous round already showed that a *stale* purge is deliberately ignored
by the lifecycle epoch, so the race the brief describes is real: clear (purge queued, ignored later)
→ same path replaced with different content → request accepted first → the cache still holds the old
path's tiles and can serve them.

Confirmed by inspection; not reproduced by a test in this round (the deterministic test needs a
temp-file replacement plus a blocked purge, and the fix it would justify is the wider identity change
below).

## 3. Source Identity Design

The identity must make v1 and v2 differ while the path is unchanged, so at least
`canonical path + file size + modification date` (never modification date alone — its granularity is
too coarse for a fast replacement), optionally `fileResourceIdentifier` where the filesystem
provides a stable one. It belongs in one type shared by the native tile cache and the thumbnail
cache, and `NativeTileKey` would carry it instead of a bare path. Deliberately not implemented here:
it touches every key construction site, and the brief asks for it to be designed for reuse rather
than rushed.

## 4. Tile-cache Invariants

`purge(exceptSourcePath:)` updates `entries`, `storedBytes` and `pinned` under the cache's lock and
decrements `storedBytes` by each removed entry's cost. Reading the code, `storedBytes == Σ entry.cost`
and `pinned ⊆ entries.keys` hold after a purge, and `purgedForSourceChange` counts removed entries.
**The explicit invariant tests the brief asks for were not written this round**, so this is a
code-level argument, not measured evidence.

## 5. Pending Page-index Audit

Confirmed: `applyRequest` queued `pendingPlan = plan` without the page, and the pending start called
`start(plan: queued, source: finishedSource, pageIndex: 0)` — a pan on page 2 restarted the pass on
page 0, decoding the wrong page. The viewport-coverage check had the same defect from the other
side: it built the *running* pass's keys with the *new* request's page index, so a request for a
different page could look covered and be dropped as "already running".

## 6. Native-detail Regression Results

Fix: the scheduler records `pendingPageIndex` with the queued plan and `runningPageIndex` with the
running pass; the coverage check now requires the same page and builds the running keys with the
running page; the pending start uses the queued page. Test: request page 2, queue a small move on
page 2, finish the running pass → `runningPageIndexForTesting == 2` (before the fix it was 0).

Phase 1 verification: **512 tests, 0 failures**; TSan **21 tests, 0 failures, no race reports**;
ASan **28 tests, 0 failures, no reports**.

## 7. Phase 2 — not started

The Tool Dock work (pin button and layout, auto-hide state machine with a reveal zone, styling,
compositional hover/press animation, reduced-motion handling, ~18 tests), the drawer filename change
and the fixed-size Settings window are a substantial feature set. The contract for this round is
"Phase 1 clean, then Phase 2"; with the context remaining after Phase 1 I cannot implement that set
together with the tests and GUI validation it requires without risking exactly the kind of
half-finished change the brief forbids. It is therefore reported as **not started**, with the tree
left in a clean, fully verified state (512 tests green) rather than mid-feature.

Nothing in Phase 2 was touched: no dock code, no drawer filename behaviour, no Settings window
change, no icon changes.
