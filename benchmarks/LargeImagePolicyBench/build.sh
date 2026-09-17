#!/bin/bash
# Builds the large-image policy benchmark harness.
# Production imaging sources are extracted from Git at build time so the harness
# always measures the same decoder the app ships (no second copy to drift).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REF="${1:-HEAD}"
HERE="$ROOT/benchmarks/LargeImagePolicyBench"
WORK="$HERE/.work"
VENDOR="$WORK/vendor"

mkdir -p "$VENDOR" "$WORK/out"

for f in Imaging/ImageDecoder.swift \
         Imaging/ImageIODecoder.swift \
         Imaging/ImageDescriptor.swift \
         Imaging/ImageMetadata.swift \
         Imaging/DecodeCache.swift \
         Imaging/DecodeCoordinator.swift \
         Imaging/ThumbnailPipeline.swift \
         Metadata/MetadataReader.swift; do
    git -C "$ROOT" show "$REF:PicViewMac/$f" > "$VENDOR/$(basename "$f")"
done

swiftc -O -swift-version 6 "$VENDOR"/*.swift "$HERE/bench/Probe.swift" "$HERE/bench/main.swift" -o "$WORK/picbench"
swiftc -O "$HERE/bench/gen/main.swift"       -o "$WORK/gen"
swiftc -O "$HERE/bench/minbench/main.swift"  -o "$WORK/minbench"
swiftc -O "$HERE/bench/probebench/main.swift" -o "$WORK/probebench"

echo "built from $REF:"
echo "  $WORK/picbench  (A/B/E gates)"
echo "  $WORK/gen       (fixtures)"
echo "  $WORK/minbench  (D gate)"
echo "  $WORK/probebench (C gate)"
