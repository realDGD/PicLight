# Audit: source identity, cache invariants, pending page index — and the Phase 2 dock/settings work

This round closed Phase 1 (three audit items with their missing test suites) and then implemented
Phase 2 (the product requirements for the tool dock, the drawer filenames and the settings window).

The headline finding is not in the new UI. **The same-path source-identity fix from the previous
round was inert in production**: the version string it compared was read through `URL.resourceValues`,
whose per-URL cache a file replacement does not invalidate — measured, it still reported the old size
and date ten seconds after the file at that path had been rewritten. The cache-side logic was
correct; the identity it was fed was stale. Fixed, with the reproduction kept as a test.

Phase 1's other two items (source-scoped cache invariants, pending plan page index) are confirmed and
covered by new deterministic suites. Phase 2 was implemented as specified; the parameters it uses are
listed below so they can be checked against the brief without reading the code.

## 1. Audit matrix

| # | Item | Verdict |
| --- | --- | --- |
| A | Same-path replaced source can still serve the previous file's tiles | **confirmed** — the version source was cached; fixed in `sourceVersion(of:)` |
| B | Source-purge byte/pin invariants | **confirmed sound** — 9 invariant tests, one wrong assumption in my own test corrected |
| C | A queued native-detail plan loses its page index | **confirmed (already fixed)** — now covered by 3 deterministic tests |
| D | `NativeTileCache.pin` can pin keys that are not resident | **API footgun** — by design (pins precede decodes); documented, not changed |
| E | `CATransition` lookup by the key passed to `add(_:forKey:)` | **API footgun** — CoreAnimation files it under `"transition"`; lookups now go by class |
| F | Tool dock pin + auto-hide + reveal strip + press animation | **implemented** — spec parameters, new suite |
| G | Drawer filenames always visible, preference removed | **implemented** |
| H | Settings window fixed at 560×560 | **implemented** |
| I | `infoButton` was a second, never-installed button | **confirmed dead** — `isInfoVisible` read a button that was not in the dock |
| J | Thumbnail cache byte accounting / LRU | **deferred** (unchanged from the previous round) |
| K | Identical-request churn | **deferred** (unchanged from the previous round) |

## 2. A — the source identity was read through a cache that never expires

### Inspection

`NativeDetailScheduler.sourceVersion(of:)` (added last round) built the identity from
`url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])`. `applyRequest` feeds that
string to `cache.setSourceVersion(_:for:)`, which drops the path's tiles whose stamped version
differs. The cache logic is right; the question is whether the string changes when the file does.

### Deterministic reproduction

