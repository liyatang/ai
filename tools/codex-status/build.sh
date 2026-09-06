#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/sources.sh"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$SCRIPT_DIR/app/Info.plist")"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
xcrun swiftc -warnings-as-errors -O -target "arm64-apple-macosx${MIN_OS}" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -o "$BUILD_DIR/AIQuota" "$SCRIPT_DIR"/app/*.swift
ACTUAL_MIN_OS="$(xcrun vtool -show-build "$BUILD_DIR/AIQuota" | awk '/minos/ {print $2}')"
if [[ "$ACTUAL_MIN_OS" != "$MIN_OS" ]]; then
  echo "错误：二进制最低系统版本 $ACTUAL_MIN_OS 与声明 $MIN_OS 不一致。"
  exit 1
fi
codesign --force --sign - "$BUILD_DIR/AIQuota" >/dev/null
codesign --verify --strict "$BUILD_DIR/AIQuota"
mkdir -p "$SCRIPT_DIR/bin"
mv "$BUILD_DIR/AIQuota" "$SCRIPT_DIR/bin/AIQuota"
source_hash > "$SCRIPT_DIR/bin/AIQuota.source-sha256"
echo "AIQuota binary rebuilt (arm64, macOS ${MIN_OS}+)."
