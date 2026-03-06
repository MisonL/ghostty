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

case_missing_os_fails_fast() {
  local output
  if run_with_env output \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true; then
    fail "missing SR_CI_OS should fail"
  fi

  assert_contains "$output" "SR_CI_OS is required (linux|macos)" "missing SR_CI_OS"
  pass "missing SR_CI_OS fails fast"
}

case_missing_transport_mode_fails_fast() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_DRY_RUN=true; then
    fail "missing SR_CI_TRANSPORT_MODE should fail"
  fi

  assert_contains "$output" "SR_CI_TRANSPORT_MODE is required (auto|shared|native)" "missing SR_CI_TRANSPORT_MODE"
  pass "missing SR_CI_TRANSPORT_MODE fails fast"
}

case_invalid_os_fails_fast() {
  local output
  if run_with_env output \
    SR_CI_OS=windows \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true; then
    fail "invalid SR_CI_OS should fail"
  fi

  assert_contains "$output" "invalid SR_CI_OS: windows" "invalid SR_CI_OS"
  pass "invalid SR_CI_OS fails fast"
}

case_invalid_transport_mode_fails_fast() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=udp \
    SR_CI_DRY_RUN=true; then
    fail "invalid SR_CI_TRANSPORT_MODE should fail"
  fi

  assert_contains "$output" "invalid SR_CI_TRANSPORT_MODE: udp (expected: auto|shared|native)" "invalid SR_CI_TRANSPORT_MODE"
  pass "invalid SR_CI_TRANSPORT_MODE fails fast"
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

case_dry_run_route_backend_flag_present_macos() {
  local output
  if ! run_with_env output \
    SR_CI_OS=macos \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND=metal \
    SR_CI_SYSTEM_PATH=/nix/store/fake-system-path \
    SR_CI_DRY_RUN=true; then
    fail "macOS dry-run with explicit route backend should succeed"
  fi

  assert_contains "$output" "dry-run compat-check command" "macOS dry-run command print"
  assert_contains "$output" "--expect-software-route-backend metal" "macOS dry-run route backend arg"
  pass "dry-run keeps explicit macOS route backend argument"
}

case_linux_legacy_target_defaults_to_no_override() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_TARGET=x86_64-linux.4.19 \
    SR_CI_DRY_RUN=true; then
    fail "linux legacy target without explicit override should succeed in dry-run"
  fi

  assert_contains "$output" "legacy-target=true" "linux legacy target flag"
  assert_contains "$output" "allow-legacy-os=false" "linux legacy target default allow-legacy"
  assert_contains "$output" "legacy-override-source=default" "linux legacy target default source"
  assert_contains "$output" "gate-expected-cpu-effective=false" "linux legacy target default gate"
  assert_contains "$output" "--allow-legacy-os=false" "linux legacy target default compat arg"
  assert_contains "$output" "--app-runtime none" "linux legacy target default app runtime"
  pass "linux legacy target stays conservative by default"
}

case_linux_legacy_target_force_enable_uses_gtk_runtime_and_normalizes_knobs() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_TARGET=x86_64-linux.4.19 \
    SR_CI_FORCE_ALLOW_LEGACY_OS=true \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_FRAME_DAMAGE_MODE=rects \
    SR_CI_CPU_DAMAGE_RECT_CAP=0 \
    SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS=55 \
    SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT=0; then
    fail "linux legacy target with explicit override should succeed in dry-run"
  fi

  assert_contains "$output" "legacy-target=true" "linux forced legacy target flag"
  assert_contains "$output" "allow-legacy-os=true" "linux forced legacy allow-legacy"
  assert_contains "$output" "legacy-override-source=SR_CI_FORCE_ALLOW_LEGACY_OS" "linux forced legacy source"
  assert_contains "$output" "gate-expected-cpu-effective=true" "linux forced legacy gate"
  assert_contains "$output" "--allow-legacy-os=true" "linux forced legacy compat arg"
  assert_contains "$output" "--app-runtime gtk" "linux forced legacy app runtime"
  assert_contains "$output" "--cpu-frame-damage-mode rects" "linux forced legacy frame damage arg"
  assert_contains "$output" "--expect-cpu-frame-damage-mode rects" "linux forced legacy frame damage expect arg"
  assert_contains "$output" "--cpu-damage-rect-cap 0" "linux forced legacy damage rect cap arg"
  assert_contains "$output" "--expect-cpu-damage-rect-cap 1" "linux forced legacy damage rect cap expect arg"
  assert_contains "$output" "--cpu-publish-warning-threshold-ms 55" "linux forced legacy publish threshold arg"
  assert_contains "$output" "--expect-cpu-publish-warning-threshold-ms 55" "linux forced legacy publish threshold expect arg"
  assert_contains "$output" "--cpu-publish-warning-consecutive-limit 0" "linux forced legacy publish consecutive arg"
  assert_contains "$output" "--expect-cpu-publish-warning-consecutive-limit 1" "linux forced legacy publish consecutive expect arg"
  pass "linux legacy override enables gtk runtime and normalizes cpu knobs"
}

