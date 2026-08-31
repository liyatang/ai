#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

sed '/^#if !TESTING$/,$d' "$PROJECT_DIR/app/main.swift" > "$BUILD_DIR/AIQuota.swift"
cp "$SCRIPT_DIR/test_main.swift" "$BUILD_DIR/main.swift"
swiftc -warnings-as-errors \
  "$BUILD_DIR/AIQuota.swift" "$BUILD_DIR/main.swift" \
  -o "$BUILD_DIR/AIQuota-card-tests"
"$BUILD_DIR/AIQuota-card-tests"
