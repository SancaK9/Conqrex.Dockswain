#!/usr/bin/env bash
# Build Dockswain.app (a menu-bar-only macOS app) from the Swift package.
# Usage: ./build-app.sh   ->   ./Dockswain.app
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "Building release…"
swift build -c release

BIN=".build/release/Dockswain"
BUNDLE=".build/release/Dockswain_Dockswain.bundle"
APP="Dockswain.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Dockswain"
# Bundle.module finds the resource bundle in the app's Resources dir. It must NOT
# live in Contents/MacOS — a nested .bundle there makes codesign reject the app.
[ -d "$BUNDLE" ] && cp -R "$BUNDLE" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dockswain</string>
  <key>CFBundleDisplayName</key><string>Dockswain</string>
  <key>CFBundleIdentifier</key><string>com.conqrex.dockswain</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Dockswain</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- menu-bar only: no Dock icon -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Sign with the stable self-signed identity if it exists (so the Keychain "Always
# Allow" for your SSH passwords survives rebuilds). Falls back to ad-hoc otherwise.
IDENTITY="Dockswain Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    SIGN="$IDENTITY"
else
    SIGN="-"
    echo "Tip: run ./make-signing-cert.sh once for a stable signature (fewer Keychain prompts)."
fi
# Sign the nested resource bundle first, then the app (avoids --deep, which is finicky).
[ -d "$APP/Contents/Resources/Dockswain_Dockswain.bundle" ] && \
    codesign --force --sign "$SIGN" "$APP/Contents/Resources/Dockswain_Dockswain.bundle" >/dev/null 2>&1 || true
codesign --force --sign "$SIGN" "$APP" >/dev/null 2>&1 || \
    echo "Warning: codesign failed; the app may still run but Keychain prompts can recur."

echo "Built $APP  (signed with: $SIGN)"
echo "Run it:   open $APP        (look for the ⚓ in your menu bar)"
echo "Install:  cp -R $APP /Applications/"
