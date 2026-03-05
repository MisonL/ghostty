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

case_target_os_mismatch_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_TARGET=x86_64-macos.14.0.0 \
    SR_CI_DRY_RUN=true; then
    fail "target OS mismatch should fail"
  fi

  assert_contains "$output" "SR_CI_TARGET OS mismatch" "target OS mismatch"
  pass "target OS mismatch fails fast"
}

case_route_backend_os_mismatch_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND=metal \
    SR_CI_DRY_RUN=true; then
    fail "linux route backend mismatch should fail"
  fi

  assert_contains "$output" "SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND mismatch" "route backend mismatch"
  pass "route backend mismatch fails fast"
}

case_dry_run_route_backend_flag_present() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND=opengl; then
    fail "dry-run with explicit route backend should succeed"
  fi

  assert_contains "$output" "dry-run compat-check command" "dry-run command print"
  assert_contains "$output" "--expect-software-route-backend opengl" "dry-run route backend arg"
  pass "dry-run keeps explicit route backend argument"
}

case_linux_legacy_auto_transport_uses_gtk_runtime() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_TARGET=x86_64-linux.4.19 \
    SR_CI_DRY_RUN=true; then
    fail "linux legacy target with auto transport should succeed in dry-run"
  fi

  assert_contains "$output" "dry-run compat-check command" "linux legacy dry-run command print"
  assert_contains "$output" "--app-runtime gtk" "linux legacy auto transport app runtime"
  pass "linux legacy target auto transport uses gtk runtime"
}

case_linux_non_legacy_auto_transport_uses_none_runtime() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_TARGET=x86_64-linux.6.6 \
    SR_CI_DRY_RUN=true; then
    fail "linux non-legacy target with auto transport should succeed in dry-run"
  fi

  assert_contains "$output" "dry-run compat-check command" "linux non-legacy dry-run command print"
  assert_contains "$output" "--app-runtime none" "linux non-legacy auto transport app runtime"
  pass "linux non-legacy target auto transport uses none runtime"
}

case_macos_default_route_backend_is_metal() {
  local output
  if ! run_with_env output \
    SR_CI_OS=macos \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_SYSTEM_PATH=/nix/store/fake-system-path; then
    fail "macOS dry-run with system path should succeed"
  fi

  assert_contains "$output" "dry-run compat-check command" "macOS dry-run command print"
  assert_contains "$output" "--expect-software-route-backend metal" "macOS default route backend"
  pass "macOS default route backend is metal"
}

case_dry_run_cpu_publish_warning_knobs_passthrough() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS=55 \
    SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT=4; then
    fail "dry-run with cpu publish warning knobs should succeed"
  fi

  assert_contains "$output" "dry-run compat-check command" "dry-run command print"
  assert_contains "$output" "--cpu-publish-warning-threshold-ms 55" "dry-run cpu publish warning threshold arg"
  assert_contains "$output" "--cpu-publish-warning-consecutive-limit 4" "dry-run cpu publish warning consecutive limit arg"
  pass "dry-run passes cpu publish warning knobs"
}

case_dry_run_cpu_publish_warning_threshold_only_passthrough() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS=21; then
    fail "dry-run with cpu publish warning threshold only should succeed"
  fi

  assert_contains "$output" "dry-run compat-check command" "dry-run command print"
  assert_contains "$output" "--cpu-publish-warning-threshold-ms 21" "dry-run cpu publish warning threshold-only arg"
  pass "dry-run passes cpu publish warning threshold-only knob"
}

test_cases=(
  case_target_gate_mismatch_fails
  case_macos_missing_system_path_fails
  case_target_os_mismatch_fails
  case_route_backend_os_mismatch_fails
  case_dry_run_route_backend_flag_present
  case_linux_legacy_auto_transport_uses_gtk_runtime
  case_linux_non_legacy_auto_transport_uses_none_runtime
  case_macos_default_route_backend_is_metal
  case_dry_run_cpu_publish_warning_knobs_passthrough
  case_dry_run_cpu_publish_warning_threshold_only_passthrough
)

for test_case in "${test_cases[@]}"; do
  "$test_case"
done

echo "[selftest] summary: passed ${#test_cases[@]} cases"
echo "[selftest] all checks passed"