A temporary file is written (4096 bytes), the version is read, the file is rewritten (8192 bytes)
with an explicit later modification date, and the version is read again — through the same `URL`
value, which is what production does (`FolderItem.url` is stable for the item's lifetime):

```
PROBE size now=8192
PROBE url immediate=4096-1789730728.1791558 first=4096-1789730728.1791558 same=true
PROBE fm immediate=8192-1789730788.179618 first=4096-1789730728.1791558 same=false
PROBE url after 1.0s=... same=true
PROBE url after 3.0s=... same=true
PROBE url after 6.0s=... same=true
```

The URL accessor keeps answering with the pre-replacement size *and* date indefinitely;
`FileManager.attributesOfItem` reports the change immediately.

### Why it mattered

`setSourceVersion` compared equal strings, so the replaced file's tiles stayed resident and were
served for the new file at the same path — the exact symptom the previous round's fix was written to
remove. The previous round's evidence was cache-level (a mismatched version drops tiles), which was
true but never exercised against a real replacement.

### Fix

`sourceVersion(of:)` now reads `FileManager.default.attributesOfItem(atPath:)`, which stats the file
on every call, and returns `"missing"` when the file cannot be stat'ed. The reproduction above is
`NativeSourceIdentityTests.testTheVersionFollowsAReplacementAtTheSamePath`, and
`testARequestForAReplacedFileCannotServeTheOldTile` runs the whole path through `request(…)`.

## 3. B — source-scoped cache invariants

Nine tests in `NativeTileCacheInvariantTests`, each asserting `storedBytes == Σ resident costs` and
`count == keys.count` after the operation under test, plus the operation-specific claim: an overwrite
replaces one tile's bytes rather than adding them, eviction drops the least-recently-used *unpinned*
tile, a pinned tile is never evicted, `purge(keeping:)` recomputes the total, `purge(exceptSourcePath:)`
is exact, `removeAll` leaves nothing, and a version change keeps the same books.

One assumption in my own first draft was wrong and is corrected here: **`pinnedKeys ⊆ keys` does not
hold** and must not. `applyRequest` pins the visible keys when the request is made, before any tile
is decoded, so a pin on a not-yet-resident tile is normal. What must hold — and is asserted where
tiles are actually removed — is that a pin never outlives its tile: `purge(keeping:)` keeps the pin of
a surviving tile and drops the pin of a removed one, and a version change drops the pins of the tiles
it removes.

## 4. C — a queued plan keeps its page index

Three tests in `PendingPageIndexTests`, driven through a provider stub that records the page each pass
is asked to decode and then blocks, so the "second request arrives while the first pass is running"
scenario is deterministic rather than a race with a real decode:

* a small pan on page 3 queues behind the running pass, and the queued pass reaches the provider with
  page 3 — the page-0 default would have shown up as `[3, 0]`;
* the same scenario on page 0 reports `[0, 0]`, so the test cannot pass by accident;
* a request for another page replaces the queue instead of running it, and the queued page-3 plan
  never reaches the provider.

## 5. Phase 2 — tool dock

Implemented in `ViewerToolDockView` and `ToolDockVisibilityModel`, wired in `ViewerViewController`.

Parameters, so they can be compared with the brief directly:

| Parameter | Value | Source |
| --- | --- | --- |
| Pin position | last control, behind its own separator | `testThePinIsTheLastControlBehindItsOwnSeparator` |
| Unpinned / pinned symbol | `pin.square` / `pin.square.fill` | `testThePinReadsAsAnOutlineUntilItIsEngaged` |
| Unpinned / pinned tint | `.labelColor` / `.systemBlue` | same |
| Tooltip + accessibility label | 固定工具栏 / 取消固定工具栏 | same |
| Pin ownership | viewer's model, per window, not persisted | `testSettingThePinStateDirectlyDoesNotReportAChange` |
| Show delay | 0.05 s | `testTimingsSitInTheIntendedRanges` |
| Hide delay | 0.7 s | same |
| Reveal strip tolerance | 24 pt either side | `testRevealZoneCoversThePillSidewaysAndTheGapBelow` |
| Reveal strip height | dock height + bottom inset + 8 pt margin, from the window's bottom edge | same |
| Transition | opacity + 8 pt slide towards the bottom edge, 0.15 s | `testTransitionParametersSitInTheIntendedRanges` |
| Press dip | 0.92×, 0.06 s down / 0.12 s up | `testPressDurationsAreInTheIntendedRanges` |
| Hover | 1.12× on the button, 1.04× on its neighbours | `testNeighbourHoverStillLiftsOnlyTheImmediateNeighbours` |
| Scale composition | `effectiveScale = hoverScale × pressScale` | `testPressDipsTheButtonAndComposesWithHover` |
| Pin crossfade | 0.12 s fade | `testTheSymbolSwapCrossfadesInTheIntendedRange` |
| Reduce Motion | no slide, no duration, no crossfade | `testReduceMotionRemovesTheCrossfade`, `hiddenOffset(reduceMotion:)` |

Two properties worth stating explicitly, because they are the ones a UI change can break silently:

* **The dock never moves the image.** Enlargement, the press dip and the hide transition are layer
  transforms; no frame, position or anchor point changes, so nothing reflows.
  `testHoverAndPressNeverChangeCanvasGeometry` compares `canvas.frame`, `dock.frame`, `zoomScale` and
  `fitScale` across hover + press; `testHoveringTheDockDoesNotMoveAnyButton` (existing) still holds.
* **A hidden dock is not merely transparent.** It leaves the hierarchy (`isHidden = true`) once the
  fade finishes, with a timed fallback that does not depend on the animation callback — the same
  contract the generic chrome fade already used.

The reveal strip is derived from the live dock frame, so pinning the drawer (which moves the canvas)
moves the strip with it: `testTheZoneFollowsTheDockWhenTheDrawerIsPinned`.

## 6. Phase 2 — drawer filenames and the settings window

* `ViewerViewController.applySettings` sets `drawer.filenameMode = .always` and no longer reads the
  preference; the UserDefaults key is left in place so an old value cannot resurface
  (`testAStoredPreferenceCannotHideTheNames` sets it to `never` and asserts the drawer still shows
  names). The cell's `.hover`/`.never` modes remain as cell capabilities — the policy decision lives
  in one place rather than a deleted code path.
* The filename popup is gone from the settings browse tab, with the tab's other popups still present
  so the check inspects a real view tree (`testTheFilenamePreferenceIsNoLongerOffered`).
* The settings window is `[.titled, .closable]` — no `.resizable` — with `contentMinSize ==
  contentMaxSize == 560×560`, and every tab's rows fit the fixed height (a tab that did not fit would
  have no scroller behind it): `SettingsWindowTests`.

