#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
heartbeat_script="$script_dir/ci-heartbeat.sh"

tmp_dir="$(mktemp -d -t ghostty-ci-heartbeat-selftest.XXXXXX)"
trap 'rm -rf "$tmp_dir"' EXIT

success_log="$tmp_dir/success.log"
slow_log="$tmp_dir/slow.log"
timeout_log="$tmp_dir/timeout.log"

echo "[ci-heartbeat-selftest] phase=quick-success"
"$heartbeat_script" \
  --label quick-success \
  --heartbeat-seconds 1 \
  --silence-timeout-seconds 10 \
  --log-file "$success_log" \
  -- bash -lc 'echo ready'
grep -q 'status=done exit_code=0' "$success_log"

echo "[ci-heartbeat-selftest] phase=slow-output"
"$heartbeat_script" \
  --label slow-output \
  --heartbeat-seconds 1 \
  --silence-timeout-seconds 10 \
  --log-file "$slow_log" \
  -- bash -lc 'for i in 1 2 3; do echo tick-$i; sleep 1; done'
grep -q 'status=running' "$slow_log"
grep -q 'tick-3' "$slow_log"

echo "[ci-heartbeat-selftest] phase=silence-timeout"
set +e
"$heartbeat_script" \
  --label silence-timeout \
  --heartbeat-seconds 1 \
  --silence-timeout-seconds 2 \
  --log-file "$timeout_log" \
  -- bash -lc 'sleep 5'
timeout_exit="$?"
set -e

if [[ "$timeout_exit" -eq 0 ]]; then
  echo "expected silence-timeout selftest to fail" >&2
  exit 1
fi

grep -q 'failure-class=ci-silence-timeout' "$timeout_log"
echo "[ci-heartbeat-selftest] phase=success"
