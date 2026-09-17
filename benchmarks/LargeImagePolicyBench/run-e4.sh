#!/bin/bash
# E4: app-level acceptance harness.
# Exports the given revision into a scratch tree, overlays the temporary
# instrumentation (BenchTrace + counters), builds, opens the image through the
# production path, and prints the acceptance numbers:
#   full-stream traversals, open energy, main-thread stall, peak RSS/footprint.
#
# Usage: run-e4.sh [ref] [image]
#   ref    revision to measure (default 123d943, the pre-change baseline)
#   image  the multi-gigapixel image (default $PICLIGHT_BENCH_GIANT)
#
# Needs a logged-in GUI session: the app opens a real window.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/benchmarks/LargeImagePolicyBench"
REF="${1:-123d943}"
IMAGE="${2:-${PICLIGHT_BENCH_GIANT:-/Users/dgd/Downloads/万萝图/万萝图.png}}"
WORK="$HERE/.work/e4-app"

test -f "$IMAGE" || { echo "image not found: $IMAGE"; exit 1; }

HEAD_REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ "$REF" != "$HEAD_REV" ] && [ "$REF" != "HEAD" ] && [ "$REF" != "HEAD^{commit}" ]; then
    echo "note: the overlay in instrumentation/ is written against HEAD ($HEAD_REV);" >&2
    echo "      measuring $REF may not compile if the decode path has changed since." >&2
fi

echo "== hashing source image (read-only check) =="
shasum -a 256 "$IMAGE"

rm -rf "$WORK"; mkdir -p "$WORK"
git -C "$ROOT" archive "$REF" | tar -x -C "$WORK"
# The instrumentation is *applied* to the exported tree rather than overlaid as whole
# files: an overlay silently reverts production changes it predates, and the run would
# measure the old path without saying so.
python3 "$HERE/instrumentation/apply.py" "$WORK"

echo "== building instrumented app from $REF =="
( cd "$WORK" && swift build -c release )

echo "== running (this opens a window and takes ~30-60 s) =="
PICLIGHT_TTI_BENCH="$IMAGE" "$WORK/.build/release/PicViewMac" \
    > "$HERE/results/e4-run.txt" 2> "$HERE/results/e4-run-trace.txt" || true

echo "== E4 acceptance numbers =="
grep -E "full_stream_traversals|open_energy_mJ|peakRSS_getrusage|peakFootprint_sampled|footprint_at_finish|canvas_draws" "$HERE/results/e4-run.txt" || true
stall=$(grep -o 'mainThreadLatency=[ 0-9]*ms' "$HERE/results/e4-run-trace.txt" | sed 's/[^0-9]//g' | sort -n | tail -1)
echo "main_thread_stall_max_ms = ${stall:-n/a}"
echo "== hashing source image again =="
shasum -a 256 "$IMAGE"
echo "targets: traversals == 1, open energy <= ~70 J, stall p95 < 100 ms, no Image IO region > 1 GiB"
