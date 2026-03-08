#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  .github/scripts/ci-heartbeat.sh \
    --label <label> \
    --heartbeat-seconds <seconds> \
    --silence-timeout-seconds <seconds> \
    --log-file <path> \
    -- <command> [args...]
EOF
}

label=""
heartbeat_seconds="60"
silence_timeout_seconds="900"
log_file=""

while (($# > 0)); do
  case "$1" in
    --label)
      label="${2:-}"
      shift 2
      ;;
    --heartbeat-seconds)
      heartbeat_seconds="${2:-}"
      shift 2
      ;;
    --silence-timeout-seconds)
      silence_timeout_seconds="${2:-}"
      shift 2
      ;;
    --log-file)
      log_file="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$label" || -z "$log_file" || $# -eq 0 ]]; then
  usage >&2
  exit 2
fi
if ! [[ "$heartbeat_seconds" =~ ^[0-9]+$ && "$heartbeat_seconds" -gt 0 ]]; then
  echo "invalid --heartbeat-seconds: $heartbeat_seconds" >&2
  exit 2
fi
if ! [[ "$silence_timeout_seconds" =~ ^[0-9]+$ && "$silence_timeout_seconds" -gt 0 ]]; then
  echo "invalid --silence-timeout-seconds: $silence_timeout_seconds" >&2
  exit 2
fi

mkdir -p "$(dirname "$log_file")"
: > "$log_file"

tmp_dir="$(mktemp -d -t ghostty-ci-heartbeat.XXXXXX)"
pipe_path="$tmp_dir/output.pipe"
last_output_file="$tmp_dir/last-output"
command_exit_file="$tmp_dir/command.exit"
timeout_flag_file="$tmp_dir/timeout"
mkfifo "$pipe_path"
date +%s > "$last_output_file"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

log_line() {
  local line="$1"
  printf '%s\n' "$line" | tee -a "$log_file"
}

start_epoch="$(date +%s)"
log_line "[ci-heartbeat] label=$label status=start heartbeat_seconds=$heartbeat_seconds silence_timeout_seconds=$silence_timeout_seconds"
printf '[ci-heartbeat] label=%s cmd:' "$label" | tee -a "$log_file"
for arg in "$@"; do
  printf ' %q' "$arg" | tee -a "$log_file"
done
printf '\n' | tee -a "$log_file"

(
  set +e
  "$@" >"$pipe_path" 2>&1
  printf '%s\n' "$?" > "$command_exit_file"
) &
command_pid=$!

(
  set +e
  while IFS= read -r line || [[ -n "$line" ]]; do
    date +%s > "$last_output_file"
    printf '%s\n' "$line" | tee -a "$log_file"
  done < "$pipe_path"
) &
reader_pid=$!

(
  set +e
  while kill -0 "$command_pid" 2>/dev/null; do
    sleep "$heartbeat_seconds"
    if ! kill -0 "$command_pid" 2>/dev/null; then
      break
    fi

    local_now="$(date +%s)"
    local_last_output="$(cat "$last_output_file")"
    elapsed="$((local_now - start_epoch))"
    silence_age="$((local_now - local_last_output))"
    log_line "[ci-heartbeat] label=$label status=running elapsed_seconds=$elapsed last_output_age_seconds=$silence_age"

    if (( silence_age >= silence_timeout_seconds )); then
      log_line "[ci-heartbeat] failure-class=ci-silence-timeout label=$label elapsed_seconds=$elapsed last_output_age_seconds=$silence_age"
      printf '1\n' > "$timeout_flag_file"
      kill "$command_pid" 2>/dev/null || true
      sleep 5
      kill -9 "$command_pid" 2>/dev/null || true
      break
    fi
  done
) &
heartbeat_pid=$!

wait "$command_pid" || true
wait "$reader_pid" || true
wait "$heartbeat_pid" || true

if [[ -f "$timeout_flag_file" ]]; then
  log_line "[ci-heartbeat] label=$label status=failed reason=silence-timeout"
  exit 124
fi

command_exit_code="$(cat "$command_exit_file")"
end_epoch="$(date +%s)"
elapsed_total="$((end_epoch - start_epoch))"
log_line "[ci-heartbeat] label=$label status=done exit_code=$command_exit_code elapsed_seconds=$elapsed_total"
exit "$command_exit_code"
