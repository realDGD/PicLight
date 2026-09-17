# Task 10 — Quick Look spike (report only, not integrated)

Target: `~/Downloads/万萝图/万萝图.png`, 1.929 GiB, 48000×32000, the investigation image.
Tool: `benchmarks/QuickLookSpike/main.swift` (`./build.sh` → `qlspike`), run 2026-09-18.
Raw output: `qlspike-run.txt` (first invocation, nothing cached) and `qlspike-rerun.txt`
(second invocation, separate process).

## What was measured

| Request | Wall time | Result | QL helper peak RSS |
| --- | --- | --- | --- |
| 2048, cold | 16 013 ms | 2048×1365, type = thumbnail (real image, not an icon) | 0.02–0.04 GiB |
| 2048, warm (same process) | 8 ms | 2048×1365 | none observed |
| 2048, "cold" in a **new process** | 7 ms | 2048×1365 | none observed |
| 4096, cold | 15 920 ms | **error** (`QLThumbnailErrorDomain` 0) | 0.04 GiB |
| 4096, warm | 16 036 ms | **error** again (failures are not cached) | 0.04 GiB |
| control: own `CGImageSourceCreateThumbnailAtIndex`, page cache warm, 2048 | 16 254 ms | 2048×1365, own footprint peak 0.09 GiB | — |
| control: same at 4096 | 16 098 ms | 4096×2731, own footprint peak 0.24 GiB | — |

## Cold vs warm is not page cache

The file's page cache cannot explain a 7 ms reply: the control above performs the same
thumbnail decode **with the file already resident** and still costs 16.25 s, because PNG
inflate dominates. The 7 ms pass in a fresh process therefore comes from Quick Look's own
cache, which `lsof` locates on disk:

```text
/private/var/folders/f8/.../C/com.apple.quicklook.ThumbnailsAgent/com.apple.QuickLook.thumbnailcache/
  thumbnails.data   42 228 792 bytes
  index.sqlite         507 904 bytes (+ 2.6 MB -wal)
  cloudthumbnails.db    32 768 bytes
```

`ThumbnailsAgent` (RSS 37 MB) holds `thumbnails.data` open, so the entry survives the client
process exiting. One link in that chain is inferred, not verified: TCC refuses to read the
index, so "the entry is keyed to this file" rests on Quick Look's documented file-identity
keying plus the 7 ms repeat, not on direct inspection of the row. The store lives under
`/private/var/folders/.../C` — a system-managed, purgeable cache the app neither controls nor
can count on. The unrelated `~/Library/Caches/ThumbnailsCache` was byte-for-byte unchanged
across every run (824 746 bytes, 22 files), so that is not where this went.

## Verdict: negative — do not integrate

The bar in the plan is "a repeatable materially earlier preview". It is not met:

- **First preview is not earlier.** 16.0 s through Quick Look versus 16.25 s for our own
  streaming thumbnail and ≈16–18 s for the bounded decode — the same decode, the same cost.
  Quick Look's only structural advantage is that the cost lands in a helper process instead of
  ours; it does not make the wait shorter.
- **The warm win is not something the app can own.** It is Quick Look's cache, capped at 2048
  (the 4096 request fails *after* doing the full decode and fails again on every retry), stored
  in a purgeable system directory, and unavailable to the app's own level policy — the levels
  we actually use are 1024/2048/4096/8192 with 8192 for a native-detail window.
- **It would fight an existing decision.** Oversized drawer items are deliberately
  placeholders; routing them through Quick Look would reintroduce a ~16 s background decode per
  oversized item, which is the waste the placeholder policy exists to avoid.
- **Our own cache already covers the useful case.** The on-screen image and preloaded
  neighbours are served from `DecodeCache` in ~0 ms within a session, and a repeat visit costs
  one bounded decode (≈16–18 s) — the same as Quick Look's cold path.

Recorded as a negative result; per Task 10 step 3 nothing was integrated, and
`grep -r QLThumbnail|QuickLook PicViewMac/` stays empty (checked in Task 9).
