#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${STATBAR_CONFIGURATION:-Debug}"
DERIVED_DATA="$ROOT_DIR/build/run"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/StatBar.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/StatBar"
cd "$ROOT_DIR"
xcodegen generate
xcodebuild -quiet -project StatBar.xcodeproj -scheme StatBar \
  -configuration "$CONFIGURATION" -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build

# Replace the running copy only after a successful build.
pkill -x StatBar >/dev/null 2>&1 || true
case "$MODE" in
  --debug) exec lldb -- "$APP_BINARY" ;;
  *) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
case "$MODE" in
  --verify)
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    echo "Running: $APP_BUNDLE"
    ;;
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "StatBar"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.erole.StatBar"' ;;
esac
