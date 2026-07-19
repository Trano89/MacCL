#!/usr/bin/env bash
# Build MacCL.app and install it into /Applications.
# Usage: scripts/build.sh [release|debug]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="MacCL"
DEST="/Applications/$APP_NAME.app"

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
  echo "✗ Binary not found at $BIN" >&2
  exit 1
fi

# Assemble the bundle in a staging area first, so a failed build never touches
# the installed app. The install itself is rm -rf + cp -R, not an atomic swap:
# if it is interrupted mid-copy, /Applications/MacCL.app is left incomplete —
# just re-run the script.
STAGE="$(mktemp -d)/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"

# SwiftPM copies bundled resources next to the binary as MacCL_MacCL.bundle
RES_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$STAGE/Contents/Resources/"
fi

# App icon (optional)
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so Gatekeeper lets it launch locally. Never silence this: on Apple
# silicon an unsigned binary doesn't start at all ("Killed: 9"), and hiding the
# failure here means debugging that crash with no clue.
codesign --force --sign - "$STAGE"

# Install: quit a running instance so the swap takes effect, then replace.
killall "$APP_NAME" >/dev/null 2>&1 || true
rm -rf "$DEST"
cp -R "$STAGE" "$DEST"
rm -rf "$(dirname "$STAGE")"

echo "✓ Installed $DEST"
