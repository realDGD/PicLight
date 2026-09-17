#!/bin/bash
# Takes N animated-playback samples from a single build, for the energy A/B.
#
# The question this exists to answer: is the per-drawn-frame energy of the animated
# path above the recorded baseline because of a real change, or because a single run
# does not measure anything? One build, N runs, same drill as run-e4.sh otherwise.
#
# Usage: sample-animation.sh <ref> <samples> <label> [ENV=value ...]
#   e.g. sample-animation.sh HEAD 5 metal-on
#        sample-animation.sh HEAD 5 metal-off PICLIGHT_DISABLE_METAL=1
#        sample-animation.sh 123d943 5 baseline
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/benchmarks/LargeImagePolicyBench"
REF="$1"; N="$2"; LABEL="$3"; shift 3
IMAGE="${PICLIGHT_BENCH_FIXTURES:-/tmp/piclight-bench/fixtures}/anim-1000.gif"
WORK="$HERE/.work/e4-anim-$LABEL"
OUT="$HERE/results/anim-ab-$LABEL.txt"

test -f "$IMAGE" || { echo "animation fixture not found: $IMAGE"; exit 1; }

echo "== building instrumented app from $REF ($LABEL) =="
rm -rf "$WORK"; mkdir -p "$WORK"
git -C "$ROOT" archive "$REF" | tar -x -C "$WORK"
# A revision that predates the anchored instrumentation is instrumented with the
# whole-file overlay of the era instead (INSTR_REF names that revision). The energy
# counter and the draw/ping counters are byte-identical between the two forms — the
# overlay was replaced because it silently reverted production code, not because the
# measurement changed.
if [ -n "${INSTR_REF:-}" ]; then
    echo "   instrumentation: whole-file overlay from $INSTR_REF"
    rm -rf "$WORK/.instr"; mkdir -p "$WORK/.instr"
    git -C "$ROOT" archive "$INSTR_REF" benchmarks/LargeImagePolicyBench/instrumentation/PicViewMac \
        | tar -x -C "$WORK/.instr"
    cp -R "$WORK/.instr/benchmarks/LargeImagePolicyBench/instrumentation/PicViewMac/." "$WORK/PicViewMac/"
    rm -rf "$WORK/.instr"
else
    python3 "$HERE/instrumentation/apply.py" "$WORK"
fi
( cd "$WORK" && swift build -c release )

{
    echo "### $LABEL — ref $REF, $(git -C "$ROOT" rev-parse --short "$REF" 2>/dev/null || echo "$REF"), $(date)"
    echo "### env: ${*:-none}"
    echo "### machine: $(sysctl -n vm.swapusage) | load $(sysctl -n vm.loadavg)"
    echo "run draws frames energy_mJ traversals ping_p95_ms ping_max_ms mJ_per_frame"
} > "$OUT"

for i in $(seq 1 "$N"); do
    env "$@" PICLIGHT_TTI_BENCH="$IMAGE" PICLIGHT_BENCH_SECONDS=20 \
        "$WORK/.build/release/PicViewMac" > /tmp/anim-run.txt 2> /tmp/anim-trace.txt || true
    python3 - "$i" /tmp/anim-run.txt /tmp/anim-trace.txt >> "$OUT" <<'PY'
import re, sys
index, run_path, trace_path = sys.argv[1], sys.argv[2], sys.argv[3]
run = open(run_path, errors="replace").read()
trace = open(trace_path, errors="replace").read()

def value(name):
    m = re.search(rf"{name}\s*=\s*([0-9.]+)", run)
    return float(m.group(1)) if m else None

draws = value("canvas_draws")
frames = value("frames_applied")
energy = value("open_energy_mJ")
m = re.search(r"full_stream_traversals = (\d+)", run)
traversals = int(m.group(1)) if m else None
pings = sorted(int(x) for x in re.findall(r"mainThreadLatency=\s*(\d+)ms", trace))
p95 = pings[min(len(pings) - 1, int(round(0.95 * (len(pings) - 1))))] if pings else None
maxping = pings[-1] if pings else None
per_frame = round(energy / draws, 1) if energy and draws else None
print(index, draws, frames, energy, traversals, p95, maxping, per_frame)
PY
    tail -1 "$OUT"
done

echo "== $LABEL summary =="
python3 - "$OUT" <<'PY'
import statistics, sys
rows = [l.split() for l in open(sys.argv[1]) if l and l[0].isdigit()]
cols = ["draws", "frames", "energy_mJ", "traversals", "ping_p95_ms", "ping_max_ms", "mJ_per_frame"]
for i, name in enumerate(cols):
    values = [float(r[i + 1]) for r in rows if r[i + 1] != "None"]
    if not values:
        print(f"  {name:14} not recorded")
        continue
    if name == "traversals":
        print(f"  {name:14} {values}")
        continue
    mean = statistics.mean(values)
    spread = (max(values) - min(values)) / mean * 100 if mean else 0
    print(f"  {name:14} mean {mean:9.2f}  min {min(values):9.2f}  max {max(values):9.2f}  spread {spread:5.1f}%")
print(f"  samples        {len(rows)}")
PY
