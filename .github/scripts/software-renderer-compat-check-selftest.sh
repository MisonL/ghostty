#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sut="$script_dir/software-renderer-compat-check.sh"

fail() {
  echo "[compat-selftest] FAIL: $*" >&2
  exit 1
}

pass() {
  echo "[compat-selftest] PASS: $*"
}

assert_contains() {
  local output="$1"
  local expected="$2"
  local case_name="$3"
  if [[ "$output" != *"$expected"* ]]; then
    fail "$case_name: output missing '$expected'"
  fi
}

run_with_fake_zig() {
  local __outvar="$1"
  local scenario="$2"
  shift 2

  local temp_dir fake_bin fake_log_file captured_output status
  temp_dir="$(mktemp -d)"
  fake_bin="$temp_dir/bin"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cache_dir=""
while (($# > 0)); do
  if [[ "$1" == "--cache-dir" ]]; then
    shift
    cache_dir="${1:-}"
    break
  fi
  shift
done

write_options_file() {
  local contents="$1"
  local options_dir="$cache_dir/o/fake"
  mkdir -p "$options_dir"
  printf '%s\n' "$contents" >"$options_dir/options.zig"
}

default_route_backend() {
  case "$(uname -s)" in
    Darwin) printf 'metal' ;;
    *) printf 'opengl' ;;
  esac
}

route_backend="$(default_route_backend)"

case "${GHOSTTY_COMPAT_SELFTEST_SCENARIO:-}" in
  options-zig-missing)
    echo "fake build success without options snapshot"
    exit 0
    ;;
  config-mismatch)
    write_options_file "pub const software_renderer_cpu_effective = false;
pub const software_renderer_route_backend = .${route_backend};"
    echo "fake build success with mismatched options snapshot"
    exit 0
    ;;
  runtime-log-missing)
    write_options_file "pub const software_renderer_route_backend = .${route_backend};"
    echo "fake build success without capability kv log"
    exit 0
    ;;
  runtime-log-mismatch)
    write_options_file "pub const software_renderer_route_backend = .${route_backend};"
    echo "software renderer cpu shader capability kv status=unavailable reason=missing_driver hint_source=none hint_readable=false minimal_runtime_enabled=false"
    exit 0
    ;;
  runtime-diagnostics-mismatch)
    write_options_file "pub const software_renderer_cpu_effective = true;
pub const software_renderer_route_backend = .${route_backend};"
    echo "software renderer cpu damage kv frame_damage_mode=rects rect_count=2 overflow_count=0 damage_rect_cap=64"
    echo "software renderer cpu publish retry kv reason=invalid_surface retry_count=1 invalid_surface_count=1 pool_retired_pressure_count=0 frame_pool_exhausted_count=0 mailbox_backpressure_count=0"
    exit 0
    ;;
  runtime-publish-warning-missing)
    write_options_file "pub const software_renderer_cpu_effective = true;
pub const software_renderer_route_backend = .${route_backend};"
    echo "software renderer cpu damage kv frame_damage_mode=rects rect_count=3 overflow_count=1 damage_rect_cap=64"
    echo "software renderer cpu publish retry kv reason=mailbox_backpressure retry_count=4 invalid_surface_count=1 pool_retired_pressure_count=1 frame_pool_exhausted_count=1 mailbox_backpressure_count=1"
    exit 0
    ;;
  success)
    write_options_file "pub const software_renderer_cpu_effective = true;