case_linux_legacy_target_force_disable_stays_disabled() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_TARGET=x86_64-linux.4.19 \
    SR_CI_FORCE_ALLOW_LEGACY_OS=false \
    SR_CI_DRY_RUN=true; then
    fail "linux legacy target with explicit false override should succeed in dry-run"
  fi

  assert_contains "$output" "legacy-override-source=SR_CI_FORCE_ALLOW_LEGACY_OS" "linux forced false legacy source"
  assert_contains "$output" "allow-legacy-os=false" "linux forced false allow-legacy"
  assert_contains "$output" "--allow-legacy-os=false" "linux forced false compat arg"
  assert_contains "$output" "--app-runtime none" "linux forced false app runtime"
  pass "linux legacy target explicit false keeps override disabled"
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

case_macos_legacy_target_defaults_to_no_override() {
  local output
  if ! run_with_env output \
    SR_CI_OS=macos \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_TARGET=x86_64-macos.10.15.0 \
    SR_CI_SYSTEM_PATH=/nix/store/fake-system-path \
    SR_CI_DRY_RUN=true; then
    fail "macOS legacy target without explicit override should succeed in dry-run"
  fi

  assert_contains "$output" "legacy-target=true" "macOS legacy target flag"
  assert_contains "$output" "allow-legacy-os=false" "macOS legacy target default allow-legacy"
  assert_contains "$output" "legacy-override-source=default" "macOS legacy target default source"
  assert_contains "$output" "gate-expected-cpu-effective=false" "macOS legacy target default gate"
  assert_contains "$output" "--allow-legacy-os=false" "macOS legacy target default compat arg"
  pass "macOS legacy target stays conservative by default"
}

case_macos_legacy_target_force_enable_normalizes_knobs() {
  local output
  if ! run_with_env output \
    SR_CI_OS=macos \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_TARGET=x86_64-macos.10.15.0 \
    SR_CI_SYSTEM_PATH=/nix/store/fake-system-path \
    SR_CI_FORCE_ALLOW_LEGACY_OS=true \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_FRAME_DAMAGE_MODE=rects \
    SR_CI_CPU_DAMAGE_RECT_CAP=0 \
    SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS=55 \
    SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT=0; then
    fail "macOS legacy target with explicit override should succeed in dry-run"
  fi

  assert_contains "$output" "legacy-target=true" "macOS forced legacy target flag"
  assert_contains "$output" "allow-legacy-os=true" "macOS forced legacy allow-legacy"
  assert_contains "$output" "legacy-override-source=SR_CI_FORCE_ALLOW_LEGACY_OS" "macOS forced legacy source"
  assert_contains "$output" "gate-expected-cpu-effective=true" "macOS forced legacy gate"
  assert_contains "$output" "--allow-legacy-os=true" "macOS forced legacy compat arg"
  assert_contains "$output" "--system /nix/store/fake-system-path" "macOS forced legacy system arg"
  assert_contains "$output" "--cpu-frame-damage-mode rects" "macOS forced legacy frame damage arg"
  assert_contains "$output" "--expect-cpu-frame-damage-mode rects" "macOS forced legacy frame damage expect arg"
  assert_contains "$output" "--cpu-damage-rect-cap 0" "macOS forced legacy damage rect cap arg"
  assert_contains "$output" "--expect-cpu-damage-rect-cap 1" "macOS forced legacy damage rect cap expect arg"
  assert_contains "$output" "--cpu-publish-warning-threshold-ms 55" "macOS forced legacy publish threshold arg"
  assert_contains "$output" "--expect-cpu-publish-warning-threshold-ms 55" "macOS forced legacy publish threshold expect arg"
  assert_contains "$output" "--cpu-publish-warning-consecutive-limit 0" "macOS forced legacy publish consecutive arg"
  assert_contains "$output" "--expect-cpu-publish-warning-consecutive-limit 1" "macOS forced legacy publish consecutive expect arg"
  pass "macOS legacy override normalizes cpu knobs"
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
  assert_contains "$output" "--expect-cpu-publish-warning-threshold-ms 55" "dry-run cpu publish warning threshold expect arg"
  assert_contains "$output" "--expect-cpu-publish-warning-consecutive-limit 4" "dry-run cpu publish warning consecutive limit expect arg"
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
  assert_contains "$output" "--expect-cpu-publish-warning-threshold-ms 21" "dry-run cpu publish warning threshold-only expect arg"
  pass "dry-run passes cpu publish warning threshold-only knob"
}

