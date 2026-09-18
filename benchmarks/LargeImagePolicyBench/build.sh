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

IN_GIT=1
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || IN_GIT=0
if [ "$IN_GIT" = "0" ]; then
    echo "note: not a git checkout; using the working-tree sources instead of '$REF'" >&2
fi

# The imaging layer is vendored as a set: the decoder, the budget/policy helpers it
# uses, and the metadata reader. Keep this list in step with the target's files.
for f in Imaging/ImageDecoder.swift \
         Imaging/ImageIODecoder.swift \
         Imaging/ImageDescriptor.swift \
         Imaging/ImageMetadata.swift \
         Imaging/DecodeCache.swift \
         Imaging/DecodeCoordinator.swift \
         Imaging/DecodeBudget.swift \
         Imaging/NativeTile.swift \
         Imaging/NativeTileProvider.swift \
         Imaging/OversizedPolicy.swift \
         Imaging/DimensionProbe.swift \
         Imaging/BitmapMaterializer.swift \
         Imaging/ImageHeaderProbe.swift \
         Imaging/ThumbnailPipeline.swift \
         Viewer/RenderImage.swift \
         Viewer/ViewportState.swift \
         Viewer/MetalImageRenderer.swift \
         Viewer/MetalLibraryLocator.swift \
         Metadata/MetadataReader.swift; do
    if [ "$IN_GIT" = "1" ]; then
        git -C "$ROOT" show "$REF:PicViewMac/$f" > "$VENDOR/$(basename "$f")"
    else
        cp "$ROOT/PicViewMac/$f" "$VENDOR/$(basename "$f")"
    fi
done

# The streaming decoder as a standalone module: the package target gets this from SwiftPM,
# a one-file swiftc build needs a module map and an archive.
mkdir -p "$WORK/mod/PicPNGStream"
cat > "$WORK/mod/PicPNGStream/module.modulemap" <<MODULEMAP
module PicPNGStream {
    header "$ROOT/PicPNGStream/include/PicPNGStream.h"
    export *
}
MODULEMAP
clang -O2 -c "$ROOT/PicPNGStream/pngstream.c" -I "$ROOT/PicPNGStream/include" -o "$WORK/pngstream.o"
ar rcs "$WORK/libPicPNGStream.a" "$WORK/pngstream.o"

DECODER_FLAGS=(-I "$WORK/mod" -Xcc -fmodule-map-file="$WORK/mod/PicPNGStream/module.modulemap" \
               -L "$WORK" -lPicPNGStream -lz)
swiftc -O -swift-version 6 "${DECODER_FLAGS[@]}" "$VENDOR"/*.swift "$HERE/bench/Probe.swift" "$HERE/bench/main.swift" -o "$WORK/picbench"
swiftc -O "$HERE/bench/gen/main.swift"       -o "$WORK/gen"
swiftc -O "$HERE/bench/minbench/main.swift"  -o "$WORK/minbench"
swiftc -O "$HERE/bench/probebench/main.swift" -o "$WORK/probebench"
swiftc -O "$HERE/bench/regionbench/main.swift" -o "$WORK/regionbench"
# The streaming decoder as a standalone module: the package target gets this from SwiftPM,
# a one-file swiftc build needs a module map and an archive.
mkdir -p "$WORK/mod/PicPNGStream"
cat > "$WORK/mod/PicPNGStream/module.modulemap" <<MODULEMAP
module PicPNGStream {
    header "$ROOT/PicPNGStream/include/PicPNGStream.h"
    export *
}
MODULEMAP
clang -O2 -c "$ROOT/PicPNGStream/pngstream.c" -I "$ROOT/PicPNGStream/include" -o "$WORK/pngstream.o"
ar rcs "$WORK/libPicPNGStream.a" "$WORK/pngstream.o"
swiftc -O -swift-version 6 "${DECODER_FLAGS[@]}" \
    "$HERE/bench/tilebench/main.swift" "$VENDOR/NativeTile.swift" "$VENDOR/NativeTileProvider.swift" \
    "$VENDOR/ViewportState.swift" "$VENDOR/DecodeBudget.swift" \
    -lz -o "$WORK/tilebench"

echo "built from $REF:"
echo "  $WORK/picbench  (A/B/E gates)"
echo "  $WORK/gen       (fixtures)"
echo "  $WORK/minbench  (D gate)"
echo "  $WORK/probebench (C gate)"
