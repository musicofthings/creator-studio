#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target StudioDomain
build_path="$(swift build --show-bin-path)"
test_binary="$(mktemp -t creator-compositor-test)"
trap 'rm -f "$test_binary"' EXIT
swiftc -target "$(uname -m)-apple-macos15.0" -parse-as-library -swift-version 6 -I "$build_path/Modules" \
  "$build_path"/StudioDomain.build/*.swift.o \
  Apps/CreatorStudioMac/Sources/MacTimelineCompositor.swift \
  scripts/test_timeline_compositor.swift -o "$test_binary"
"$test_binary"
