#!/usr/bin/env bash
# Local reference app only. Game data and saves remain outside the bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN=build/oracle-clang/pd.arm64
test -f "$BIN" || { echo 'Run scripts/build-macos.sh first.' >&2; exit 1; }
python3 scripts/check-apple-platform.py macosx "$BIN"
APP="$ROOT/build/mac-reference/Perfect Dark Reference.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/perfectdark"
cp vendor/dabs-mod/LICENSE "$APP/Contents/Resources/ENGINE-LICENSE"
cp LICENSE "$APP/Contents/Resources/APPLE-SHELL-LICENSE"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>perfectdark</string>
  <key>CFBundleIdentifier</key><string>local.darkpad.reference</string>
  <key>CFBundleName</key><string>Perfect Dark Reference</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "$APP"
