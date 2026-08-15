#!/usr/bin/env bash
# build.sh — compile the Gear menu-bar app with the Swift Command Line Tools.
# No Xcode project, no Interface Builder, no SwiftUI. Just swiftc.
#
# Run from anywhere; it operates on its own directory.
set -euo pipefail

# Resolve this script's directory so it works regardless of CWD.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

SRC="src/GearApp.swift"
BIN="build/Gear"

# macOS 13+ deployment target: NSImage(systemSymbolName:) needs 11+, and we
# want modern AppKit APIs. Apple Silicon => arm64.
TARGET="arm64-apple-macosx13"

echo "==> Compiling $SRC -> ./$BIN (target $TARGET)"
mkdir -p build
swiftc -O "$SRC" -o "$BIN" \
    -target "$TARGET" \
    -framework AppKit \
    -framework Foundation

echo ""
echo "==> Build succeeded."
echo "    Binary: $DIR/$BIN"
echo "    Launch: ./gear/Gear &   (or, from this dir:  ./Gear & )"
echo ""

# ---- Optional polish: assemble a minimal .app so Finder-launch has no Dock icon ----
# LSUIElement=true makes it a true agent app even when double-clicked in Finder.
APP="build/Gear.app"
if [[ "${1:-}" == "--app" || "${MAKE_APP:-}" == "1" ]]; then
    echo "==> Assembling minimal $APP wrapper (LSUIElement=true)"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    cp "$BIN" "$APP/Contents/MacOS/Gear"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Gear</string>
    <key>CFBundleDisplayName</key>     <string>Gear</string>
    <key>CFBundleExecutable</key>      <string>Gear</string>
    <key>CFBundleIdentifier</key>      <string>com.local.switchable-llm-gear</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST
    echo "    Bundle: $DIR/$APP"
    echo "    Launch: open $DIR/$APP   (or:  open ./gear/build/Gear.app )"
    echo ""
fi
