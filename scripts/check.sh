#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_directory=$(mktemp -d)
origin_pid=''
cleanup() {
  if [[ -n "$origin_pid" ]]; then kill "$origin_pid" 2>/dev/null || true; wait "$origin_pid" 2>/dev/null || true; fi
  python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$test_directory"
}
trap cleanup EXIT
export OTA_TEST_CONTROL="$test_directory/control.json"
echo '{}' > "$OTA_TEST_CONTROL"
python3 -u Tests/SyntholocOTATests/Fixtures/server.py "$OTA_TEST_CONTROL" > "$test_directory/port" &
origin_pid=$!
for _ in {1..100}; do
  if [[ -s "$test_directory/port" ]]; then break; fi
  sleep 0.05
done
export OTA_TEST_ORIGIN="http://127.0.0.1:$(cat "$test_directory/port")"
python3 -c 'import subprocess,sys; sys.exit(subprocess.run(["swift", "test", "--package-path", ".", "-j", "4"], timeout=180).returncode)'
swift build --package-path . -c release -j 4