case_dry_run_runtime_diagnostics_expectations_passthrough() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW=1 \
    SR_CI_EXPECT_CPU_PUBLISH_RETRY_REASON=mailbox_backpressure \
    SR_CI_EXPECT_CPU_PUBLISH_WARNING=true; then
    fail "dry-run with runtime diagnostics expectations should succeed"
  fi

  assert_contains "$output" "runtime-diagnostics expect-damage-overflow=1 expect-publish-retry-reason=mailbox_backpressure expect-publish-warning=true" "dry-run runtime diagnostics summary"
  assert_contains "$output" "--expect-cpu-damage-overflow 1" "dry-run cpu damage overflow expect arg"
  assert_contains "$output" "--expect-cpu-publish-retry-reason mailbox_backpressure" "dry-run cpu publish retry expect arg"
  assert_contains "$output" "--expect-cpu-publish-warning true" "dry-run cpu publish warning expect arg"
  pass "dry-run passes runtime diagnostics expectations"
}

case_dry_run_runtime_diagnostics_zero_and_false_passthrough() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW=0 \
    SR_CI_EXPECT_CPU_PUBLISH_WARNING=false; then
    fail "dry-run with runtime diagnostics zero/false expectations should succeed"
  fi

  assert_contains "$output" "runtime-diagnostics expect-damage-overflow=0 expect-publish-retry-reason=<unset> expect-publish-warning=false" "dry-run runtime diagnostics zero/false summary"
  assert_contains "$output" "--expect-cpu-damage-overflow 0" "dry-run cpu damage overflow zero expect arg"
  assert_contains "$output" "--expect-cpu-publish-warning false" "dry-run cpu publish warning false expect arg"
  pass "dry-run passes runtime diagnostics zero/false expectations"
}

case_dry_run_runtime_diagnostics_smoke_passthrough() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_TEST_FILTER="cpu route diagnostics kv helpers emit structured logs" \
    SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_DAMAGE_OVERFLOW=1 \
    SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_PUBLISH_RETRY_REASON=mailbox_backpressure \
    SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_PUBLISH_WARNING=true; then
    fail "dry-run with runtime diagnostics smoke should succeed"
  fi

  assert_contains "$output" "runtime-diagnostics-smoke filter=cpu route diagnostics kv helpers emit structured logs expect-damage-overflow=1 expect-publish-retry-reason=mailbox_backpressure expect-publish-warning=true" "dry-run runtime diagnostics smoke summary"
  assert_contains "$output" "dry-run compat-check smoke command" "dry-run runtime diagnostics smoke command"
  assert_contains "$output" "--expect-cpu-damage-overflow 1" "dry-run runtime diagnostics smoke overflow arg"
  assert_contains "$output" "--expect-cpu-publish-retry-reason mailbox_backpressure" "dry-run runtime diagnostics smoke retry arg"
  assert_contains "$output" "--expect-cpu-publish-warning true" "dry-run runtime diagnostics smoke warning arg"
  pass "dry-run passes runtime diagnostics smoke expectations"
}

case_runtime_diagnostics_smoke_expectations_require_filter() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_DAMAGE_OVERFLOW=1; then
    fail "runtime diagnostics smoke expectations without filter should fail"
  fi

  assert_contains "$output" "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_TEST_FILTER is required when smoke expectations are provided" "runtime diagnostics smoke filter requirement"
  pass "runtime diagnostics smoke expectations require filter"
}

