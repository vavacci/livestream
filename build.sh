#!/usr/bin/env bash
# build.sh — 一键出 .tipa：xcodebuild → ldid → zip
#
# 用法：
#   1. 把本脚本、trollstore.xcconfig、Entitlements/ 拷到你的 iOS App 项目根
#   2. 修改下面 APP_NAME / SCHEME 为你的 App 名字
#   3. 在 Entitlements/<AppName>.entitlements 和 Entitlements/<ExtName>.entitlements
#      里写好真实 entitlements（含 application-groups 等 capability）
#   4. ./build.sh
#
# 依赖：
#   - macOS + Xcode（提供 xcodebuild、plutil）
#   - ldid (Procursus 版)：brew install ldid
#
set -euo pipefail

cd "$(dirname "$0")"                                 # 切到脚本所在目录（= 项目根）

# ====== 你需要改的两个变量 ======
APP_NAME="livestream"
SCHEME="livestream"
# ================================

DERIVED="build"
APP="$DERIVED/Build/Products/Release-iphoneos/${APP_NAME}.app"

# 1. 前置依赖
if ! command -v ldid >/dev/null; then
    echo "ldid not found. Install via: brew install ldid" >&2
    exit 1
fi
if [[ ! -f trollstore.xcconfig ]]; then
    echo "trollstore.xcconfig not found in $(pwd)" >&2
    echo "  Copy it from docs/templates/trollstore.xcconfig first." >&2
    exit 1
fi
if [[ ! -f "Entitlements/${APP_NAME}.entitlements" ]]; then
    echo "Entitlements/${APP_NAME}.entitlements not found" >&2
    echo "  Create it from docs/templates/Entitlements/MyApp.entitlements first." >&2
    exit 1
fi

# 2. xcodebuild —— 关键就是 -xcconfig 那一行把 trollstore.xcconfig 挂上去
echo "==> [1/3] xcodebuild"
xcodebuild \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED" \
    -destination 'generic/platform=iOS' \
    -sdk iphoneos \
    -configuration Release \
    -xcconfig trollstore.xcconfig

if [[ ! -d "$APP" ]]; then
    echo "App bundle not built: $APP" >&2
    exit 2
fi

# 3. ldid 后处理：清扩展属性 → 注入 entitlements → 兜底递归签
echo
echo "==> [2/3] ldid sign + inject entitlements"
xattr -rc "$APP"

# 3a. 主 App
APP_BIN=$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")
ldid -S"Entitlements/${APP_NAME}.entitlements" "$APP/$APP_BIN"
echo "  [app] $APP_BIN ← Entitlements/${APP_NAME}.entitlements"

# 3b. 所有 Extension：每个 *.appex 都尝试匹配同名 .entitlements 文件
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
        echo "  [ext] $ext_name ← (ad-hoc only, no entitlements file)"
    fi
done

# 3c. 兜底：尝试递归 ad-hoc 签 Frameworks / 其它 dylib
#      ldid 旧版本对含 entitlements 的子 binary 递归签时会 assert (flag_S)；
#      失败时降级为逐文件签，再失败就跳过——Xcode 在 CODE_SIGNING_ALLOWED=NO
#      下通常已经替我们 ad-hoc 签好了 Frameworks。
if ! ldid -s "$APP" 2>/dev/null; then
    echo "  ldid -s recursive failed (likely old ldid + entitled child binary)"
    echo "  falling back to per-dylib signing"
    while IFS= read -r f; do
        ldid -S "$f" 2>/dev/null || true
    done < <(find "$APP" -type f \( -name "*.dylib" -o -name "*.so" \))
fi

# 4. 打 .tipa（其实就是 .ipa 改后缀）
echo
echo "==> [3/3] pack .tipa"
rm -rf Payload "${APP_NAME}.ipa" "${APP_NAME}.tipa"
mkdir Payload
cp -r "$APP" Payload/
zip -qr "${APP_NAME}.ipa" Payload
cp "${APP_NAME}.ipa" "${APP_NAME}.tipa"
rm -rf Payload

# 5. 校验
echo
echo "==> verify"
echo "App entitlements (head):"
ldid -e "$APP/$APP_BIN" | head -15
echo
echo "Output: ${APP_NAME}.tipa ($(du -h "${APP_NAME}.tipa" | cut -f1))"