## 7. API footguns (documented, not changed)

* **`NativeTileCache.pin` accepts non-resident keys.** Correct for its caller (a request pins what it
  is about to decode) and harmless — a pin on an absent tile protects nothing — but it means
  `pinnedKeys ⊆ keys` is not an invariant, and a test that assumes it will fail. Documented in
  `NativeTileCacheInvariantTests`.
* **A `CATransition` is not retrievable under the key passed to `add(_:forKey:)`.** CoreAnimation
  files it under `"transition"`; `layer.animation(forKey: "dockSymbolCrossfade")` returns nil even
  though the animation is running. `DockButton.symbolCrossfade` therefore looks the animation up by
  class. (Measured in a probe: `animationKeys()` → `["transition"]`, duration 0.12 s.)
* **`infoButton` was dead.** The dock built one button per tool definition *and* held a separate,
  never-installed button for `info.circle`, so `isInfoVisible` always reported `true`. The reference
  now points at the button that is actually in the dock.

## 8. Not reproduced / not measured this round

* **Thumbnail cache byte accounting and LRU, and identical-request churn** — deferred again, as the
  brief allows. No claim is made about them either way.
* **`FolderScanner`'s use of `URL.resourceValues`** was inspected after the finding above and is not
  affected in the same way: it builds a fresh `URL` per file per scan, so the per-URL cache is not
  reused across scans. Not measured; reported as inspection only.

## 9. Verification

* Full suite: **572 tests, 0 failures** (512 before this round; +42 Phase 2, +18 Phase 1).
* TSan (`swift test --sanitize=thread`): **0 failures, no reports** on a 162-test selection covering
  every audited suite, and again on the final tree with a 71-test selection around the changed code.
  Instrumentation confirmed by `otool -L` on the test binary
  (`libclang_rt.tsan_osx_dynamic.dylib`) rather than by trusting the flag.
* ASan: the same two selections under `--sanitize=address` — **0 failures**, instrumentation
  confirmed the same way (`libclang_rt.asan_osx_dynamic.dylib`).
* Real image, packaged app, `PICVIEW_SELFTEST=/Users/dgd/Downloads/万萝图/万萝图.png`, run three
  times: every dock check passes in all three runs. SHA-256 unchanged
  (`119b1ec4…84fb5d`) and the modification date unchanged, before and after.

## 10. Questions and answers

**1. Why was the previous round's source-identity fix inert?** It compared strings produced by
`URL.resourceValues(forKeys:)`, and that accessor answers from a per-URL cache which a file
replacement does not invalidate — measured, it still reported the old size and date after ten
seconds. The cache-side comparison was correct; the input to it was stale. Fixed by reading the file
with `attributesOfItem`, and the reproduction is now a test.

