#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
sed '/^#if !TESTING$/,$d' "$PROJECT_DIR/app/main.swift" > "$BUILD_DIR/AppCore.swift"
cp "$PROJECT_DIR"/app/{Models,ProcessRunner,Resources,Drawing,Charts,Probe,CardView}.swift "$BUILD_DIR/"
cp "$SCRIPT_DIR/render_previews.swift" "$BUILD_DIR/main.swift"
xcrun swiftc -warnings-as-errors "$BUILD_DIR"/*.swift -o "$BUILD_DIR/render"
"$BUILD_DIR/render" "${1:?Provide output directory}"
