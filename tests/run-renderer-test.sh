#!/bin/sh
set -eu
test_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
test_binary=$(mktemp -t scorpi-viewer-renderer-test)
trap 'rm -f "$test_binary"' EXIT
xcrun clang -fobjc-arc -fblocks -UNDEBUG \
    -framework Cocoa -framework Metal -framework MetalKit -framework IOSurface \
    "$test_dir/renderer_test.m" "$test_dir/../ScorpiViewer/Renderer.m" \
    -o "$test_binary"
MTL_DEBUG_LAYER=1 "$test_binary" "$test_dir/../ScorpiViewer/Shaders.metal"
