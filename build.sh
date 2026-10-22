#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${LIGHTPASTE_BUILD_DIR:-$PROJECT_DIR/.build}"
APP_DIR="$PROJECT_DIR/轻贴.app"
APP_VERSION="0.7.0"
APP_BUILD="7"
# Distribution signing (optional). Without these the app is ad-hoc signed for this Mac only.
#   LIGHTPASTE_SIGN_IDENTITY  e.g. "Developer ID Application: Name (TEAMID)"
#   LIGHTPASTE_NOTARY_PROFILE a profile saved with: xcrun notarytool store-credentials <profile>
SIGN_IDENTITY="${LIGHTPASTE_SIGN_IDENTITY:-}"
# Self-signed identity from Scripts/MakeLocalSigningIdentity.sh; used when present instead of ad-hoc,
# so this Mac keeps the Accessibility permission across rebuilds.
LOCAL_IDENTITY="${LIGHTPASTE_LOCAL_IDENTITY:-LightPaste Local Signing}"
NOTARY_PROFILE="${LIGHTPASTE_NOTARY_PROFILE:-}"
if [[ -n "$NOTARY_PROFILE" && -z "$SIGN_IDENTITY" ]]; then
  print -u2 "公证需要 Developer ID 签名：请同时设置 LIGHTPASTE_SIGN_IDENTITY。"
  exit 1
fi
mkdir -p "$BUILD_DIR/module-cache" "$BUILD_DIR/package-cache" "$BUILD_DIR/config" "$BUILD_DIR/security"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
export SWIFT_MODULECACHE_PATH="$BUILD_DIR/module-cache"
swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" \
  --cache-path "$BUILD_DIR/package-cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" \
  --disable-sandbox --disable-keychain --manifest-cache local -c release --product LightPaste
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/package-cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --disable-sandbox --disable-keychain --manifest-cache local -c release --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/LightPaste" "$APP_DIR/Contents/MacOS/LightPaste"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>轻贴</string>
<key>CFBundleDisplayName</key><string>轻贴</string>
<key>CFBundleIdentifier</key><string>com.local.lightpaste</string>
<key>CFBundleVersion</key><string>$APP_BUILD</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleExecutable</key><string>LightPaste</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.local.lightpaste.clip-id</string>
<key>UTTypeDescription</key><string>轻贴历史条目</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict><dict>
<key>UTTypeIdentifier</key><string>com.local.lightpaste.favorites</string>
<key>UTTypeDescription</key><string>轻贴收藏备份</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>lightpaste</string></array></dict>
</dict></array>
<key>NSPasteboardUsageDescription</key><string>在本机保存你复制的内容，方便搜索、收藏并再次粘贴。</string>
<key>NSAccessibilityUsageDescription</key><string>将选中的内容粘贴回你正在使用的应用。</string>
</dict></plist>
PLIST
if [[ -f "$PROJECT_DIR/Scripts/MakeIcon.swift" ]]; then
  swift -module-cache-path "$BUILD_DIR/module-cache" "$PROJECT_DIR/Scripts/MakeIcon.swift" "$BUILD_DIR/AppIcon.iconset"
  python3 "$PROJECT_DIR/Scripts/PackIcon.py" "$BUILD_DIR/AppIcon.iconset" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  if security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
    /usr/bin/codesign --force --sign "$LOCAL_IDENTITY" --identifier com.local.lightpaste "$APP_DIR"
    print "已生成：$APP_DIR（$APP_VERSION，本机固定签名 $LOCAL_IDENTITY，重新构建后辅助功能授权保留）"
  else
    /usr/bin/codesign --force --sign - --identifier com.local.lightpaste "$APP_DIR"
    print "已生成：$APP_DIR（$APP_VERSION，本机临时签名；运行 Scripts/MakeLocalSigningIdentity.sh 可保留授权）"
  fi
  exit 0
fi

# Hardened runtime and a secure timestamp are required for notarization.
/usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier com.local.lightpaste "$APP_DIR"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_DIR"
print "已签名：$APP_DIR（$APP_VERSION，$SIGN_IDENTITY）"
[[ -z "$NOTARY_PROFILE" ]] && exit 0

ARCHIVE="$BUILD_DIR/轻贴-$APP_VERSION.zip"
rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
/usr/sbin/spctl --assess --type execute --verbose "$APP_DIR"
# Re-archive the stapled app so the download opens offline without a Gatekeeper lookup.
rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE"
print "已公证：$ARCHIVE"