case_dry_run_cpu_frame_damage_mode_passthrough() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_FRAME_DAMAGE_MODE=off; then
    fail "dry-run with cpu frame damage mode should succeed"
  fi

  assert_contains "$output" "dry-run compat-check command" "dry-run command print"
  assert_contains "$output" "--cpu-frame-damage-mode off" "dry-run cpu frame damage mode arg"
  assert_contains "$output" "--expect-cpu-frame-damage-mode off" "dry-run cpu frame damage mode expect arg"
  pass "dry-run passes cpu frame damage mode"
}

case_dry_run_cpu_damage_rect_cap_passthrough() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_DAMAGE_RECT_CAP=64; then
    fail "dry-run with cpu damage rect cap should succeed"
  fi

  assert_contains "$output" "dry-run compat-check command" "dry-run command print"
  assert_contains "$output" "--cpu-damage-rect-cap 64" "dry-run cpu damage rect cap arg"
  assert_contains "$output" "--expect-cpu-damage-rect-cap 64" "dry-run cpu damage rect cap expect arg"
  pass "dry-run passes cpu damage rect cap"
}

case_cpu_damage_rect_cap_invalid_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_DAMAGE_RECT_CAP=70000; then
    fail "invalid cpu damage rect cap should fail"
  fi

  assert_contains "$output" "invalid SR_CI_CPU_DAMAGE_RECT_CAP" "invalid cpu damage rect cap"
  pass "invalid cpu damage rect cap fails fast"
}

case_cpu_damage_rect_cap_non_numeric_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_DAMAGE_RECT_CAP=abc; then
    fail "non-numeric cpu damage rect cap should fail"
  fi

  assert_contains "$output" "invalid SR_CI_CPU_DAMAGE_RECT_CAP: abc (expected: u16)" "non-numeric cpu damage rect cap"
  pass "non-numeric cpu damage rect cap fails fast"
}

case_cpu_frame_damage_mode_invalid_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_FRAME_DAMAGE_MODE=tiles; then
    fail "invalid cpu frame damage mode should fail"
  fi

  assert_contains "$output" "invalid SR_CI_CPU_FRAME_DAMAGE_MODE: tiles (expected: off|rects)" "invalid cpu frame damage mode"
  pass "invalid cpu frame damage mode fails fast"
}

case_cpu_publish_warning_threshold_invalid_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS=4294967296; then
    fail "invalid cpu publish warning threshold should fail"
  fi

  assert_contains "$output" "invalid SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS" "invalid cpu publish warning threshold"
  pass "invalid cpu publish warning threshold fails fast"
}

case_cpu_publish_warning_consecutive_limit_invalid_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT=256; then
    fail "invalid cpu publish warning consecutive limit should fail"
  fi

  assert_contains "$output" "invalid SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT" "invalid cpu publish warning consecutive limit"
  pass "invalid cpu publish warning consecutive limit fails fast"
}

case_expect_cpu_publish_retry_reason_invalid_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_EXPECT_CPU_PUBLISH_RETRY_REASON=pressure; then
    fail "invalid cpu publish retry reason should fail"
  fi

  assert_contains "$output" "invalid SR_CI_EXPECT_CPU_PUBLISH_RETRY_REASON: pressure" "invalid cpu publish retry reason"
  pass "invalid cpu publish retry reason fails fast"
}

case_expect_cpu_damage_overflow_invalid_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW=one; then
    fail "invalid cpu damage overflow expectation should fail"
  fi

  assert_contains "$output" "invalid SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW: one (expected: u64)" "invalid cpu damage overflow"
  pass "invalid cpu damage overflow expectation fails fast"
}

case_expect_cpu_damage_overflow_too_large_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW=18446744073709551616; then
    fail "too-large cpu damage overflow expectation should fail"
  fi

  assert_contains "$output" "invalid SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW: 18446744073709551616 (expected: 0..18446744073709551615)" "too-large cpu damage overflow"
  pass "too-large cpu damage overflow expectation fails fast"
}

case_expect_cpu_publish_warning_invalid_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_EXPECT_CPU_PUBLISH_WARNING=maybe; then
    fail "invalid cpu publish warning expectation should fail"
  fi

  assert_contains "$output" "invalid SR_CI_EXPECT_CPU_PUBLISH_WARNING: maybe (expected: true|false)" "invalid cpu publish warning expectation"
  pass "invalid cpu publish warning expectation fails fast"
}

