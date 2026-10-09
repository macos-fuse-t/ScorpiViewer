#!/bin/sh
set -eu
test_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
test_binary=$(mktemp -t scorpi-viewer-scroll-test)
trap 'rm -f "$test_binary"' EXIT
xcrun clang -fobjc-arc -fblocks -UNDEBUG \
    -framework Cocoa -framework Metal -framework MetalKit -framework IOSurface \
    "$test_dir/scroll_test.m" -o "$test_binary"
"$test_binary"