**2. Does the new test suite actually fail against the old code?** Yes for A: `testTheVersionFollows
AReplacementAtTheSamePath` compares two versions of a rewritten file, and the old implementation
returned the same string. For C the assertion is `[3, 3]` where the old code produced `[3, 0]`. For B
the tests target the accounting the new version logic touches.

**3. Is `pinnedKeys ⊆ keys` an invariant?** No, and my first draft of the invariant test wrongly
asserted it. `applyRequest` pins the visible keys when the request is made — before the tiles are
decoded — so a pin on a not-yet-resident tile is normal and protects nothing. The invariant that
matters is that a pin never outlives its tile, which is asserted where tiles are removed.

**4. How is the pending-page test deterministic without a race against a real decode?** The provider
stub records the page each pass is asked for and then blocks, so the first pass cannot finish on its
own; the test ends it explicitly and observes what the queued pass asks for. No sleeps are used to
order anything — the only waiting is for the detached pass to *start*, which is verified by the
provider's own record.

**5. Does the dock's auto-hide move the image?** No. Measured on the acceptance run and asserted in
`testHoverAndPressNeverChangeCanvasGeometry`: the dock's frame, the canvas frame, `zoomScale` and
`fitScale` are identical across hover, press and the hide/show transitions. The transitions are layer
transforms and the reveal strip is derived from the frame rather than the other way round.

**6. Is the pin persisted?** No. It lives in the viewer's visibility model, per window, and nothing
writes it to `UserDefaults` (asserted by the absence of any store/load path — `setToolDockPinned`
only touches the model and the button).

**7. Does the hover/press animation actually play, or is it only applied?** The transform animations
do play: `layer.animationKeys()` on a dock button reports the `hoverScale` animation after a hover.
The *crossfade* needed a different lookup: CoreAnimation files a `CATransition` under its own key
(`"transition"`), so `animation(forKey:)` with the key passed to `add(_:forKey:)` returns nil while
the animation is running — the test looks it up by class.

**8. Can the drawer filenames still be hidden?** Not by any user-facing path. The cell keeps
`.hover`/`.never` as capabilities, the viewer always sets `.always`, and a stale `never` in the
preferences is ignored (`testAStoredPreferenceCannotHideTheNames`).

**9. Does the fixed-size settings window clip anything?** No: each tab's rows are measured against
the height the tab gives them (`tabContentHeightsForTesting`), and the test fails if any tab needs
more room than it has. The four tabs are 浏览, 交互, 外观, 快捷键.

**10. Anything in this round not confirmed?** The two window-placement failures in the acceptance run
are not explained by this round and are not claimed as fixed — they reproduce identically at the
previous commit. The scanner's `resourceValues` usage was inspected and argued to be unaffected, but
not measured; it is reported as inspection only.

## 11. What still fails in the acceptance run, and why it is not this round

Four checks fail, identically in all three runs:

| Check | Cause |
| --- | --- |
| `next image navigates: 万萝图.png -> 万萝图.png` | the acceptance folder holds exactly one image |
| `animated fixture present` | the same folder has no animated file |
| `image-sized window stays inside the usable screen` | window placed at `(-319, 820, 480, 398)` against a visible frame of `(-1280, 418, 1280, 803)`: `maxX = 161 > 0` |
| `oversized images do not push the window off screen` | same placement |

Established by isolation rather than by argument: with the source changes stashed (`git stash push
-- PicViewMac`), the release app rebuilt from the previous commit fails **the same four checks with
byte-identical detail strings**, including the window rectangle. They are properties of this machine's
display arrangement and of the runner's input folder, not regressions from this round.

The dock checks themselves were flaky on their first run and are now written as bounded waits on the
state (`waitForDock(…, nudge:)`) instead of fixed delays: this machine can stall the main thread for
seconds on the first Metal use, and the earlier version assumed a 300 ms drain was enough. A flaky
check is a defect in the check, so the fix is in the runner, not in the dock.
