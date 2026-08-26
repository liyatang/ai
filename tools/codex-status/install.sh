#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="${CODEX_STATUS_TEST_HOME:-$HOME}"
SUPPORT_DIR="$USER_HOME/.config/quota-widget"
APP_DIR="$USER_HOME/Applications/Codex 状态.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/AIQuota"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "错误：当前安装包仅支持 Apple Silicon（M 系列芯片）。"
  exit 1
fi

PYTHON=""
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [[ -x "$candidate" ]] && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
    PYTHON="$candidate"
    break
  fi
done

if [[ -z "$PYTHON" ]]; then
  echo "错误：未找到 Python 3.9 或更高版本。"
  echo "请让 Codex 在获得你的确认后安装 Python，再重新运行本脚本。"
  exit 2
fi

if [[ ! -f "$USER_HOME/.codex/auth.json" ]]; then
  echo "提示：尚未检测到 Codex 登录态。App 可以安装，但额度会在登录 Codex 后才显示。"
fi

mkdir -p "$USER_HOME/Applications" "$SUPPORT_DIR"
chmod 700 "$SUPPORT_DIR"

cp "$SCRIPT_DIR/quota_fetch.py" "$SUPPORT_DIR/quota_fetch.py"
cp "$SCRIPT_DIR/diagnostics.py" "$SUPPORT_DIR/diagnostics.py"
chmod 700 "$SUPPORT_DIR/quota_fetch.py" "$SUPPORT_DIR/diagnostics.py"

if [[ ! -f "$SUPPORT_DIR/config.json" ]]; then
  cp "$SCRIPT_DIR/config.example.json" "$SUPPORT_DIR/config.json"
fi
chmod 600 "$SUPPORT_DIR/config.json"

BUILD_ROOT="$(mktemp -d)"
trap 'rm -rf "$BUILD_ROOT"' EXIT
BUILD_APP="$BUILD_ROOT/Codex 状态.app"
mkdir -p "$BUILD_APP/Contents/MacOS"
cp "$SCRIPT_DIR/app/Info.plist" "$BUILD_APP/Contents/Info.plist"
cp "$SCRIPT_DIR/bin/AIQuota" "$BUILD_APP/Contents/MacOS/AIQuota"
chmod 755 "$BUILD_APP/Contents/MacOS/AIQuota"
codesign --force --sign - "$BUILD_APP" >/dev/null
codesign --verify --deep --strict "$BUILD_APP"

if [[ "${CODEX_STATUS_SKIP_STOP:-0}" != "1" ]]; then
  pkill -x AIQuota 2>/dev/null || true
fi
if [[ -d "$APP_DIR" ]]; then
  mkdir -p "$USER_HOME/.Trash"
  BACKUP_APP="$USER_HOME/.Trash/Codex 状态-更新前-$(date +%Y%m%d-%H%M%S).app"
  mv "$APP_DIR" "$BACKUP_APP"
  echo "旧版本已移到废纸篓：$BACKUP_APP"
fi
mv "$BUILD_APP" "$APP_DIR"
if [[ "${CODEX_STATUS_SKIP_LAUNCH:-0}" != "1" ]]; then
  open "$APP_DIR"
fi

echo ""
echo "Codex 状态已安装并启动。"
echo "App：$APP_DIR"
echo "Python：$PYTHON"
echo "如需开机启动，请在 系统设置 → 通用 → 登录项 中手动添加。"
