#!/bin/zsh
# Builds "KVM Switcher.app" (menu-bar only, no Dock icon) into .build/ and prints its path.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0-dev}"
swift build -c release --product KVMMenuBar >&2
swift build -c release --product kvmctl >&2

APP=".build/KVM Switcher.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/KVMMenuBar "$APP/Contents/MacOS/KVMSwitcher"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.kvm-switcher</string>
  <key>CFBundleName</key><string>KVM Switcher</string>
  <key>CFBundleExecutable</key><string>KVMSwitcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# A real identity keeps the Accessibility grant across rebuilds; ad-hoc (CI) loses it every build.
IDENTITY="${KVM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" "$APP" >&2
echo "$(pwd)/$APP"
