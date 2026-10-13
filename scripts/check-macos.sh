#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-test}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
ARGS=(CODE_SIGNING_ALLOWED=NO)
case "$MODE" in
  test) CONFIGURATION=Debug ;;
  benchmark)
    CONFIGURATION=Release
    ARGS+=(-only-testing:StatBarTests/PerformanceTests ENABLE_TESTABILITY=YES)
    ;;
  *) echo "usage: $0 [test|benchmark]" >&2; exit 2 ;;
esac
RESULT_DIR="$ROOT_DIR/build/checks/$MODE-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$RESULT_DIR"
xcodegen generate
if xcodebuild -project StatBar.xcodeproj -scheme StatBar \
  -configuration "$CONFIGURATION" -destination 'platform=macOS' \
  -derivedDataPath "$ROOT_DIR/build/checks/$CONFIGURATION" \
  -resultBundlePath "$RESULT_DIR/Results.xcresult" \
  "${ARGS[@]}" test >"$RESULT_DIR/xcodebuild.log" 2>&1; then
  grep -E 'BENCHMARK|Executed .* tests|\*\* TEST' "$RESULT_DIR/xcodebuild.log"
  echo "Results: $RESULT_DIR"
else
  RESULT=$?
  tail -80 "$RESULT_DIR/xcodebuild.log"
  echo "Full log: $RESULT_DIR/xcodebuild.log" >&2
  exit "$RESULT"
fi
