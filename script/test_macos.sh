#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift test --package-path "$ROOT_DIR/macOS"
if [[ "${1:-}" != "--existing-bundle" ]]; then "$ROOT_DIR/script/build_and_run.sh" --build; fi
FIXTURE_DIR="$(mktemp -d /tmp/omagawd-smoke.XXXXXX)"
python3 "$ROOT_DIR/macOS/Tests/Fixtures/server.py" "$FIXTURE_DIR" &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true; rm -rf "$FIXTURE_DIR"' EXIT
for _ in {1..50}; do [[ -f "$FIXTURE_DIR/port" ]] && break; sleep 0.1; done
PORT="$(cat "$FIXTURE_DIR/port")"
REPORT="$ROOT_DIR/dist/smoke-test.txt"
BUNDLE="${OMAGAWD_TEST_BUNDLE:-$ROOT_DIR/dist/build.noindex/OmaGAWD.app}"
rm -f "$REPORT"
pkill -x OmaGAWD >/dev/null 2>&1 || true
open -n "$BUNDLE" --args --smoke-test "$FIXTURE_DIR/OmaGAWD test tone.wav" "$PORT" "$REPORT"
for _ in {1..60}; do [[ -f "$REPORT" ]] && break; sleep 1; done
if [[ ! -f "$REPORT" ]]; then echo 'FAIL: smoke test timed out'; exit 1; fi
cat "$REPORT"
[[ "$(head -n 1 "$REPORT")" == "PASS" ]]
