#!/usr/bin/env bash
# Build ClaudeMac.app from the SwiftPM executable target.
# Usage: scripts/build.sh [release|debug]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP_NAME="ClaudeMac"
BUNDLE_ID="com.antonin.claudemac"

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
  echo "✗ Binary not found at $BIN" >&2
  exit 1
fi

APP="$ROOT/dist/$APP_NAME.app"
echo "▶ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM copies bundled resources next to the binary as ClaudeMac_ClaudeMac.bundle
RES_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
fi

# Bundle the local model router (Node script) so Ollama routing works.
if [[ -d "$ROOT/router" ]]; then
  mkdir -p "$APP/Contents/Resources/router"
  cp "$ROOT/router/"*.mjs "$APP/Contents/Resources/router/" 2>/dev/null || true
fi

# App icon (optional)
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so Gatekeeper lets it launch locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"
