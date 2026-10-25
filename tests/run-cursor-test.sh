#!/bin/sh
set -eu
test_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
test_binary=$(mktemp -t scorpi-viewer-cursor-test)
trap 'rm -f "$test_binary"' EXIT
xcrun clang -fobjc-arc -fblocks -UNDEBUG \
    -framework Cocoa -framework Metal -framework MetalKit -framework IOSurface \
    "$test_dir/cursor_test.m" "$test_dir/../ScorpiViewer/MouseLockController.m" "$test_dir/../ScorpiViewer/GuestCursorOverlay.m" -o "$test_binary"
"$test_binary"
