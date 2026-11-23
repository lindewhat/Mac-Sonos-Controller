#!/bin/zsh
# Builds Mac Sonos Control, signs it, installs it in /Applications and launches it.
# Usage: ./build.sh            (build + install + launch)
#        ./build.sh --no-run   (build + install only)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Mac Sonos Control"
DEST="/Applications/$APP_NAME.app"
# Assemble outside the Desktop/iCloud folders: they add hidden markings that break code signing.
BUILD_DIR="${TMPDIR:-/tmp}/mac-sonos-control-build"
APP="$BUILD_DIR/$APP_NAME.app"

# Preflight: plain-language checks, so a first-time installer gets a clear message instead of a cryptic error.
stop() { echo "\nCannot continue: $1\n" >&2; exit 1 }
[[ "$(uname -m)" == "arm64" ]] || stop "this app needs a Mac with Apple Silicon (M1 or newer)."
(( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) || stop "this app needs macOS 14 or newer. Update macOS first."
xcodebuild -version >/dev/null 2>&1 || stop "Xcode is not ready.
  1. Install Xcode from the App Store (it is free).
  2. Open Xcode once and agree to the licence if it asks.
  3. Run ./build.sh again.
If Xcode is already installed, Terminal may be pointing elsewhere. Run this once and try again:
  sudo xcode-select -s /Applications/Xcode.app"

echo "Running tests..."
swift test 2>&1 | tail -3

echo "Building..."
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/MacSonosControl"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MacSonosControl"
# SwiftPM stamps the program as built with the oldest supported macOS SDK (14). macOS then gives the app the
# old look: a nearly solid menu that ignores the "Reduce transparency" setting. Stamp the SDK that was really
# used, so the menu looks and behaves like every other current menu. Falls back quietly if vtool is missing.
SDK_VERSION="$(xcrun --show-sdk-version)"
if vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace -output "$BUILD_DIR/stamped" "$APP/Contents/MacOS/MacSonosControl" 2>/dev/null; then
  mv "$BUILD_DIR/stamped" "$APP/Contents/MacOS/MacSonosControl"
else
  echo "NOTE: could not stamp the SDK version; the menu may look older than other menus."
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signing: a stable identity keeps macOS permissions (Accessibility) across rebuilds.
# Override with SIGN_IDENTITY="..." if needed. Prefers Apple Development, then a local cert.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep -E 'Apple Development|Developer ID Application|Mac Sonos Control Local' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "NOTE: no signing certificate found, so the app is signed ad hoc. It works, but macOS"
  echo "      will ask for the Accessibility permission again after every rebuild or update."
  echo "      (A free Apple Development certificate in Xcode avoids that; see the README.)"
  IDENTITY="-"
else
  echo "Signing with: $IDENTITY"
fi
xattr -cr "$APP"  # remove Finder/iCloud markings, which codesign refuses
codesign --force --sign "$IDENTITY" --identifier com.lindewhat.mac-sonos-control "$APP"

# Quit a running copy, install, launch.
pkill -x MacSonosControl 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
ditto --noextattr --noqtn "$APP" "$DEST"
codesign --verify --strict "$DEST"
echo "Installed and verified: $DEST"
if [[ "${1:-}" != "--no-run" ]]; then
  open "$DEST"
fi
