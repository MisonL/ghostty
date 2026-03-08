#!/usr/bin/env bash

set -euo pipefail

echo "[software-renderer-ci] phase=init"

decimal_exceeds_u64() {
  local value="$1"
  local max_u64="18446744073709551615"

  if (( ${#value} < ${#max_u64} )); then
    return 1
  fi
  if (( ${#value} > ${#max_u64} )); then
    return 0
  fi

  [[ "$value" > "$max_u64" ]]
}

is_valid_bool_text() {
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]]
}

is_valid_cpu_publish_retry_reason() {
  local value="$1"
  [[ "$value" == "invalid_surface" || "$value" == "pool_retired_pressure" || "$value" == "frame_pool_exhausted" || "$value" == "mailbox_backpressure" ]]
}

validate_bool_env_value() {
  local var_name="$1"
  local value="$2"

  if [[ -n "$value" ]] && ! is_valid_bool_text "$value"; then
    echo "invalid $var_name: $value (expected: true|false)" >&2
    exit 2
  fi
}

validate_cpu_publish_retry_reason_env_value() {
  local var_name="$1"
  local value="$2"

  if [[ -n "$value" ]] && ! is_valid_cpu_publish_retry_reason "$value"; then
    echo "invalid $var_name: $value (expected: invalid_surface|pool_retired_pressure|frame_pool_exhausted|mailbox_backpressure)" >&2
    exit 2
  fi
}

validate_u64_env_value() {
  local var_name="$1"
  local value="$2"

  if [[ -n "$value" && ! "$value" =~ ^[0-9]+$ ]]; then
    echo "invalid $var_name: $value (expected: u64)" >&2
    exit 2
  fi
  if [[ -n "$value" ]] && decimal_exceeds_u64 "$value"; then
    echo "invalid $var_name: $value (expected: 0..18446744073709551615)" >&2
    exit 2
  fi
}

resolve_alias_value() {
  local legacy_name="$1"
  local legacy_value="$2"
  local preferred_name="$3"
  local preferred_value="$4"

  if [[ -n "$legacy_value" && -n "$preferred_value" && "$legacy_value" != "$preferred_value" ]]; then
    echo "conflicting smoke configuration: $legacy_name=$legacy_value but $preferred_name=$preferred_value" >&2
    exit 2
  fi

  if [[ -n "$preferred_value" ]]; then
    printf '%s' "$preferred_value"
  else
    printf '%s' "$legacy_value"
  fi
}

if [[ -z "${SR_CI_OS:-}" ]]; then
  echo "SR_CI_OS is required (linux|macos)" >&2
  exit 2
fi
if [[ -z "${SR_CI_TRANSPORT_MODE:-}" ]]; then
  echo "SR_CI_TRANSPORT_MODE is required (auto|shared|native)" >&2
  exit 2
fi
if [[ "$SR_CI_OS" != "linux" && "$SR_CI_OS" != "macos" ]]; then
  echo "invalid SR_CI_OS: $SR_CI_OS" >&2
  exit 2
fi
if [[ "$SR_CI_TRANSPORT_MODE" != "auto" && "$SR_CI_TRANSPORT_MODE" != "shared" && "$SR_CI_TRANSPORT_MODE" != "native" ]]; then
  echo "invalid SR_CI_TRANSPORT_MODE: $SR_CI_TRANSPORT_MODE (expected: auto|shared|native)" >&2
  exit 2
fi

target="${SR_CI_TARGET:-}"
target_label="${SR_CI_TARGET_LABEL:-unknown-target}"
transport_label="${SR_CI_TRANSPORT_LABEL:-unknown-transport}"
force_allow_legacy_os="${SR_CI_FORCE_ALLOW_LEGACY_OS:-}"
expect_cpu_effective="${SR_CI_EXPECT_CPU_EFFECTIVE:-}"
expect_software_route_backend="${SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND:-}"
cpu_shader_mode="${SR_CI_CPU_SHADER_MODE:-}"
cpu_shader_backend_is_set=false
if [[ "${SR_CI_CPU_SHADER_BACKEND+x}" == "x" ]]; then
  cpu_shader_backend_is_set=true
fi
cpu_shader_backend="${SR_CI_CPU_SHADER_BACKEND:-}"
expect_cpu_shader_backend="${SR_CI_EXPECT_CPU_SHADER_BACKEND:-}"
cpu_shader_timeout_ms="${SR_CI_CPU_SHADER_TIMEOUT_MS:-}"
cpu_shader_reprobe_interval_frames="${SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES:-}"
cpu_shader_enable_minimal_runtime="${SR_CI_CPU_SHADER_ENABLE_MINIMAL_RUNTIME:-}"
inject_fake_swiftshader_hint="${SR_CI_INJECT_FAKE_SWIFTSHADER_HINT:-}"
expect_cpu_shader_capability_status="${SR_CI_EXPECT_CPU_SHADER_CAPABILITY_STATUS:-}"
expect_cpu_shader_capability_reason="${SR_CI_EXPECT_CPU_SHADER_CAPABILITY_REASON:-}"
expect_cpu_shader_capability_hint_source="${SR_CI_EXPECT_CPU_SHADER_CAPABILITY_HINT_SOURCE:-}"
expect_cpu_shader_capability_hint_readable="${SR_CI_EXPECT_CPU_SHADER_CAPABILITY_HINT_READABLE:-}"
cpu_frame_damage_mode="${SR_CI_CPU_FRAME_DAMAGE_MODE:-}"
cpu_damage_rect_cap="${SR_CI_CPU_DAMAGE_RECT_CAP:-}"
cpu_publish_warning_threshold_ms="${SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS:-}"
cpu_publish_warning_consecutive_limit="${SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT:-}"
expect_cpu_publish_retry_reason="${SR_CI_EXPECT_CPU_PUBLISH_RETRY_REASON:-}"
expect_cpu_damage_overflow="${SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW:-}"
expect_cpu_publish_warning="${SR_CI_EXPECT_CPU_PUBLISH_WARNING:-}"
expect_cpu_publish_success="${SR_CI_EXPECT_CPU_PUBLISH_SUCCESS:-}"
runtime_diagnostics_smoke_test_filter="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_TEST_FILTER:-}"
runtime_diagnostics_smoke_expect_cpu_publish_retry_reason="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_PUBLISH_RETRY_REASON:-}"
runtime_diagnostics_smoke_expect_cpu_damage_overflow="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_DAMAGE_OVERFLOW:-}"
runtime_diagnostics_smoke_expect_cpu_publish_warning="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_PUBLISH_WARNING:-}"
runtime_diagnostics_smoke_primary_test_filter="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_TEST_FILTER:-}"
runtime_diagnostics_smoke_primary_expect_cpu_publish_retry_reason="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_PUBLISH_RETRY_REASON:-}"
runtime_diagnostics_smoke_primary_expect_cpu_damage_overflow="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_DAMAGE_OVERFLOW:-}"
runtime_diagnostics_smoke_primary_expect_cpu_publish_warning="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_PUBLISH_WARNING:-}"
runtime_diagnostics_smoke_secondary_test_filter="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_TEST_FILTER:-}"
runtime_diagnostics_smoke_secondary_expect_cpu_publish_retry_reason="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_PUBLISH_RETRY_REASON:-}"
runtime_diagnostics_smoke_secondary_expect_cpu_damage_overflow="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_DAMAGE_OVERFLOW:-}"
runtime_diagnostics_smoke_secondary_expect_cpu_publish_warning="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_PUBLISH_WARNING:-}"
runtime_diagnostics_smoke_published_test_filter="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PUBLISHED_TEST_FILTER:-}"
runtime_diagnostics_smoke_published_expect_cpu_publish_success="${SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PUBLISHED_EXPECT_CPU_PUBLISH_SUCCESS:-}"
system_path="${SR_CI_SYSTEM_PATH:-}"
dry_run="${SR_CI_DRY_RUN:-false}"

if [[ "$dry_run" != "true" && "$dry_run" != "false" ]]; then
  echo "invalid SR_CI_DRY_RUN: $dry_run (expected: true|false)" >&2
  exit 2
fi
if [[ -n "$force_allow_legacy_os" && "$force_allow_legacy_os" != "true" && "$force_allow_legacy_os" != "false" ]]; then
  echo "invalid SR_CI_FORCE_ALLOW_LEGACY_OS: $force_allow_legacy_os (expected: true|false)" >&2
  exit 2
fi
if [[ -n "$expect_cpu_effective" && "$expect_cpu_effective" != "true" && "$expect_cpu_effective" != "false" ]]; then
  echo "invalid SR_CI_EXPECT_CPU_EFFECTIVE: $expect_cpu_effective (expected: true|false)" >&2
  exit 2
fi
if [[ -n "$expect_software_route_backend" && "$expect_software_route_backend" != "opengl" && "$expect_software_route_backend" != "metal" ]]; then
  echo "invalid SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND: $expect_software_route_backend (expected: opengl|metal)" >&2
  exit 2
fi
if [[ -n "$cpu_frame_damage_mode" && "$cpu_frame_damage_mode" != "off" && "$cpu_frame_damage_mode" != "rects" ]]; then
  echo "invalid SR_CI_CPU_FRAME_DAMAGE_MODE: $cpu_frame_damage_mode (expected: off|rects)" >&2
  exit 2
fi
if [[ -n "$cpu_shader_reprobe_interval_frames" ]]; then
  if ! [[ "$cpu_shader_reprobe_interval_frames" =~ ^[0-9]+$ ]]; then
    echo "invalid SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES: $cpu_shader_reprobe_interval_frames (expected: u16)" >&2
    exit 2
  fi
  if (( ${#cpu_shader_reprobe_interval_frames} > 5 )) || {
    (( ${#cpu_shader_reprobe_interval_frames} == 5 )) && (( cpu_shader_reprobe_interval_frames > 65535 ))
  }; then
    echo "invalid SR_CI_CPU_SHADER_REPROBE_INTERVAL_FRAMES: $cpu_shader_reprobe_interval_frames (expected: 0..65535)" >&2
    exit 2
  fi
fi
if [[ -n "$cpu_damage_rect_cap" ]]; then
  if ! [[ "$cpu_damage_rect_cap" =~ ^[0-9]+$ ]]; then
    echo "invalid SR_CI_CPU_DAMAGE_RECT_CAP: $cpu_damage_rect_cap (expected: u16)" >&2
    exit 2
  fi
  if (( ${#cpu_damage_rect_cap} > 5 )) || {
    (( ${#cpu_damage_rect_cap} == 5 )) && (( cpu_damage_rect_cap > 65535 ))
  }; then
    echo "invalid SR_CI_CPU_DAMAGE_RECT_CAP: $cpu_damage_rect_cap (expected: 0..65535)" >&2
    exit 2
  fi
fi
if [[ -n "$cpu_publish_warning_threshold_ms" ]]; then
  if ! [[ "$cpu_publish_warning_threshold_ms" =~ ^[0-9]+$ ]]; then
    echo "invalid SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS: $cpu_publish_warning_threshold_ms (expected: u32)" >&2
    exit 2
  fi
  if (( ${#cpu_publish_warning_threshold_ms} > 10 )) || {
    (( ${#cpu_publish_warning_threshold_ms} == 10 )) && (( cpu_publish_warning_threshold_ms > 4294967295 ))
  }; then
    echo "invalid SR_CI_CPU_PUBLISH_WARNING_THRESHOLD_MS: $cpu_publish_warning_threshold_ms (expected: 0..4294967295)" >&2
    exit 2
  fi
fi
if [[ -n "$cpu_publish_warning_consecutive_limit" ]]; then
  if ! [[ "$cpu_publish_warning_consecutive_limit" =~ ^[0-9]+$ ]]; then
    echo "invalid SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT: $cpu_publish_warning_consecutive_limit (expected: u8)" >&2
    exit 2
  fi
  if (( ${#cpu_publish_warning_consecutive_limit} > 3 )) || {
    (( ${#cpu_publish_warning_consecutive_limit} == 3 )) && (( cpu_publish_warning_consecutive_limit > 255 ))
  }; then
    echo "invalid SR_CI_CPU_PUBLISH_WARNING_CONSECUTIVE_LIMIT: $cpu_publish_warning_consecutive_limit (expected: 0..255)" >&2
    exit 2
  fi
fi
validate_cpu_publish_retry_reason_env_value "SR_CI_EXPECT_CPU_PUBLISH_RETRY_REASON" "$expect_cpu_publish_retry_reason"
validate_u64_env_value "SR_CI_EXPECT_CPU_DAMAGE_OVERFLOW" "$expect_cpu_damage_overflow"
validate_bool_env_value "SR_CI_EXPECT_CPU_PUBLISH_WARNING" "$expect_cpu_publish_warning"
validate_bool_env_value "SR_CI_EXPECT_CPU_PUBLISH_SUCCESS" "$expect_cpu_publish_success"
validate_cpu_publish_retry_reason_env_value "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_PUBLISH_RETRY_REASON" "$runtime_diagnostics_smoke_expect_cpu_publish_retry_reason"
validate_u64_env_value "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_DAMAGE_OVERFLOW" "$runtime_diagnostics_smoke_expect_cpu_damage_overflow"
validate_bool_env_value "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_PUBLISH_WARNING" "$runtime_diagnostics_smoke_expect_cpu_publish_warning"
validate_cpu_publish_retry_reason_env_value "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_PUBLISH_RETRY_REASON" "$runtime_diagnostics_smoke_primary_expect_cpu_publish_retry_reason"
validate_u64_env_value "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_DAMAGE_OVERFLOW" "$runtime_diagnostics_smoke_primary_expect_cpu_damage_overflow"
validate_bool_env_value "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_PUBLISH_WARNING" "$runtime_diagnostics_smoke_primary_expect_cpu_publish_warning"
validate_cpu_publish_retry_reason_env_value "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_PUBLISH_RETRY_REASON" "$runtime_diagnostics_smoke_secondary_expect_cpu_publish_retry_reason"
validate_u64_env_value "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_DAMAGE_OVERFLOW" "$runtime_diagnostics_smoke_secondary_expect_cpu_damage_overflow"
validate_bool_env_value "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_EXPECT_CPU_PUBLISH_WARNING" "$runtime_diagnostics_smoke_secondary_expect_cpu_publish_warning"
validate_bool_env_value "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PUBLISHED_EXPECT_CPU_PUBLISH_SUCCESS" "$runtime_diagnostics_smoke_published_expect_cpu_publish_success"

resolved_runtime_diagnostics_smoke_primary_test_filter="$(
  resolve_alias_value \
    "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_TEST_FILTER" \
    "$runtime_diagnostics_smoke_test_filter" \
    "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_TEST_FILTER" \
    "$runtime_diagnostics_smoke_primary_test_filter"
)"
resolved_runtime_diagnostics_smoke_primary_expect_cpu_publish_retry_reason="$(
  resolve_alias_value \
    "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_PUBLISH_RETRY_REASON" \
    "$runtime_diagnostics_smoke_expect_cpu_publish_retry_reason" \
    "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_PUBLISH_RETRY_REASON" \
    "$runtime_diagnostics_smoke_primary_expect_cpu_publish_retry_reason"
)"
resolved_runtime_diagnostics_smoke_primary_expect_cpu_damage_overflow="$(
  resolve_alias_value \
    "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_DAMAGE_OVERFLOW" \
    "$runtime_diagnostics_smoke_expect_cpu_damage_overflow" \
    "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_DAMAGE_OVERFLOW" \
    "$runtime_diagnostics_smoke_primary_expect_cpu_damage_overflow"
)"
resolved_runtime_diagnostics_smoke_primary_expect_cpu_publish_warning="$(
  resolve_alias_value \
    "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_EXPECT_CPU_PUBLISH_WARNING" \
    "$runtime_diagnostics_smoke_expect_cpu_publish_warning" \
    "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_EXPECT_CPU_PUBLISH_WARNING" \
    "$runtime_diagnostics_smoke_primary_expect_cpu_publish_warning"
)"
resolved_runtime_diagnostics_smoke_secondary_test_filter="$runtime_diagnostics_smoke_secondary_test_filter"
resolved_runtime_diagnostics_smoke_secondary_expect_cpu_publish_retry_reason="$runtime_diagnostics_smoke_secondary_expect_cpu_publish_retry_reason"
resolved_runtime_diagnostics_smoke_secondary_expect_cpu_damage_overflow="$runtime_diagnostics_smoke_secondary_expect_cpu_damage_overflow"
resolved_runtime_diagnostics_smoke_secondary_expect_cpu_publish_warning="$runtime_diagnostics_smoke_secondary_expect_cpu_publish_warning"
resolved_runtime_diagnostics_smoke_published_test_filter="$runtime_diagnostics_smoke_published_test_filter"
resolved_runtime_diagnostics_smoke_published_expect_cpu_publish_success="$runtime_diagnostics_smoke_published_expect_cpu_publish_success"

if [[ -z "$resolved_runtime_diagnostics_smoke_primary_test_filter" && ( -n "$resolved_runtime_diagnostics_smoke_primary_expect_cpu_publish_retry_reason" || -n "$resolved_runtime_diagnostics_smoke_primary_expect_cpu_damage_overflow" || -n "$resolved_runtime_diagnostics_smoke_primary_expect_cpu_publish_warning" ) ]]; then
  if [[ -n "$runtime_diagnostics_smoke_primary_expect_cpu_publish_retry_reason" || -n "$runtime_diagnostics_smoke_primary_expect_cpu_damage_overflow" || -n "$runtime_diagnostics_smoke_primary_expect_cpu_publish_warning" || -n "$runtime_diagnostics_smoke_primary_test_filter" ]]; then
    echo "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PRIMARY_TEST_FILTER is required when primary smoke expectations are provided" >&2
  else
    echo "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_TEST_FILTER is required when smoke expectations are provided" >&2
  fi
  exit 2
fi
if [[ -z "$resolved_runtime_diagnostics_smoke_secondary_test_filter" && ( -n "$resolved_runtime_diagnostics_smoke_secondary_expect_cpu_publish_retry_reason" || -n "$resolved_runtime_diagnostics_smoke_secondary_expect_cpu_damage_overflow" || -n "$resolved_runtime_diagnostics_smoke_secondary_expect_cpu_publish_warning" ) ]]; then
  echo "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_SECONDARY_TEST_FILTER is required when secondary smoke expectations are provided" >&2
  exit 2
fi
if [[ -z "$resolved_runtime_diagnostics_smoke_published_test_filter" && -n "$resolved_runtime_diagnostics_smoke_published_expect_cpu_publish_success" ]]; then
  echo "SR_CI_RUNTIME_DIAGNOSTICS_SMOKE_PUBLISHED_TEST_FILTER is required when published smoke expectations are provided" >&2
  exit 2
fi

allow_legacy_os=false
target_os=""
target_major=""
target_is_legacy_os=false
legacy_override_source=default
app_runtime=none
expected_route_backend_for_os=opengl
if [[ "$SR_CI_OS" == "macos" ]]; then
  expected_route_backend_for_os=metal
fi

if [[ -n "$target" ]]; then
  if [[ "$target" =~ ^[^-]+-([^.]+)\. ]]; then
    target_os="${BASH_REMATCH[1]}"
  else
    echo "Unrecognized target format: $target (expected: <arch>-linux.<major>.<minor>[.<patch>] or <arch>-macos.<major>[.<minor>[.<patch>]])" >&2
    exit 1
  fi
  if [[ "$target_os" != "linux" && "$target_os" != "macos" ]]; then
    echo "Unsupported SR_CI_TARGET OS '$target_os' in target=$target; cpu-route CI supports linux|macos only" >&2
    exit 1
  fi
  if [[ "$target_os" != "$SR_CI_OS" ]]; then
    echo "SR_CI_TARGET OS mismatch: SR_CI_OS=$SR_CI_OS but target=$target (target-os=$target_os)" >&2
    exit 1
  fi

  if [[ "$SR_CI_OS" == "linux" ]]; then
    if [[ "$target" =~ ^[^-]+-linux\.([0-9]+)\.([0-9]+)(\..*)?$ ]]; then
      target_major="${BASH_REMATCH[1]}"
      if (( target_major < 5 )); then
        target_is_legacy_os=true
      fi
    else
      echo "Unrecognized linux target format: $target" >&2
      exit 1
    fi
  else
    if [[ "$target" =~ ^[^-]+-macos\.([0-9]+)(\..*)?$ ]]; then
      target_major="${BASH_REMATCH[1]}"
      if (( target_major < 11 )); then
        target_is_legacy_os=true
      fi
    else
      echo "Unrecognized macOS target format: $target" >&2
      exit 1
    fi
  fi
fi

if [[ -n "$force_allow_legacy_os" ]]; then
  allow_legacy_os="$force_allow_legacy_os"
  legacy_override_source=SR_CI_FORCE_ALLOW_LEGACY_OS
fi
if [[ "$allow_legacy_os" != "true" && "$allow_legacy_os" != "false" ]]; then
  echo "Invalid computed allow_legacy_os value: $allow_legacy_os" >&2
  exit 1
fi
if [[ "$SR_CI_OS" == "linux" && "$allow_legacy_os" == "true" && "$SR_CI_TRANSPORT_MODE" == "auto" ]]; then
  app_runtime=gtk
fi

target_gate_expected_cpu_effective="unknown"
if [[ -n "$target" && -n "$target_major" ]]; then
  target_supported=true
  if [[ "$SR_CI_OS" == "linux" ]]; then
    if (( target_major < 5 )); then target_supported=false; fi
  else
    if (( target_major < 11 )); then target_supported=false; fi
  fi

  if [[ "$target_supported" == "true" || "$allow_legacy_os" == "true" ]]; then
    target_gate_expected_cpu_effective=true
  else
    target_gate_expected_cpu_effective=false
  fi
fi

if [[ "$target_gate_expected_cpu_effective" != "unknown" && -n "$expect_cpu_effective" && "$expect_cpu_effective" != "$target_gate_expected_cpu_effective" ]]; then
  echo "Target gate expected cpu_effective ($target_gate_expected_cpu_effective) mismatches matrix expect_cpu_effective ($expect_cpu_effective) for target-label=$target_label target=${target:-default}" >&2
  exit 1
fi

resolved_cpu_shader_mode="$cpu_shader_mode"
resolved_cpu_shader_backend="$cpu_shader_backend"
resolved_cpu_shader_timeout_ms="$cpu_shader_timeout_ms"
resolved_cpu_shader_reprobe_interval_frames="$cpu_shader_reprobe_interval_frames"
resolved_cpu_shader_enable_minimal_runtime="$cpu_shader_enable_minimal_runtime"
resolved_fake_swiftshader_hint="$inject_fake_swiftshader_hint"
resolved_cpu_frame_damage_mode="$cpu_frame_damage_mode"
resolved_cpu_damage_rect_cap="$cpu_damage_rect_cap"
resolved_cpu_publish_warning_threshold_ms="$cpu_publish_warning_threshold_ms"
resolved_cpu_publish_warning_consecutive_limit="$cpu_publish_warning_consecutive_limit"
if [[ -z "$resolved_fake_swiftshader_hint" ]]; then resolved_fake_swiftshader_hint=false; fi
if [[ -z "$resolved_cpu_shader_mode" ]]; then resolved_cpu_shader_mode=full; fi
if [[ -z "$resolved_cpu_shader_backend" ]]; then resolved_cpu_shader_backend=vulkan_swiftshader; fi
if [[ -z "$resolved_cpu_shader_timeout_ms" ]]; then resolved_cpu_shader_timeout_ms=16; fi
if [[ -z "$resolved_cpu_shader_reprobe_interval_frames" ]]; then resolved_cpu_shader_reprobe_interval_frames=120; fi
if [[ -z "$resolved_cpu_shader_enable_minimal_runtime" ]]; then resolved_cpu_shader_enable_minimal_runtime=false; fi
if [[ -z "$resolved_cpu_frame_damage_mode" ]]; then resolved_cpu_frame_damage_mode=rects; fi
if [[ -z "$resolved_cpu_damage_rect_cap" ]]; then resolved_cpu_damage_rect_cap=64; fi
if [[ -z "$resolved_cpu_publish_warning_threshold_ms" ]]; then resolved_cpu_publish_warning_threshold_ms=40; fi
if [[ -z "$resolved_cpu_publish_warning_consecutive_limit" ]]; then resolved_cpu_publish_warning_consecutive_limit=3; fi
effective_cpu_damage_rect_cap="$resolved_cpu_damage_rect_cap"
if [[ "$resolved_cpu_frame_damage_mode" == "rects" && "$effective_cpu_damage_rect_cap" == "0" ]]; then
  effective_cpu_damage_rect_cap=1
fi
effective_cpu_publish_warning_consecutive_limit="$resolved_cpu_publish_warning_consecutive_limit"
if [[ "$effective_cpu_publish_warning_consecutive_limit" == "0" ]]; then
  effective_cpu_publish_warning_consecutive_limit=1
fi
if [[ -z "$expect_cpu_shader_backend" ]]; then
  if [[ "$cpu_shader_backend_is_set" == "true" && -n "$cpu_shader_backend" ]]; then
    expect_cpu_shader_backend="$cpu_shader_backend"
  elif [[ -n "$cpu_shader_mode" && -z "$cpu_shader_backend" ]]; then
    expect_cpu_shader_backend=vulkan_swiftshader
  fi
fi
if [[ -z "$expect_cpu_effective" ]]; then expect_cpu_effective="<unset>"; fi

echo "[software-renderer-ci] $SR_CI_OS target-label=$target_label transport-label=$transport_label target=${target:-default} legacy-target=$target_is_legacy_os allow-legacy-os=$allow_legacy_os legacy-override-source=$legacy_override_source gate-expected-cpu-effective=$target_gate_expected_cpu_effective matrix-expect-cpu-effective=$expect_cpu_effective app-runtime=$app_runtime"
echo "[software-renderer-ci] $SR_CI_OS resolved-cpu-shader mode=$resolved_cpu_shader_mode backend=$resolved_cpu_shader_backend timeout-ms=$resolved_cpu_shader_timeout_ms reprobe-interval-frames=$resolved_cpu_shader_reprobe_interval_frames enable-minimal-runtime=$resolved_cpu_shader_enable_minimal_runtime fake-swiftshader-hint=$resolved_fake_swiftshader_hint expect-cpu-shader-backend=${expect_cpu_shader_backend:-<unset>}"
echo "[software-renderer-ci] $SR_CI_OS resolved-cpu-route frame-damage-mode=$resolved_cpu_frame_damage_mode damage-rect-cap=$resolved_cpu_damage_rect_cap effective-damage-rect-cap=$effective_cpu_damage_rect_cap publish-warning-threshold-ms=$resolved_cpu_publish_warning_threshold_ms publish-warning-consecutive-limit=$resolved_cpu_publish_warning_consecutive_limit effective-publish-warning-consecutive-limit=$effective_cpu_publish_warning_consecutive_limit"
echo "[software-renderer-ci] $SR_CI_OS runtime-diagnostics expect-damage-overflow=${expect_cpu_damage_overflow:-<unset>} expect-publish-retry-reason=${expect_cpu_publish_retry_reason:-<unset>} expect-publish-warning=${expect_cpu_publish_warning:-<unset>} expect-publish-success=${expect_cpu_publish_success:-<unset>}"
echo "[software-renderer-ci] $SR_CI_OS runtime-diagnostics-smoke-primary filter=${resolved_runtime_diagnostics_smoke_primary_test_filter:-<unset>} expect-damage-overflow=${resolved_runtime_diagnostics_smoke_primary_expect_cpu_damage_overflow:-<unset>} expect-publish-retry-reason=${resolved_runtime_diagnostics_smoke_primary_expect_cpu_publish_retry_reason:-<unset>} expect-publish-warning=${resolved_runtime_diagnostics_smoke_primary_expect_cpu_publish_warning:-<unset>}"
echo "[software-renderer-ci] $SR_CI_OS runtime-diagnostics-smoke-secondary filter=${resolved_runtime_diagnostics_smoke_secondary_test_filter:-<unset>} expect-damage-overflow=${resolved_runtime_diagnostics_smoke_secondary_expect_cpu_damage_overflow:-<unset>} expect-publish-retry-reason=${resolved_runtime_diagnostics_smoke_secondary_expect_cpu_publish_retry_reason:-<unset>} expect-publish-warning=${resolved_runtime_diagnostics_smoke_secondary_expect_cpu_publish_warning:-<unset>}"
echo "[software-renderer-ci] $SR_CI_OS runtime-diagnostics-smoke-published filter=${resolved_runtime_diagnostics_smoke_published_test_filter:-<unset>} expect-damage-overflow=<unset> expect-publish-retry-reason=<unset> expect-publish-warning=<unset> expect-publish-success=${resolved_runtime_diagnostics_smoke_published_expect_cpu_publish_success:-<unset>}"
if [[ "$SR_CI_OS" == "macos" ]]; then
  echo "[software-renderer-ci] $SR_CI_OS system-path=${system_path:-<unset>}"
fi
if [[ "$allow_legacy_os" == "true" ]]; then
  echo "[software-renderer-ci] $SR_CI_OS note: allow-legacy-os only bypasses build target-version gate; runtime fallback gates still apply."
elif [[ "$target_is_legacy_os" == "true" ]]; then
  echo "[software-renderer-ci] $SR_CI_OS note: legacy target detected but keep allow-legacy-os=false by default; set SR_CI_FORCE_ALLOW_LEGACY_OS=true to opt into build-time bring-up."
fi

if [[ -n "$expect_software_route_backend" && "$expect_software_route_backend" != "$expected_route_backend_for_os" ]]; then
  echo "SR_CI_EXPECT_SOFTWARE_ROUTE_BACKEND mismatch: SR_CI_OS=$SR_CI_OS expects $expected_route_backend_for_os but got $expect_software_route_backend" >&2
  exit 1
fi

if [[ -n "$expect_software_route_backend" ]]; then
  route_backend="$expect_software_route_backend"
else
  route_backend="$expected_route_backend_for_os"
fi

if [[ "$SR_CI_OS" == "macos" && -z "$system_path" ]]; then
  echo "SR_CI_SYSTEM_PATH is required for macOS software-renderer cpu-path CI (current-value=${system_path:-<unset>})" >&2
  exit 1
fi

print_compat_check_command() {
  local label="$1"
  shift

  printf "[software-renderer-ci] %s: %q" "$label" "./.github/scripts/software-renderer-compat-check.sh"
  for arg in "$@"; do
    printf " %q" "$arg"
  done
  printf "\n"
}

run_compat_check_command() {
  echo "[software-renderer-ci] phase=compat-check-command-start"
  nix develop -c \
    ./.github/scripts/software-renderer-compat-check.sh \
    "$@"
  echo "[software-renderer-ci] phase=compat-check-command-end"
}

run_runtime_diagnostics_smoke_slot() {
  local slot_name="$1"
  local test_filter="$2"
  local expect_cpu_damage_overflow="$3"
  local expect_cpu_publish_retry_reason="$4"
  local expect_cpu_publish_warning="$5"
  local expect_cpu_publish_success="$6"
  local smoke_compat_args=()

  if [[ -z "$test_filter" ]]; then
    return 0
  fi

  smoke_compat_args=("${base_compat_args[@]}")
  smoke_compat_args+=(--test-filter "$test_filter")
  if [[ -n "$expect_cpu_publish_retry_reason" ]]; then
    smoke_compat_args+=(--expect-cpu-publish-retry-reason "$expect_cpu_publish_retry_reason")
  fi
  if [[ -n "$expect_cpu_damage_overflow" ]]; then
    smoke_compat_args+=(--expect-cpu-damage-overflow "$expect_cpu_damage_overflow")
  fi
  if [[ -n "$expect_cpu_publish_warning" ]]; then
    smoke_compat_args+=(--expect-cpu-publish-warning "$expect_cpu_publish_warning")
  fi
  if [[ -n "$expect_cpu_publish_success" ]]; then
    smoke_compat_args+=(--expect-cpu-publish-success "$expect_cpu_publish_success")
  fi

  if [[ "$dry_run" == "true" ]]; then
    print_compat_check_command "dry-run compat-check ${slot_name} smoke command" "${smoke_compat_args[@]}"
    return 0
  fi

  echo "[software-renderer-ci] phase=runtime-diagnostics-smoke-${slot_name}-start filter=$test_filter"
  run_compat_check_command "${smoke_compat_args[@]}"
  echo "[software-renderer-ci] phase=runtime-diagnostics-smoke-${slot_name}-end"
}

base_compat_args=(
  --mode test
  --transport "$SR_CI_TRANSPORT_MODE"
  --allow-legacy-os="$allow_legacy_os"
  --expected-host-os "$SR_CI_OS"
  --mismatch-policy fail
  --expect-software-route-backend "$route_backend"
)
if [[ -n "$cpu_shader_mode" ]]; then
  base_compat_args+=(--cpu-shader-mode "$cpu_shader_mode")
  base_compat_args+=(--expect-cpu-shader-mode "$cpu_shader_mode")
fi
if [[ -n "$cpu_shader_backend" ]]; then
  base_compat_args+=(--cpu-shader-backend "$cpu_shader_backend")
fi
if [[ -n "$expect_cpu_shader_backend" ]]; then
  base_compat_args+=(--expect-cpu-shader-backend "$expect_cpu_shader_backend")
fi
if [[ -n "$cpu_shader_timeout_ms" ]]; then
  base_compat_args+=(--cpu-shader-timeout-ms "$cpu_shader_timeout_ms")
  base_compat_args+=(--expect-cpu-shader-timeout-ms "$cpu_shader_timeout_ms")
fi
if [[ -n "$cpu_shader_reprobe_interval_frames" ]]; then
  base_compat_args+=(--cpu-shader-reprobe-interval-frames "$cpu_shader_reprobe_interval_frames")
  base_compat_args+=(--expect-cpu-shader-reprobe-interval-frames "$cpu_shader_reprobe_interval_frames")
fi
if [[ -n "$cpu_shader_enable_minimal_runtime" ]]; then
  base_compat_args+=(--cpu-shader-enable-minimal-runtime "$cpu_shader_enable_minimal_runtime")
  base_compat_args+=(--expect-cpu-shader-enable-minimal-runtime "$cpu_shader_enable_minimal_runtime")
fi
if [[ -n "$inject_fake_swiftshader_hint" ]]; then
  base_compat_args+=(--inject-fake-swiftshader-hint "$inject_fake_swiftshader_hint")
fi
if [[ -n "$expect_cpu_shader_capability_status" ]]; then
  base_compat_args+=(--expect-cpu-shader-capability-status "$expect_cpu_shader_capability_status")
fi
if [[ -n "$expect_cpu_shader_capability_reason" ]]; then
  base_compat_args+=(--expect-cpu-shader-capability-reason "$expect_cpu_shader_capability_reason")
fi
if [[ -n "$expect_cpu_shader_capability_hint_source" ]]; then
  base_compat_args+=(--expect-cpu-shader-capability-hint-source "$expect_cpu_shader_capability_hint_source")
fi
if [[ -n "$expect_cpu_shader_capability_hint_readable" ]]; then
  base_compat_args+=(--expect-cpu-shader-capability-hint-readable "$expect_cpu_shader_capability_hint_readable")
fi
if [[ -n "$cpu_frame_damage_mode" ]]; then
  base_compat_args+=(--cpu-frame-damage-mode "$cpu_frame_damage_mode")
  base_compat_args+=(--expect-cpu-frame-damage-mode "$cpu_frame_damage_mode")
fi
if [[ -n "$cpu_damage_rect_cap" ]]; then
  base_compat_args+=(--cpu-damage-rect-cap "$cpu_damage_rect_cap")
  base_compat_args+=(--expect-cpu-damage-rect-cap "$effective_cpu_damage_rect_cap")
fi
if [[ -n "$cpu_publish_warning_threshold_ms" ]]; then
  base_compat_args+=(--cpu-publish-warning-threshold-ms "$cpu_publish_warning_threshold_ms")
  base_compat_args+=(--expect-cpu-publish-warning-threshold-ms "$cpu_publish_warning_threshold_ms")
fi
if [[ -n "$cpu_publish_warning_consecutive_limit" ]]; then
  base_compat_args+=(--cpu-publish-warning-consecutive-limit "$cpu_publish_warning_consecutive_limit")
  base_compat_args+=(--expect-cpu-publish-warning-consecutive-limit "$effective_cpu_publish_warning_consecutive_limit")
fi
if [[ -n "$target" ]]; then
  base_compat_args+=(--target "$target")
fi
if [[ "$expect_cpu_effective" != "<unset>" ]]; then
  base_compat_args+=(--expect-cpu-effective "$expect_cpu_effective")
fi
if [[ "$SR_CI_OS" == "linux" ]]; then
  base_compat_args+=(--app-runtime "$app_runtime")
else
  base_compat_args+=(--system "$system_path")
fi

compat_args=("${base_compat_args[@]}")
if [[ -n "$expect_cpu_publish_retry_reason" ]]; then
  compat_args+=(--expect-cpu-publish-retry-reason "$expect_cpu_publish_retry_reason")
fi
if [[ -n "$expect_cpu_damage_overflow" ]]; then
  compat_args+=(--expect-cpu-damage-overflow "$expect_cpu_damage_overflow")
fi
if [[ -n "$expect_cpu_publish_warning" ]]; then
  compat_args+=(--expect-cpu-publish-warning "$expect_cpu_publish_warning")
fi
if [[ -n "$expect_cpu_publish_success" ]]; then
  compat_args+=(--expect-cpu-publish-success "$expect_cpu_publish_success")
fi

if [[ "$dry_run" == "true" ]]; then
  echo "[software-renderer-ci] phase=dry-run"
  print_compat_check_command "dry-run compat-check command" "${compat_args[@]}"
  run_runtime_diagnostics_smoke_slot \
    "primary" \
    "$resolved_runtime_diagnostics_smoke_primary_test_filter" \
    "$resolved_runtime_diagnostics_smoke_primary_expect_cpu_damage_overflow" \
    "$resolved_runtime_diagnostics_smoke_primary_expect_cpu_publish_retry_reason" \
    "$resolved_runtime_diagnostics_smoke_primary_expect_cpu_publish_warning" \
    ""
  run_runtime_diagnostics_smoke_slot \
    "secondary" \
    "$resolved_runtime_diagnostics_smoke_secondary_test_filter" \
    "$resolved_runtime_diagnostics_smoke_secondary_expect_cpu_damage_overflow" \
    "$resolved_runtime_diagnostics_smoke_secondary_expect_cpu_publish_retry_reason" \
    "$resolved_runtime_diagnostics_smoke_secondary_expect_cpu_publish_warning" \
    ""
  run_runtime_diagnostics_smoke_slot \
    "published" \
    "$resolved_runtime_diagnostics_smoke_published_test_filter" \
    "" \
    "" \
    "" \
    "$resolved_runtime_diagnostics_smoke_published_expect_cpu_publish_success"
  exit 0
fi

echo "[software-renderer-ci] phase=compat-check-main-start"
run_compat_check_command "${compat_args[@]}"
echo "[software-renderer-ci] phase=compat-check-main-end"
run_runtime_diagnostics_smoke_slot \
  "primary" \
  "$resolved_runtime_diagnostics_smoke_primary_test_filter" \
  "$resolved_runtime_diagnostics_smoke_primary_expect_cpu_damage_overflow" \
  "$resolved_runtime_diagnostics_smoke_primary_expect_cpu_publish_retry_reason" \
  "$resolved_runtime_diagnostics_smoke_primary_expect_cpu_publish_warning" \
  ""
run_runtime_diagnostics_smoke_slot \
  "secondary" \
  "$resolved_runtime_diagnostics_smoke_secondary_test_filter" \
  "$resolved_runtime_diagnostics_smoke_secondary_expect_cpu_damage_overflow" \
  "$resolved_runtime_diagnostics_smoke_secondary_expect_cpu_publish_retry_reason" \
  "$resolved_runtime_diagnostics_smoke_secondary_expect_cpu_publish_warning" \
  ""

run_runtime_diagnostics_smoke_slot \
  "published" \
  "$resolved_runtime_diagnostics_smoke_published_test_filter" \
  "" \
  "" \
  "" \
  "$resolved_runtime_diagnostics_smoke_published_expect_cpu_publish_success"

echo "[software-renderer-ci] phase=success"