case_force_allow_legacy_os_invalid_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_FORCE_ALLOW_LEGACY_OS=maybe; then
    fail "invalid force allow legacy os should fail"
  fi

  assert_contains "$output" "invalid SR_CI_FORCE_ALLOW_LEGACY_OS: maybe (expected: true|false)" "invalid force allow legacy os"
  pass "invalid force allow legacy os fails fast"
}

case_dry_run_cpu_shader_reprobe_interval_frames_passthrough() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES=77; then
    fail "dry-run with cpu shader reprobe interval should succeed"
  fi

  assert_contains "$output" "dry-run compat-check command" "dry-run command print"
  assert_contains "$output" "--cpu-shader-reprobe-interval-frames 77" "dry-run cpu shader reprobe interval arg"
  assert_contains "$output" "--expect-cpu-shader-reprobe-interval-frames 77" "dry-run cpu shader reprobe interval expect arg"
  pass "dry-run passes cpu shader reprobe interval"
}

case_dry_run_cpu_shader_reprobe_interval_zero_passthrough() {
  local output
  if ! run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES=0; then
    fail "dry-run with cpu shader reprobe interval=0 should succeed"
  fi

  assert_contains "$output" "dry-run compat-check command" "dry-run command print"
  assert_contains "$output" "--cpu-shader-reprobe-interval-frames 0" "dry-run cpu shader reprobe interval zero arg"
  assert_contains "$output" "--expect-cpu-shader-reprobe-interval-frames 0" "dry-run cpu shader reprobe interval zero expect arg"
  pass "dry-run passes cpu shader reprobe interval zero"
}

case_cpu_shader_reprobe_interval_invalid_fails() {
  local output
  if run_with_env output \
    SR_CI_OS=linux \
    SR_CI_TRANSPORT_MODE=auto \
    SR_CI_DRY_RUN=true \
    SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES=70000; then
    fail "invalid cpu shader reprobe interval should fail"
  fi

  assert_contains "$output" "invalid SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES" "invalid reprobe interval"
  pass "invalid cpu shader reprobe interval fails fast"
}

test_cases=(
  case_target_gate_mismatch_fails
  case_missing_os_fails_fast
  case_missing_transport_mode_fails_fast
  case_invalid_os_fails_fast
  case_invalid_transport_mode_fails_fast
  case_macos_missing_system_path_fails
  case_target_os_mismatch_fails
  case_route_backend_os_mismatch_fails
  case_dry_run_route_backend_flag_present
  case_dry_run_route_backend_flag_present_macos
  case_linux_legacy_target_defaults_to_no_override
  case_linux_legacy_target_force_enable_uses_gtk_runtime_and_normalizes_knobs
  case_linux_legacy_target_force_disable_stays_disabled
  case_linux_non_legacy_auto_transport_uses_none_runtime
  case_macos_default_route_backend_is_metal
  case_macos_legacy_target_defaults_to_no_override
  case_macos_legacy_target_force_enable_normalizes_knobs
  case_dry_run_cpu_publish_warning_knobs_passthrough
  case_dry_run_cpu_publish_warning_threshold_only_passthrough
  case_dry_run_runtime_diagnostics_expectations_passthrough
  case_dry_run_runtime_diagnostics_zero_and_false_passthrough
  case_dry_run_runtime_diagnostics_smoke_passthrough
  case_runtime_diagnostics_smoke_expectations_require_filter
  case_dry_run_cpu_frame_damage_mode_passthrough
  case_dry_run_cpu_damage_rect_cap_passthrough
  case_cpu_damage_rect_cap_invalid_fails
  case_cpu_damage_rect_cap_non_numeric_fails
  case_cpu_frame_damage_mode_invalid_fails
  case_cpu_publish_warning_threshold_invalid_fails
  case_cpu_publish_warning_consecutive_limit_invalid_fails
  case_expect_cpu_publish_retry_reason_invalid_fails
  case_expect_cpu_damage_overflow_invalid_fails
  case_expect_cpu_damage_overflow_too_large_fails
  case_expect_cpu_publish_warning_invalid_fails
  case_force_allow_legacy_os_invalid_fails
  case_dry_run_cpu_shader_reprobe_interval_frames_passthrough
  case_dry_run_cpu_shader_reprobe_interval_zero_passthrough
  case_cpu_shader_reprobe_interval_invalid_fails
)

for test_case in "${test_cases[@]}"; do
  "$test_case"
done

echo "[selftest] summary: passed ${#test_cases[@]} cases"
echo "[selftest] all checks passed"
