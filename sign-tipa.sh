#!/usr/bin/env bash
# sign-tipa.sh — 给已 build 出来的 .app 用 ldid 注入 entitlements + 递归签名
#
# 用法：./sign-tipa.sh /path/to/MyApp.app
# 在 Makefile 中由 `make sign` 触发。
#
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "Usage: $0 /path/to/MyApp.app" >&2
    exit 1
fi

if ! command -v ldid >/dev/null; then
    echo "ldid not found. Install via: brew install ldid" >&2
    exit 1
fi

xattr -rc "$APP"

# 1. 主 App
APP_BIN=$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")
APP_NAME=$(basename "$APP" .app)
APP_ENTS="Entitlements/${APP_NAME}.entitlements"

if [[ -f "$APP_ENTS" ]]; then
    ldid -S"$APP_ENTS" "$APP/$APP_BIN"
    echo "  [app] $APP_BIN ← $APP_ENTS"
else
    ldid -S "$APP/$APP_BIN"
    echo "  [app] $APP_BIN ← (ad-hoc only)"
fi

# 2. 所有 Extension
for ext in "$APP/PlugIns/"*.appex; do
    [[ -d "$ext" ]] || continue
    ext_name=$(basename "$ext" .appex)
    ext_bin=$(plutil -extract CFBundleExecutable raw "$ext/Info.plist")
    ext_ents="Entitlements/${ext_name}.entitlements"
    if [[ -f "$ext_ents" ]]; then
        ldid -S"$ext_ents" "$ext/$ext_bin"
        echo "  [ext] $ext_name ← $ext_ents"
    else
        ldid -S "$ext/$ext_bin"
        echo "  [ext] $ext_name ← (ad-hoc only)"
    fi
done

# 3. 兜底：尝试递归签，失败则降级为逐 dylib 签
if ! ldid -s "$APP" 2>/dev/null; then
    echo "  ldid -s recursive failed; falling back to per-dylib"
    while IFS= read -r f; do
        ldid -S "$f" 2>/dev/null || true
    done < <(find "$APP" -type f \( -name "*.dylib" -o -name "*.so" \))
fi

# 4. 校验
echo
echo "===== verification ====="
codesign -dvv "$APP/$APP_BIN" 2>&1 | head -8
echo
echo "App entitlements:"
ldid -e "$APP/$APP_BIN" | head -15
