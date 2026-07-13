#!/usr/bin/env bash
# Build and launch ClaudeMac.app
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh" "${1:-release}"
# Relaunch cleanly
killall ClaudeMac >/dev/null 2>&1 || true
open "$ROOT/dist/ClaudeMac.app"
echo "✓ Launched ClaudeMac.app"