pub const software_renderer_route_backend = .${route_backend};"
    echo "software renderer cpu shader capability kv status=available reason=n/a hint_source=n/a hint_readable=false minimal_runtime_enabled=false"
    echo "software renderer cpu damage kv frame_damage_mode=rects rect_count=3 overflow_count=1 damage_rect_cap=64"
    echo "software renderer cpu publish retry kv reason=mailbox_backpressure retry_count=4 invalid_surface_count=1 pool_retired_pressure_count=1 frame_pool_exhausted_count=1 mailbox_backpressure_count=1"
    echo "software renderer cpu publish warning kv last_cpu_frame_ms=17 threshold_ms=40 consecutive=3 warning_count=1 shader_capability_observed=true shader_capability_available=true shader_minimal_runtime_enabled=true"
    exit 0
    ;;
  toolchain-linker-pic)
    echo "ld.lld: error: relocation R_X86_64_32 against ''.rodata'' can not be used when making a shared object; recompile with -fPIC"
    exit 1
    ;;
  xcode-build-chain)
    echo "xcodebuild: error: Testing cancelled because the build failed"
    exit 1
    ;;
  logic-or-runtime)
    echo "generic regression without classified hint"
    exit 1
    ;;
  *)
    echo "unknown GHOSTTY_COMPAT_SELFTEST_SCENARIO=${GHOSTTY_COMPAT_SELFTEST_SCENARIO:-unset}" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$fake_bin/zig"

  set +e
  captured_output="$(
    PATH="$fake_bin:$PATH" \
      GHOSTTY_COMPAT_SELFTEST_SCENARIO="$scenario" \
      "$sut" "$@" 2>&1
  )"
  status=$?
  set -e

  rm -rf "$temp_dir"
  printf -v "$__outvar" '%s' "$captured_output"
  return "$status"
}

case_options_zig_missing_detected() {
  local output
  if run_with_fake_zig output \
    options-zig-missing \
    --mode build \
    --expect-cpu-effective true; then
    fail "options-zig-missing should fail"
  fi

  assert_contains "$output" "failure-class=environment options-zig-missing" "options-zig-missing"
  pass "options-zig-missing classified correctly"
}

case_config_mismatch_detected() {
  local output
  if run_with_fake_zig output \
    config-mismatch \
    --mode build \
    --expect-cpu-effective true; then
    fail "config-mismatch should fail"
  fi

  assert_contains "$output" "failure-class=assertion config-mismatch" "config-mismatch"
  pass "config-mismatch classified correctly"
}

case_runtime_log_missing_detected() {
  local output
  if run_with_fake_zig output \
    runtime-log-missing \
    --mode build \
    --expect-cpu-shader-capability-status available; then
    fail "runtime-log-missing should fail"
  fi

  assert_contains "$output" "failure-class=assertion runtime-log-missing" "runtime-log-missing"
  pass "runtime-log-missing classified correctly"
}

case_runtime_log_mismatch_detected() {
  local output
  if run_with_fake_zig output \
    runtime-log-mismatch \
    --mode build \
    --expect-cpu-shader-capability-status available; then
    fail "runtime-log-mismatch should fail"
  fi

  assert_contains "$output" "failure-class=assertion runtime-log-mismatch" "runtime-log-mismatch"
  pass "runtime-log-mismatch classified correctly"
}

case_toolchain_linker_pic_detected() {
  local output
  if run_with_fake_zig output \
    toolchain-linker-pic \
    --mode build; then
    fail "toolchain-linker-pic should fail"
  fi

  assert_contains "$output" "failure-class=environment toolchain-linker-pic" "toolchain-linker-pic"
  pass "toolchain-linker-pic classified correctly"
}

case_xcode_build_chain_detected() {
  local output
  if run_with_fake_zig output \
    xcode-build-chain \
    --mode build; then
    fail "xcode-build-chain should fail"
  fi

  assert_contains "$output" "failure-class=environment xcode-build-chain" "xcode-build-chain"
  pass "xcode-build-chain classified correctly"
}

case_logic_or_runtime_default_detected() {
  local output
  if run_with_fake_zig output \
    logic-or-runtime \
    --mode build; then
    fail "logic-or-runtime should fail"
  fi

  assert_contains "$output" "failure-class=logic-or-runtime" "logic-or-runtime"
  pass "logic-or-runtime classified correctly"
}

case_blackbox_success_smoke() {
  local output
  if ! run_with_fake_zig output \
    success \
    --mode build \
    --expect-cpu-effective true \
    --expect-cpu-shader-capability-status available \
    --expect-cpu-damage-overflow 1 \
    --expect-cpu-publish-retry-reason mailbox_backpressure \
    --expect-cpu-publish-warning true; then
    fail "blackbox success smoke should pass"
  fi

  assert_contains "$output" "[software-compat] success" "blackbox success smoke"
  pass "blackbox success smoke passes"
}

