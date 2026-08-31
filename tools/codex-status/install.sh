#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="${CODEX_STATUS_TEST_HOME:-$HOME}"
SUPPORT_DIR="$USER_HOME/.config/quota-widget"
APP_DIR="$USER_HOME/Applications/Codex 状态.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/AIQuota"
LEGACY_APP_DIR="$USER_HOME/Applications/AI Quota.app"
LEGACY_EXECUTABLE="$LEGACY_APP_DIR/Contents/MacOS/AIQuota"

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

SOURCE_STAMP="$SCRIPT_DIR/bin/AIQuota.source-sha256"
if [[ ! -f "$SOURCE_STAMP" ]] || \
   [[ "$(shasum -a 256 "$SCRIPT_DIR/app/main.swift" | awk '{print $1}')" != "$(tr -d '[:space:]' < "$SOURCE_STAMP")" ]]; then
  echo "错误：预编译 AIQuota 与 main.swift 不一致，请先运行 ./build.sh。"
  exit 3
fi

if [[ ! -f "$USER_HOME/.codex/auth.json" ]]; then
  echo "提示：尚未检测到 Codex 登录态。App 可以安装，但额度会在登录 Codex 后才显示。"
fi

BUILD_ROOT="$(mktemp -d)"
cleanup() {
  rm -rf "$BUILD_ROOT"
  rm -f "$SUPPORT_DIR/quota_fetch.py.next" "$SUPPORT_DIR/diagnostics.py.next"
}
trap cleanup EXIT
BUILD_APP="$BUILD_ROOT/Codex 状态.app"
mkdir -p "$BUILD_APP/Contents/MacOS"
cp "$SCRIPT_DIR/app/Info.plist" "$BUILD_APP/Contents/Info.plist"
cp "$SCRIPT_DIR/bin/AIQuota" "$BUILD_APP/Contents/MacOS/AIQuota"
chmod 755 "$BUILD_APP/Contents/MacOS/AIQuota"
codesign --force --sign - "$BUILD_APP" >/dev/null
codesign --verify --deep --strict "$BUILD_APP"

# 先完成 App 构建与签名验证，再更新运行脚本，避免构建失败时留下新旧版本混用。
mkdir -p "$USER_HOME/Applications" "$SUPPORT_DIR"
chmod 700 "$SUPPORT_DIR"
cp "$SCRIPT_DIR/quota_fetch.py" "$SUPPORT_DIR/quota_fetch.py.next"
cp "$SCRIPT_DIR/diagnostics.py" "$SUPPORT_DIR/diagnostics.py.next"
chmod 700 "$SUPPORT_DIR/quota_fetch.py.next" "$SUPPORT_DIR/diagnostics.py.next"

if [[ ! -f "$SUPPORT_DIR/config.json" ]]; then
  cp "$SCRIPT_DIR/config.example.json" "$SUPPORT_DIR/config.json"
fi
chmod 600 "$SUPPORT_DIR/config.json"

if [[ "${CODEX_STATUS_SKIP_STOP:-0}" != "1" ]]; then
  for app_executable in "$EXECUTABLE" "$LEGACY_EXECUTABLE"; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < <(pgrep -f -x "$app_executable" 2>/dev/null || true)
  done
fi
for existing_app in "$APP_DIR" "$LEGACY_APP_DIR"; do
  if [[ ! -d "$existing_app" ]]; then
    continue
  fi
  mkdir -p "$USER_HOME/.Trash"
  APP_NAME="$(basename "$existing_app" .app)"
  BACKUP_APP="$USER_HOME/.Trash/$APP_NAME-更新前-$(date +%Y%m%d-%H%M%S).app"
  mv "$existing_app" "$BACKUP_APP"
  echo "旧版本已移到废纸篓：$BACKUP_APP"
done
mv "$BUILD_APP" "$APP_DIR"
mv "$SUPPORT_DIR/quota_fetch.py.next" "$SUPPORT_DIR/quota_fetch.py"
mv "$SUPPORT_DIR/diagnostics.py.next" "$SUPPORT_DIR/diagnostics.py"
if [[ "${CODEX_STATUS_SKIP_LAUNCH:-0}" != "1" ]]; then
  open "$APP_DIR"
fi

echo ""
if [[ "${CODEX_STATUS_SKIP_LAUNCH:-0}" == "1" ]]; then
  echo "Codex 状态已安装（未启动）。"
else
  echo "Codex 状态已安装并启动。"
fi
echo "App：$APP_DIR"
echo "Python：$PYTHON"
echo "如需开机启动，请在 系统设置 → 通用 → 登录项 中手动添加。"
