#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
swiftc -warnings-as-errors -O \
  -o "$SCRIPT_DIR/bin/AIQuota" "$SCRIPT_DIR/app/main.swift"
codesign --force --sign - "$SCRIPT_DIR/bin/AIQuota" >/dev/null
shasum -a 256 "$SCRIPT_DIR/app/main.swift" | awk '{print $1}' \
  > "$SCRIPT_DIR/bin/AIQuota.source-sha256"
echo "AIQuota binary rebuilt."