case_runtime_damage_overflow_mismatch_detected() {
  local output
  if run_with_fake_zig output \
    runtime-diagnostics-mismatch \
    --mode build \
    --expect-cpu-damage-overflow 1; then
    fail "runtime damage overflow mismatch should fail"
  fi

  assert_contains "$output" "failure-class=assertion runtime-log-mismatch" "runtime damage overflow mismatch"
  pass "runtime damage overflow mismatch classified correctly"
}

case_runtime_damage_overflow_zero_succeeds_without_log() {
  local output
  if ! run_with_fake_zig output \
    runtime-log-missing \
    --mode build \
    --expect-cpu-damage-overflow 0; then
    fail "runtime damage overflow zero expectation should pass without damage log"
  fi

  assert_contains "$output" "[software-compat] cpu-damage-overflow assertion matched" "runtime damage overflow zero"
  pass "runtime damage overflow zero expectation passes"
}

case_runtime_publish_retry_mismatch_detected() {
  local output
  if run_with_fake_zig output \
    runtime-diagnostics-mismatch \
    --mode build \
    --expect-cpu-publish-retry-reason mailbox_backpressure; then
    fail "runtime publish retry mismatch should fail"
  fi

  assert_contains "$output" "failure-class=assertion runtime-log-mismatch" "runtime publish retry mismatch"
  pass "runtime publish retry mismatch classified correctly"
}

case_runtime_publish_warning_missing_detected() {
  local output
  if run_with_fake_zig output \
    runtime-publish-warning-missing \
    --mode build \
    --expect-cpu-publish-warning true; then
    fail "runtime publish warning missing should fail"
  fi

  assert_contains "$output" "failure-class=assertion runtime-log-missing" "runtime publish warning missing"
  pass "runtime publish warning missing classified correctly"
}

case_expect_cpu_publish_retry_reason_invalid_fails_fast() {
  local output
  if run_with_fake_zig output \
    success \
    --mode build \
    --expect-cpu-publish-retry-reason pressure; then
    fail "invalid cpu publish retry reason should fail fast"
  fi

  assert_contains "$output" "invalid --expect-cpu-publish-retry-reason: pressure" "invalid cpu publish retry reason"
  pass "invalid cpu publish retry reason fails fast"
}

case_expect_cpu_publish_warning_invalid_fails_fast() {
  local output
  if run_with_fake_zig output \
    success \
    --mode build \
    --expect-cpu-publish-warning maybe; then
    fail "invalid cpu publish warning should fail fast"
  fi

  assert_contains "$output" "invalid --expect-cpu-publish-warning: maybe (expected: true|false)" "invalid cpu publish warning"
  pass "invalid cpu publish warning fails fast"
}

case_expect_cpu_damage_overflow_too_large_fails_fast() {
  local output
  if run_with_fake_zig output \
    success \
    --mode build \
    --expect-cpu-damage-overflow 18446744073709551616; then
    fail "too-large cpu damage overflow should fail fast"
  fi

  assert_contains "$output" "invalid --expect-cpu-damage-overflow: 18446744073709551616 (expected: 0..18446744073709551615)" "too-large cpu damage overflow"
  pass "too-large cpu damage overflow fails fast"
}

test_cases=(
  case_options_zig_missing_detected
  case_config_mismatch_detected
  case_runtime_log_missing_detected
  case_runtime_log_mismatch_detected
  case_runtime_damage_overflow_mismatch_detected
  case_runtime_damage_overflow_zero_succeeds_without_log
  case_runtime_publish_retry_mismatch_detected
  case_runtime_publish_warning_missing_detected
  case_expect_cpu_publish_retry_reason_invalid_fails_fast
  case_expect_cpu_publish_warning_invalid_fails_fast
  case_expect_cpu_damage_overflow_too_large_fails_fast
  case_toolchain_linker_pic_detected
  case_xcode_build_chain_detected
  case_logic_or_runtime_default_detected
  case_blackbox_success_smoke
)

for test_case in "${test_cases[@]}"; do
  "$test_case"
done

echo "[compat-selftest] summary: passed ${#test_cases[@]} cases"
echo "[compat-selftest] all checks passed"
