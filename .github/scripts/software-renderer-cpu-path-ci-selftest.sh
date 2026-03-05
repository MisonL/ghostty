#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sut="$script_dir/software-renderer-cpu-path-ci.sh"

fail() {
  echo "[selftest] FAIL: $*" >&2
  exit 1
}

pass() {
  echo "[selftest] PASS: $*"
}

assert_contains() {
  local output="$1"
  local expected="$2"
  local case_name="$3"
  if [[ "$output" != *"$expected"* ]]; then
    fail "$case_name: output missing '$expected'"
  fi
}

run_with_env() {
  local __outvar="$1"
  shift

  local captured_output
  set +e
  captured_output="$(env "$@" "$sut" 2>&1)"
  local status=$?
  set -e

  printf -v "$__outvar" '%s' "$captured_output"
  return "$status"
}

case_target_gate_mismatch_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_TARGET=x86_64-linux.5.10 \
    SR_CI_EXPECT_CPU_EFFECTIVE=false \
    SR_CI_DRY_RUN=true; then
    fail "target gate mismatch should fail"
  fi

  assert_contains "$output" "mismatches matrix expect_cpu_effective" "target gate mismatch"
  pass "target gate mismatch fails"
}

case_macos_missing_system_path_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=macos \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true; then
    fail "macOS without SR_CI_SYSTEM_PATH should fail"
  fi

  assert_contains "$output" "SR_CI_SYSTEM_PATH is required for macOS software-renderer cpu-path CI" "macOS missing system path"
  pass "macOS missing system path fails"
}

case_dry_run_route_backend_flag_present() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND=metal; then
    fail "dry-run with explicit route backend should succeed"
  fi

  assert_contains "$output" "dry-run compat-check command" "dry-run command print"
  assert_contains "$output" "--expect-software-route-backend metal" "dry-run route backend arg"
  pass "dry-run keeps explicit route backend argument"
}

case_target_gate_mismatch_fails
case_macos_missing_system_path_fails
case_dry_run_route_backend_flag_present

echo "[selftest] all checks passed"
