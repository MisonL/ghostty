#!/usr/bin/env bash

set -euo pipefail

echo "[software-compat] phase=init"

usage() {
  cat <<'EOF'
Usage:
  .github/scripts/software-renderer-compat-check.sh \
    [--transport <auto|shared|native>] \
    [--test-filter <zig-test-filter>] \
    [--target <zig-target>] \
    [--allow-legacy-os <true|false>] \
    [--cpu-shader-mode <off|safe|full>] \
    [--cpu-shader-backend <off|vulkan_swiftshader>] \
    [--cpu-shader-timeout-ms <u32>] \
    [--cpu-shader-reprobe-interval-frames <u16>] \
    [--cpu-shader-enable-minimal-runtime <true|false>] \
    [--inject-fake-swiftshader-hint <true|false>] \
    [--cpu-frame-damage-mode <off|rects>] \
    [--cpu-damage-rect-cap <u16>] \
    [--cpu-publish-warning-threshold-ms <u32>] \
    [--cpu-publish-warning-consecutive-limit <u8>] \
    [--expect-cpu-effective <true|false>] \
    [--expect-cpu-shader-mode <off|safe|full>] \
    [--expect-cpu-shader-backend <off|vulkan_swiftshader>] \
    [--expect-cpu-shader-timeout-ms <u32>] \
    [--expect-cpu-shader-reprobe-interval-frames <u16>] \
    [--expect-cpu-shader-enable-minimal-runtime <true|false>] \
    [--expect-cpu-shader-capability-status <available|unavailable>] \
    [--expect-cpu-shader-capability-reason <reason|n/a>] \
    [--expect-cpu-shader-capability-hint-source <vk_driver_files|vk_icd_filenames|vk_add_driver_files|none|n/a>] \
    [--expect-cpu-shader-capability-hint-readable <true|false>] \
    [--expect-cpu-frame-damage-mode <off|rects>] \
    [--expect-cpu-damage-rect-cap <u16>] \
    [--expect-cpu-publish-warning-threshold-ms <u32>] \
    [--expect-cpu-publish-warning-consecutive-limit <u8>] \
    [--expect-cpu-publish-retry-reason <invalid_surface|pool_retired_pressure|frame_pool_exhausted|mailbox_backpressure>] \
    [--expect-cpu-damage-overflow <u64>] \
    [--expect-cpu-publish-warning <true|false>] \
    [--expect-cpu-publish-success <true|false>] \
    [--expect-software-route-backend <opengl|metal>] \
    [--app-runtime <runtime>] \
    [--system <deps-path>] \
    [--expected-host-os <linux|macos>] \
    [--mismatch-policy <skip|fail>] \
    [--mode <build|test>]

Examples:
  .github/scripts/software-renderer-compat-check.sh \
    --target x86_64-linux.5.0.0 \
    --app-runtime none

  .github/scripts/software-renderer-compat-check.sh \
    --transport native \
    --target x86_64-macos.10.15.0 \
    --allow-legacy-os true \
    --system /path/to/deps

Notes:
  --allow-legacy-os=true is intended for legacy-target compatibility checks,
  e.g. macOS 10.15 / Linux 4.19 scenarios.
  --target accepts shorthand (e.g. x86_64-macos.11, x86_64-linux.5.0) and is
  auto-normalized to <major>.<minor>.<patch> for Zig.
  cpu-shader-mode=safe/full currently falls back to platform route while custom
  shaders are active unless CPU custom-shader execution capability is available.
  vulkan_swiftshader loader hint precedence:
  VK_DRIVER_FILES > VK_ICD_FILENAMES > VK_ADD_DRIVER_FILES.
  In safe mode, timeout must be > 0.
EOF
}

option_requires_value() {
  case "$1" in
    --mode|--transport|--test-filter|--target|--allow-legacy-os|--cpu-shader-mode|--cpu-shader-backend|--cpu-shader-timeout-ms|--cpu-shader-reprobe-interval-frames|--cpu-shader-enable-minimal-runtime|--inject-fake-swiftshader-hint|--cpu-frame-damage-mode|--cpu-damage-rect-cap|--cpu-publish-warning-threshold-ms|--cpu-publish-warning-consecutive-limit|--expect-cpu-effective|--expect-cpu-shader-mode|--expect-cpu-shader-backend|--expect-cpu-shader-timeout-ms|--expect-cpu-shader-reprobe-interval-frames|--expect-cpu-shader-enable-minimal-runtime|--expect-cpu-shader-capability-status|--expect-cpu-shader-capability-reason|--expect-cpu-shader-capability-hint-source|--expect-cpu-shader-capability-hint-readable|--expect-cpu-frame-damage-mode|--expect-cpu-damage-rect-cap|--expect-cpu-publish-warning-threshold-ms|--expect-cpu-publish-warning-consecutive-limit|--expect-cpu-publish-retry-reason|--expect-cpu-damage-overflow|--expect-cpu-publish-warning|--expect-cpu-publish-success|--expect-software-route-backend|--app-runtime|--system|--expected-host-os|--mismatch-policy)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_option_value() {
  local option="$1"
  local argc="$2"
  local next_value="${3-}"

  if (( argc < 2 )) || [[ "$next_value" == --* ]]; then
    echo "invalid $option: missing value" >&2
    usage >&2
    exit 2
  fi
}

normalize_target_for_zig() {
  local raw_target="$1"

  if [[ "$raw_target" =~ ^(.+-)(macos|linux)\.([0-9]+)(\.([0-9]+))?(\.([0-9]+))?([+-].*)?$ ]]; then
    local prefix="${BASH_REMATCH[1]}"
    local os="${BASH_REMATCH[2]}"
    local major="${BASH_REMATCH[3]}"
    local minor="${BASH_REMATCH[5]:-0}"
    local patch="${BASH_REMATCH[7]:-0}"
    local suffix="${BASH_REMATCH[8]:-}"

    printf '%s%s.%s.%s.%s%s' "$prefix" "$os" "$major" "$minor" "$patch" "$suffix"
    return
  fi

  printf '%s' "$raw_target"
}

target_version_tuple() {
  local target_value="$1"

  if [[ "$target_value" =~ ^.+-(linux|macos)\.([0-9]+)\.([0-9]+)\.([0-9]+)([+-].*)?$ ]]; then
    printf '%s %s %s %s\n' \
      "${BASH_REMATCH[1]}" \
      "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}"
    return 0
  fi

  return 1
}

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

target_meets_cpu_min_version() {
  local os="$1"
  local major="$2"
  local minor="$3"

  case "$os" in
    linux)
      (( major > 5 || (major == 5 && minor >= 0) ))
      ;;
    macos)
      (( major > 11 || (major == 11 && minor >= 0) ))
      ;;
    *)
      return 1
      ;;
  esac
}

cpu_min_version_for_os() {
  local os="$1"

  case "$os" in
    linux) printf '5.0.0' ;;
    macos) printf '11.0.0' ;;
    *) printf 'n/a' ;;
  esac
}

report_failure() {
  local failure_class="$1"
  local hint="$2"
  shift 2

  echo "[software-compat] failure-class=$failure_class"
  echo "[software-compat] hint: $hint"
  for detail in "$@"; do
    echo "[software-compat] $detail"
  done
  exit 1
}

print_cmd() {
  local arg

  printf "[software-compat] cmd:"
  for arg in "$@"; do
    printf " %q" "$arg"
  done
  printf "\n"
}

extract_log_kv_field() {
  local line="$1"
  local key="$2"
  local token

  for token in $line; do
    if [[ "$token" == "$key="* ]]; then
      printf '%s' "${token#*=}"
      return 0
    fi
  done

  return 1
}

mode="test"
transport="auto"
test_filter=""
target=""
allow_legacy_os="false"
cpu_shader_mode=""
cpu_shader_backend=""
cpu_shader_timeout_ms=""
cpu_shader_reprobe_interval_frames=""
cpu_shader_enable_minimal_runtime=""
inject_fake_swiftshader_hint="false"
cpu_frame_damage_mode=""
cpu_damage_rect_cap=""
cpu_publish_warning_threshold_ms=""
cpu_publish_warning_consecutive_limit=""
expect_cpu_effective=""
expect_cpu_shader_mode=""
expect_cpu_shader_backend=""
expect_cpu_shader_timeout_ms=""
expect_cpu_shader_reprobe_interval_frames=""
expect_cpu_shader_enable_minimal_runtime=""
expect_cpu_shader_capability_status=""
expect_cpu_shader_capability_reason=""
expect_cpu_shader_capability_hint_source=""
expect_cpu_shader_capability_hint_readable=""
expect_cpu_frame_damage_mode=""
expect_cpu_damage_rect_cap=""
expect_cpu_publish_warning_threshold_ms=""
expect_cpu_publish_warning_consecutive_limit=""
expect_cpu_publish_retry_reason=""
expect_cpu_damage_overflow=""
expect_cpu_publish_warning=""
expect_cpu_publish_success=""
expect_software_route_backend=""
app_runtime=""
system_path=""
expected_host_os=""
mismatch_policy="skip"

while (($# > 0)); do
  if option_requires_value "$1"; then
    require_option_value "$1" "$#" "${2-}"
  fi

  case "$1" in
    --mode=*)
      mode="${1#*=}"
      shift
      ;;
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    --transport=*)
      transport="${1#*=}"
      shift
      ;;
    --transport)
      transport="${2:-}"
      shift 2
      ;;
    --test-filter=*)
      test_filter="${1#*=}"
      shift
      ;;
    --test-filter)
      test_filter="${2:-}"
      shift 2
      ;;
    --target=*)
      target="${1#*=}"
      shift
      ;;
    --target)
      target="${2:-}"
      shift 2
      ;;
    --allow-legacy-os=*)
      allow_legacy_os="${1#*=}"
      shift
      ;;
    --allow-legacy-os)
      allow_legacy_os="${2:-}"
      shift 2
      ;;
    --cpu-shader-mode=*)
      cpu_shader_mode="${1#*=}"
      shift
      ;;
    --cpu-shader-mode)
      cpu_shader_mode="${2:-}"
      shift 2
      ;;
    --cpu-shader-backend=*)
      cpu_shader_backend="${1#*=}"
      shift
      ;;
    --cpu-shader-backend)
      cpu_shader_backend="${2:-}"
      shift 2
      ;;
    --cpu-shader-timeout-ms=*)
      cpu_shader_timeout_ms="${1#*=}"
      shift
      ;;
    --cpu-shader-timeout-ms)
      cpu_shader_timeout_ms="${2:-}"
      shift 2
      ;;
    --cpu-shader-reprobe-interval-frames=*)
      cpu_shader_reprobe_interval_frames="${1#*=}"
      shift
      ;;
    --cpu-shader-reprobe-interval-frames)
      cpu_shader_reprobe_interval_frames="${2:-}"
      shift 2
      ;;
    --cpu-shader-enable-minimal-runtime=*)
      cpu_shader_enable_minimal_runtime="${1#*=}"
      shift
      ;;
    --cpu-shader-enable-minimal-runtime)
      cpu_shader_enable_minimal_runtime="${2:-}"
      shift 2
      ;;
    --inject-fake-swiftshader-hint=*)
      inject_fake_swiftshader_hint="${1#*=}"
      shift
      ;;
    --inject-fake-swiftshader-hint)
      inject_fake_swiftshader_hint="${2:-}"
      shift 2
      ;;
    --cpu-frame-damage-mode=*)
      cpu_frame_damage_mode="${1#*=}"
      shift
      ;;
    --cpu-frame-damage-mode)
      cpu_frame_damage_mode="${2:-}"
      shift 2
      ;;
    --cpu-damage-rect-cap=*)
      cpu_damage_rect_cap="${1#*=}"
      shift
      ;;
    --cpu-damage-rect-cap)
      cpu_damage_rect_cap="${2:-}"
      shift 2
      ;;
    --cpu-publish-warning-threshold-ms=*)
      cpu_publish_warning_threshold_ms="${1#*=}"
      shift
      ;;
    --cpu-publish-warning-threshold-ms)
      cpu_publish_warning_threshold_ms="${2:-}"
      shift 2
      ;;
    --cpu-publish-warning-consecutive-limit=*)
      cpu_publish_warning_consecutive_limit="${1#*=}"
      shift
      ;;
    --cpu-publish-warning-consecutive-limit)
      cpu_publish_warning_consecutive_limit="${2:-}"
      shift 2
      ;;
    --expect-cpu-effective=*)
      expect_cpu_effective="${1#*=}"
      shift
      ;;
    --expect-cpu-effective)
      expect_cpu_effective="${2:-}"
      shift 2
      ;;
    --expect-cpu-shader-mode=*)
      expect_cpu_shader_mode="${1#*=}"
      shift
      ;;
    --expect-cpu-shader-mode)
      expect_cpu_shader_mode="${2:-}"
      shift 2
      ;;
    --expect-cpu-shader-backend=*)
      expect_cpu_shader_backend="${1#*=}"
      shift
      ;;
    --expect-cpu-shader-backend)
      expect_cpu_shader_backend="${2:-}"
      shift 2
      ;;
    --expect-cpu-shader-timeout-ms=*)
      expect_cpu_shader_timeout_ms="${1#*=}"
      shift
      ;;
    --expect-cpu-shader-timeout-ms)
      expect_cpu_shader_timeout_ms="${2:-}"
      shift 2
      ;;
    --expect-cpu-shader-reprobe-interval-frames=*)
      expect_cpu_shader_reprobe_interval_frames="${1#*=}"
      shift
      ;;
    --expect-cpu-shader-reprobe-interval-frames)
      expect_cpu_shader_reprobe_interval_frames="${2:-}"
      shift 2
      ;;
    --expect-cpu-shader-enable-minimal-runtime=*)
      expect_cpu_shader_enable_minimal_runtime="${1#*=}"
      shift
      ;;
    --expect-cpu-shader-enable-minimal-runtime)
      expect_cpu_shader_enable_minimal_runtime="${2:-}"
      shift 2
      ;;
    --expect-cpu-shader-capability-status=*)
      expect_cpu_shader_capability_status="${1#*=}"
      shift
      ;;
    --expect-cpu-shader-capability-status)
      expect_cpu_shader_capability_status="${2:-}"
      shift 2
      ;;
    --expect-cpu-shader-capability-reason=*)
      expect_cpu_shader_capability_reason="${1#*=}"
      shift
      ;;
    --expect-cpu-shader-capability-reason)
      expect_cpu_shader_capability_reason="${2:-}"
      shift 2
      ;;
    --expect-cpu-shader-capability-hint-source=*)
      expect_cpu_shader_capability_hint_source="${1#*=}"
      shift
      ;;
    --expect-cpu-shader-capability-hint-source)
      expect_cpu_shader_capability_hint_source="${2:-}"
      shift 2
      ;;
    --expect-cpu-shader-capability-hint-readable=*)
      expect_cpu_shader_capability_hint_readable="${1#*=}"
      shift
      ;;
    --expect-cpu-shader-capability-hint-readable)
      expect_cpu_shader_capability_hint_readable="${2:-}"
      shift 2
      ;;
    --expect-cpu-frame-damage-mode=*)
      expect_cpu_frame_damage_mode="${1#*=}"
      shift
      ;;
    --expect-cpu-frame-damage-mode)
      expect_cpu_frame_damage_mode="${2:-}"
      shift 2
      ;;
    --expect-cpu-damage-rect-cap=*)
      expect_cpu_damage_rect_cap="${1#*=}"
      shift
      ;;
    --expect-cpu-damage-rect-cap)
      expect_cpu_damage_rect_cap="${2:-}"
      shift 2
      ;;
    --expect-cpu-publish-warning-threshold-ms=*)
      expect_cpu_publish_warning_threshold_ms="${1#*=}"
      shift
      ;;
    --expect-cpu-publish-warning-threshold-ms)
      expect_cpu_publish_warning_threshold_ms="${2:-}"
      shift 2
      ;;
    --expect-cpu-publish-warning-consecutive-limit=*)
      expect_cpu_publish_warning_consecutive_limit="${1#*=}"
      shift
      ;;
    --expect-cpu-publish-warning-consecutive-limit)
      expect_cpu_publish_warning_consecutive_limit="${2:-}"
      shift 2
      ;;
    --expect-cpu-publish-retry-reason=*)
      expect_cpu_publish_retry_reason="${1#*=}"
      shift
      ;;
    --expect-cpu-publish-retry-reason)
      expect_cpu_publish_retry_reason="${2:-}"
      shift 2
      ;;
    --expect-cpu-damage-overflow=*)
      expect_cpu_damage_overflow="${1#*=}"
      shift
      ;;
    --expect-cpu-damage-overflow)
      expect_cpu_damage_overflow="${2:-}"
      shift 2
      ;;
    --expect-cpu-publish-warning=*)
      expect_cpu_publish_warning="${1#*=}"
      shift
      ;;
    --expect-cpu-publish-warning)
      expect_cpu_publish_warning="${2:-}"
      shift 2
      ;;
    --expect-cpu-publish-success=*)
      expect_cpu_publish_success="${1#*=}"
      shift
      ;;
    --expect-cpu-publish-success)
      expect_cpu_publish_success="${2:-}"
      shift 2
      ;;
    --expect-software-route-backend=*)
      expect_software_route_backend="${1#*=}"
      shift
      ;;
    --expect-software-route-backend)
      expect_software_route_backend="${2:-}"
      shift 2
      ;;
    --app-runtime=*)
      app_runtime="${1#*=}"
      shift
      ;;
    --app-runtime)
      app_runtime="${2:-}"
      shift 2
      ;;
    --system=*)
      system_path="${1#*=}"
      shift
      ;;
    --system)
      system_path="${2:-}"
      shift 2
      ;;
    --expected-host-os=*)
      expected_host_os="${1#*=}"
      shift
      ;;
    --expected-host-os)
      expected_host_os="${2:-}"
      shift 2
      ;;
    --mismatch-policy=*)
      mismatch_policy="${1#*=}"
      shift
      ;;
    --mismatch-policy)
      mismatch_policy="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$transport" != "auto" && "$transport" != "shared" && "$transport" != "native" ]]; then
  echo "invalid --transport: $transport" >&2
  exit 2
fi

if [[ "$allow_legacy_os" != "true" && "$allow_legacy_os" != "false" ]]; then
  echo "invalid --allow-legacy-os: $allow_legacy_os" >&2
  exit 2
fi

if [[ -n "$cpu_shader_mode" && "$cpu_shader_mode" != "off" && "$cpu_shader_mode" != "safe" && "$cpu_shader_mode" != "full" ]]; then
  echo "invalid --cpu-shader-mode: $cpu_shader_mode (expected: off|safe|full)" >&2
  exit 2
fi
if [[ -n "$cpu_shader_backend" && "$cpu_shader_backend" != "off" && "$cpu_shader_backend" != "vulkan_swiftshader" ]]; then
  echo "invalid --cpu-shader-backend: $cpu_shader_backend (expected: off|vulkan_swiftshader)" >&2
  exit 2
fi

if [[ -n "$cpu_shader_timeout_ms" ]]; then
  if ! [[ "$cpu_shader_timeout_ms" =~ ^[0-9]+$ ]]; then
    echo "invalid --cpu-shader-timeout-ms: $cpu_shader_timeout_ms (expected: u32)" >&2
    exit 2
  fi
  if (( ${#cpu_shader_timeout_ms} > 10 )) || {
    (( ${#cpu_shader_timeout_ms} == 10 )) && (( 10#$cpu_shader_timeout_ms > 4294967295 ))
  }; then
    echo "invalid --cpu-shader-timeout-ms: $cpu_shader_timeout_ms (expected: 0..4294967295)" >&2
    exit 2
  fi
fi

if [[ -n "$cpu_shader_reprobe_interval_frames" ]]; then
  if ! [[ "$cpu_shader_reprobe_interval_frames" =~ ^[0-9]+$ ]]; then
    echo "invalid --cpu-shader-reprobe-interval-frames: $cpu_shader_reprobe_interval_frames (expected: u16)" >&2
    exit 2
  fi
  if (( ${#cpu_shader_reprobe_interval_frames} > 5 )) || {
    (( ${#cpu_shader_reprobe_interval_frames} == 5 )) && (( 10#$cpu_shader_reprobe_interval_frames > 65535 ))
  }; then
    echo "invalid --cpu-shader-reprobe-interval-frames: $cpu_shader_reprobe_interval_frames (expected: 0..65535)" >&2
    exit 2
  fi
fi

if [[ -n "$cpu_shader_enable_minimal_runtime" && "$cpu_shader_enable_minimal_runtime" != "true" && "$cpu_shader_enable_minimal_runtime" != "false" ]]; then
  echo "invalid --cpu-shader-enable-minimal-runtime: $cpu_shader_enable_minimal_runtime" >&2
  exit 2
fi

if [[ "$inject_fake_swiftshader_hint" != "true" && "$inject_fake_swiftshader_hint" != "false" ]]; then
  echo "invalid --inject-fake-swiftshader-hint: $inject_fake_swiftshader_hint" >&2
  exit 2
fi

if [[ -n "$cpu_frame_damage_mode" && "$cpu_frame_damage_mode" != "off" && "$cpu_frame_damage_mode" != "rects" ]]; then
  echo "invalid --cpu-frame-damage-mode: $cpu_frame_damage_mode (expected: off|rects)" >&2
  exit 2
fi

if [[ -n "$cpu_damage_rect_cap" ]]; then
  if ! [[ "$cpu_damage_rect_cap" =~ ^[0-9]+$ ]]; then
    echo "invalid --cpu-damage-rect-cap: $cpu_damage_rect_cap (expected: u16)" >&2
    exit 2
  fi
  if (( ${#cpu_damage_rect_cap} > 5 )) || {
    (( ${#cpu_damage_rect_cap} == 5 )) && (( 10#$cpu_damage_rect_cap > 65535 ))
  }; then
    echo "invalid --cpu-damage-rect-cap: $cpu_damage_rect_cap (expected: 0..65535)" >&2
    exit 2
  fi
fi

if [[ -n "$cpu_publish_warning_threshold_ms" ]]; then
  if ! [[ "$cpu_publish_warning_threshold_ms" =~ ^[0-9]+$ ]]; then
    echo "invalid --cpu-publish-warning-threshold-ms: $cpu_publish_warning_threshold_ms (expected: u32)" >&2
    exit 2
  fi
  if (( ${#cpu_publish_warning_threshold_ms} > 10 )) || {
    (( ${#cpu_publish_warning_threshold_ms} == 10 )) && (( 10#$cpu_publish_warning_threshold_ms > 4294967295 ))
  }; then
    echo "invalid --cpu-publish-warning-threshold-ms: $cpu_publish_warning_threshold_ms (expected: 0..4294967295)" >&2
    exit 2
  fi
fi

if [[ -n "$cpu_publish_warning_consecutive_limit" ]]; then
  if ! [[ "$cpu_publish_warning_consecutive_limit" =~ ^[0-9]+$ ]]; then
    echo "invalid --cpu-publish-warning-consecutive-limit: $cpu_publish_warning_consecutive_limit (expected: u8)" >&2
    exit 2
  fi
  if (( ${#cpu_publish_warning_consecutive_limit} > 3 )) || {
    (( ${#cpu_publish_warning_consecutive_limit} == 3 )) && (( 10#$cpu_publish_warning_consecutive_limit > 255 ))
  }; then
    echo "invalid --cpu-publish-warning-consecutive-limit: $cpu_publish_warning_consecutive_limit (expected: 0..255)" >&2
    exit 2
  fi
fi

if [[ -n "$expect_cpu_effective" && "$expect_cpu_effective" != "true" && "$expect_cpu_effective" != "false" ]]; then
  echo "invalid --expect-cpu-effective: $expect_cpu_effective" >&2
  exit 2
fi

if [[ -n "$expect_cpu_shader_mode" && "$expect_cpu_shader_mode" != "off" && "$expect_cpu_shader_mode" != "safe" && "$expect_cpu_shader_mode" != "full" ]]; then
  echo "invalid --expect-cpu-shader-mode: $expect_cpu_shader_mode (expected: off|safe|full)" >&2
  exit 2
fi
if [[ -n "$expect_cpu_shader_backend" && "$expect_cpu_shader_backend" != "off" && "$expect_cpu_shader_backend" != "vulkan_swiftshader" ]]; then
  echo "invalid --expect-cpu-shader-backend: $expect_cpu_shader_backend (expected: off|vulkan_swiftshader)" >&2
  exit 2
fi

if [[ -n "$expect_cpu_shader_timeout_ms" ]]; then
  if ! [[ "$expect_cpu_shader_timeout_ms" =~ ^[0-9]+$ ]]; then
    echo "invalid --expect-cpu-shader-timeout-ms: $expect_cpu_shader_timeout_ms (expected: u32)" >&2
    exit 2
  fi
  if (( ${#expect_cpu_shader_timeout_ms} > 10 )) || {
    (( ${#expect_cpu_shader_timeout_ms} == 10 )) && (( 10#$expect_cpu_shader_timeout_ms > 4294967295 ))
  }; then
    echo "invalid --expect-cpu-shader-timeout-ms: $expect_cpu_shader_timeout_ms (expected: 0..4294967295)" >&2
    exit 2
  fi
fi

if [[ -n "$expect_cpu_shader_reprobe_interval_frames" ]]; then
  if ! [[ "$expect_cpu_shader_reprobe_interval_frames" =~ ^[0-9]+$ ]]; then
    echo "invalid --expect-cpu-shader-reprobe-interval-frames: $expect_cpu_shader_reprobe_interval_frames (expected: u16)" >&2
    exit 2
  fi
  if (( ${#expect_cpu_shader_reprobe_interval_frames} > 5 )) || {
    (( ${#expect_cpu_shader_reprobe_interval_frames} == 5 )) && (( 10#$expect_cpu_shader_reprobe_interval_frames > 65535 ))
  }; then
    echo "invalid --expect-cpu-shader-reprobe-interval-frames: $expect_cpu_shader_reprobe_interval_frames (expected: 0..65535)" >&2
    exit 2
  fi
fi

if [[ -n "$expect_cpu_shader_enable_minimal_runtime" && "$expect_cpu_shader_enable_minimal_runtime" != "true" && "$expect_cpu_shader_enable_minimal_runtime" != "false" ]]; then
  echo "invalid --expect-cpu-shader-enable-minimal-runtime: $expect_cpu_shader_enable_minimal_runtime" >&2
  exit 2
fi

if [[ -n "$expect_cpu_shader_capability_status" && "$expect_cpu_shader_capability_status" != "available" && "$expect_cpu_shader_capability_status" != "unavailable" ]]; then
  echo "invalid --expect-cpu-shader-capability-status: $expect_cpu_shader_capability_status (expected: available|unavailable)" >&2
  exit 2
fi

if [[ -n "$expect_cpu_shader_capability_reason" && ! "$expect_cpu_shader_capability_reason" =~ ^[a-z_]+$ && "$expect_cpu_shader_capability_reason" != "n/a" ]]; then
  echo "invalid --expect-cpu-shader-capability-reason: $expect_cpu_shader_capability_reason (expected: [a-z_]+|n/a)" >&2
  exit 2
fi

if [[ -n "$expect_cpu_shader_capability_hint_source" && "$expect_cpu_shader_capability_hint_source" != "vk_driver_files" && "$expect_cpu_shader_capability_hint_source" != "vk_icd_filenames" && "$expect_cpu_shader_capability_hint_source" != "vk_add_driver_files" && "$expect_cpu_shader_capability_hint_source" != "none" && "$expect_cpu_shader_capability_hint_source" != "n/a" ]]; then
  echo "invalid --expect-cpu-shader-capability-hint-source: $expect_cpu_shader_capability_hint_source" >&2
  exit 2
fi

if [[ -n "$expect_cpu_shader_capability_hint_readable" && "$expect_cpu_shader_capability_hint_readable" != "true" && "$expect_cpu_shader_capability_hint_readable" != "false" ]]; then
  echo "invalid --expect-cpu-shader-capability-hint-readable: $expect_cpu_shader_capability_hint_readable" >&2
  exit 2
fi

if [[ -n "$expect_cpu_frame_damage_mode" && "$expect_cpu_frame_damage_mode" != "off" && "$expect_cpu_frame_damage_mode" != "rects" ]]; then
  echo "invalid --expect-cpu-frame-damage-mode: $expect_cpu_frame_damage_mode (expected: off|rects)" >&2
  exit 2
fi

if [[ -n "$expect_cpu_damage_rect_cap" ]]; then
  if ! [[ "$expect_cpu_damage_rect_cap" =~ ^[0-9]+$ ]]; then
    echo "invalid --expect-cpu-damage-rect-cap: $expect_cpu_damage_rect_cap (expected: u16)" >&2
    exit 2
  fi
  if (( ${#expect_cpu_damage_rect_cap} > 5 )) || {
    (( ${#expect_cpu_damage_rect_cap} == 5 )) && (( 10#$expect_cpu_damage_rect_cap > 65535 ))
  }; then
    echo "invalid --expect-cpu-damage-rect-cap: $expect_cpu_damage_rect_cap (expected: 0..65535)" >&2
    exit 2
  fi
fi

if [[ -n "$expect_cpu_publish_warning_threshold_ms" ]]; then
  if ! [[ "$expect_cpu_publish_warning_threshold_ms" =~ ^[0-9]+$ ]]; then
    echo "invalid --expect-cpu-publish-warning-threshold-ms: $expect_cpu_publish_warning_threshold_ms (expected: u32)" >&2
    exit 2
  fi
  if (( ${#expect_cpu_publish_warning_threshold_ms} > 10 )) || {
    (( ${#expect_cpu_publish_warning_threshold_ms} == 10 )) && (( 10#$expect_cpu_publish_warning_threshold_ms > 4294967295 ))
  }; then
    echo "invalid --expect-cpu-publish-warning-threshold-ms: $expect_cpu_publish_warning_threshold_ms (expected: 0..4294967295)" >&2
    exit 2
  fi
fi

if [[ -n "$expect_cpu_publish_warning_consecutive_limit" ]]; then
  if ! [[ "$expect_cpu_publish_warning_consecutive_limit" =~ ^[0-9]+$ ]]; then
    echo "invalid --expect-cpu-publish-warning-consecutive-limit: $expect_cpu_publish_warning_consecutive_limit (expected: u8)" >&2
    exit 2
  fi
  if (( ${#expect_cpu_publish_warning_consecutive_limit} > 3 )) || {
    (( ${#expect_cpu_publish_warning_consecutive_limit} == 3 )) && (( 10#$expect_cpu_publish_warning_consecutive_limit > 255 ))
  }; then
    echo "invalid --expect-cpu-publish-warning-consecutive-limit: $expect_cpu_publish_warning_consecutive_limit (expected: 0..255)" >&2
    exit 2
  fi
fi

if [[ -n "$expect_cpu_publish_retry_reason" && "$expect_cpu_publish_retry_reason" != "invalid_surface" && "$expect_cpu_publish_retry_reason" != "pool_retired_pressure" && "$expect_cpu_publish_retry_reason" != "frame_pool_exhausted" && "$expect_cpu_publish_retry_reason" != "mailbox_backpressure" ]]; then
  echo "invalid --expect-cpu-publish-retry-reason: $expect_cpu_publish_retry_reason" >&2
  exit 2
fi

if [[ -n "$expect_cpu_damage_overflow" ]]; then
  if ! [[ "$expect_cpu_damage_overflow" =~ ^[0-9]+$ ]]; then
    echo "invalid --expect-cpu-damage-overflow: $expect_cpu_damage_overflow (expected: u64)" >&2
    exit 2
  fi
  if decimal_exceeds_u64 "$expect_cpu_damage_overflow"; then
    echo "invalid --expect-cpu-damage-overflow: $expect_cpu_damage_overflow (expected: 0..18446744073709551615)" >&2
    exit 2
  fi
fi

if [[ -n "$expect_cpu_publish_warning" && "$expect_cpu_publish_warning" != "true" && "$expect_cpu_publish_warning" != "false" ]]; then
  echo "invalid --expect-cpu-publish-warning: $expect_cpu_publish_warning (expected: true|false)" >&2
  exit 2
fi

if [[ -n "$expect_cpu_publish_success" && "$expect_cpu_publish_success" != "true" && "$expect_cpu_publish_success" != "false" ]]; then
  echo "invalid --expect-cpu-publish-success: $expect_cpu_publish_success (expected: true|false)" >&2
  exit 2
fi

if [[ -n "$expect_software_route_backend" && "$expect_software_route_backend" != "opengl" && "$expect_software_route_backend" != "metal" ]]; then
  echo "invalid --expect-software-route-backend: $expect_software_route_backend (expected: opengl|metal)" >&2
  exit 2
fi

if [[ "$mode" != "build" && "$mode" != "test" ]]; then
  echo "invalid --mode: $mode" >&2
  exit 2
fi
if [[ -n "$test_filter" && "$mode" != "test" ]]; then
  echo "invalid --test-filter: only supported with --mode test" >&2
  exit 2
fi

if [[ "$mismatch_policy" != "skip" && "$mismatch_policy" != "fail" ]]; then
  echo "invalid --mismatch-policy: $mismatch_policy" >&2
  exit 2
fi

if [[ -n "$expected_host_os" && "$expected_host_os" != "linux" && "$expected_host_os" != "macos" ]]; then
  echo "invalid --expected-host-os: $expected_host_os" >&2
  exit 2
fi

if [[ "$mismatch_policy" == "skip" ]] && [[ -n "$expect_cpu_effective" || -n "$expect_cpu_shader_mode" || -n "$expect_cpu_shader_backend" || -n "$expect_cpu_shader_timeout_ms" || -n "$expect_cpu_shader_reprobe_interval_frames" || -n "$expect_cpu_shader_enable_minimal_runtime" || -n "$expect_cpu_shader_capability_status" || -n "$expect_cpu_shader_capability_reason" || -n "$expect_cpu_shader_capability_hint_source" || -n "$expect_cpu_shader_capability_hint_readable" || -n "$expect_cpu_frame_damage_mode" || -n "$expect_cpu_damage_rect_cap" || -n "$expect_cpu_publish_warning_threshold_ms" || -n "$expect_cpu_publish_warning_consecutive_limit" || -n "$expect_cpu_publish_retry_reason" || -n "$expect_cpu_damage_overflow" || -n "$expect_cpu_publish_warning" || -n "$expect_cpu_publish_success" || -n "$expect_software_route_backend" ]]; then
  echo "[software-compat] warning: mismatch-policy=skip with --expect-* may bypass assertions on host/target mismatch."
fi

host_os="unknown"
case "$(uname -s)" in
  Linux) host_os="linux" ;;
  Darwin) host_os="macos" ;;
esac

if [[ -n "$expected_host_os" && "$host_os" != "$expected_host_os" ]]; then
  echo "[software-compat] host=$host_os expected-host=$expected_host_os mismatch."
  exit 1
fi

if [[ -n "$target" ]]; then
  # Keep backwards compatibility for historical CI invocations that pass
  # shorthand OS versions (for example: macos.11 or linux.5.0).
  normalized_target="$(normalize_target_for_zig "$target")"
  if [[ "$normalized_target" != "$target" ]]; then
    echo "[software-compat] normalized-target: $target -> $normalized_target"
    target="$normalized_target"
  fi
fi

target_os=""
if [[ -n "$target" ]]; then
  case "$target" in
    *-linux*) target_os="linux" ;;
    *-macos*) target_os="macos" ;;
    *-ios*) target_os="ios" ;;
  esac
fi

target_cpu_gate_expectation=""
if [[ -n "$target" ]]; then
  if tuple="$(target_version_tuple "$target")"; then
    read -r target_version_os target_version_major target_version_minor target_version_patch <<< "$tuple"
    min_version="$(cpu_min_version_for_os "$target_version_os")"
    target_supported="false"
    if target_meets_cpu_min_version "$target_version_os" "$target_version_major" "$target_version_minor"; then
      target_supported="true"
    fi
    if [[ "$target_supported" == "true" || "$allow_legacy_os" == "true" ]]; then
      target_cpu_gate_expectation="true"
    else
      target_cpu_gate_expectation="false"
    fi

    echo "[software-compat] cpu-route-target-gate os=$target_version_os version=$target_version_major.$target_version_minor.$target_version_patch min-required=$min_version allow-legacy-os=$allow_legacy_os expected-build-cpu-effective=$target_cpu_gate_expectation"
    if [[ "$target_supported" == "false" ]]; then
      if [[ "$allow_legacy_os" == "true" ]]; then
        echo "[software-compat] note: legacy target override enabled; this bypasses OS-version gate only."
      else
        echo "[software-compat] note: target is below CPU-route minimum and legacy override is disabled, so build cpu-effective is expected to be false."
      fi
    fi
    if [[ -n "$expect_cpu_effective" && "$expect_cpu_effective" != "$target_cpu_gate_expectation" ]]; then
      echo "[software-compat] note: expect-cpu-effective=$expect_cpu_effective differs from target gate expectation=$target_cpu_gate_expectation; verify matrix intent."
    fi
  else
    echo "[software-compat] note: unable to parse target version tuple for cpu-route gate: $target"
  fi
fi

if [[ -z "$expect_software_route_backend" ]]; then
  route_os="$target_os"
  if [[ -z "$route_os" ]]; then
    if [[ -n "$expected_host_os" ]]; then
      route_os="$expected_host_os"
    else
      route_os="$host_os"
    fi
  fi

  case "$route_os" in
    macos|ios)
      expect_software_route_backend="metal"
      ;;
    linux)
      expect_software_route_backend="opengl"
      ;;
  esac
fi

# Local planning/validation should not be blocked by cross-host old-target checks.
# CI should run these checks on matching runners.
if [[ -n "$target_os" && "$host_os" != "$target_os" ]]; then
  echo "[software-compat] host=$host_os target=$target_os ($target) mismatch; skip on this host."
  echo "[software-compat] run this target on matching CI runner for authoritative validation."
  if [[ "$mismatch_policy" == "fail" ]]; then
    echo "[software-compat] mismatch-policy=fail; exiting with failure"
    exit 1
  fi
  exit 0
fi

if [[ "$mismatch_policy" == "fail" && -z "$target_os" && -z "$expected_host_os" ]]; then
  echo "[software-compat] mismatch-policy=fail requires --target with known OS or --expected-host-os"
  exit 2
fi

cmd=(zig build)
if [[ "$mode" == "test" ]]; then
  cmd+=(test)
fi
if [[ -n "$test_filter" ]]; then
  cmd+=("-Dtest-filter=$test_filter")
fi
cmd+=(-Drenderer=software)
cmd+=(-Dsoftware-renderer-cpu-mvp=true)
cmd+=("-Dsoftware-renderer-cpu-allow-legacy-os=$allow_legacy_os")
if [[ -n "$cpu_shader_mode" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-shader-mode=$cpu_shader_mode")
fi
if [[ -n "$cpu_shader_backend" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-shader-backend=$cpu_shader_backend")
fi
if [[ -n "$cpu_shader_timeout_ms" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-shader-timeout-ms=$cpu_shader_timeout_ms")
fi
if [[ -n "$cpu_shader_reprobe_interval_frames" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-shader-reprobe-interval-frames=$cpu_shader_reprobe_interval_frames")
fi
if [[ -n "$cpu_shader_enable_minimal_runtime" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-shader-enable-minimal-runtime=$cpu_shader_enable_minimal_runtime")
fi
if [[ -n "$cpu_frame_damage_mode" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-frame-damage-mode=$cpu_frame_damage_mode")
fi
if [[ -n "$cpu_damage_rect_cap" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-damage-rect-cap=$cpu_damage_rect_cap")
fi
if [[ -n "$cpu_publish_warning_threshold_ms" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-publish-warning-threshold-ms=$cpu_publish_warning_threshold_ms")
fi
if [[ -n "$cpu_publish_warning_consecutive_limit" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-publish-warning-consecutive-limit=$cpu_publish_warning_consecutive_limit")
fi
cmd+=("-Dsoftware-frame-transport-mode=$transport")
cmd+=(-Demit-macos-app=false)

if [[ -n "$app_runtime" ]]; then
  cmd+=("-Dapp-runtime=$app_runtime")
fi

if [[ -n "$target" ]]; then
  cmd+=("-Dtarget=$target")
fi

if [[ -n "$system_path" ]]; then
  cmd+=(--system "$system_path")
fi

cache_dir="$(mktemp -d -t ghostty-software-compat-cache.XXXXXX)"
cmd+=(--cache-dir "$cache_dir")

fake_swiftshader_hint_dir=""
fake_swiftshader_hint_path=""
had_prev_vk_driver_files="false"
prev_vk_driver_files=""
if [[ "${VK_DRIVER_FILES+x}" == "x" ]]; then
  had_prev_vk_driver_files="true"
  prev_vk_driver_files="$VK_DRIVER_FILES"
fi
if [[ "$inject_fake_swiftshader_hint" == "true" ]]; then
  fake_swiftshader_hint_dir="$(mktemp -d -t ghostty-swiftshader-hint.XXXXXX)"
  fake_swiftshader_hint_path="$fake_swiftshader_hint_dir/fake-swiftshader-driver.json"
  fake_swiftshader_library_path="/tmp/libvk_swiftshader.so"
  if [[ "$host_os" == "macos" ]]; then
    fake_swiftshader_library_path="/tmp/libvk_swiftshader.dylib"
  fi
  cat >"$fake_swiftshader_hint_path" <<JSON
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "$fake_swiftshader_library_path",
    "api_version": "1.1.0"
  }
}
JSON
  export VK_DRIVER_FILES="$fake_swiftshader_hint_path"
  echo "[software-compat] inject-fake-swiftshader-hint=true path=$fake_swiftshader_hint_path library=$fake_swiftshader_library_path"
fi

echo "[software-compat] host=$host_os mode=$mode transport=$transport test-filter=${test_filter:-<unset>} allow-legacy-os=$allow_legacy_os cpu-shader-mode=${cpu_shader_mode:-default} cpu-shader-backend=${cpu_shader_backend:-default} cpu-shader-timeout-ms=${cpu_shader_timeout_ms:-default} cpu-shader-reprobe-interval-frames=${cpu_shader_reprobe_interval_frames:-default} cpu-shader-enable-minimal-runtime=${cpu_shader_enable_minimal_runtime:-default} cpu-frame-damage-mode=${cpu_frame_damage_mode:-default} cpu-damage-rect-cap=${cpu_damage_rect_cap:-default} cpu-publish-warning-threshold-ms=${cpu_publish_warning_threshold_ms:-default} cpu-publish-warning-consecutive-limit=${cpu_publish_warning_consecutive_limit:-default} target=${target:-default} system-path=${system_path:-<unset>}"
resolved_cpu_shader_mode="${cpu_shader_mode:-full}"
resolved_cpu_shader_backend="${cpu_shader_backend:-vulkan_swiftshader}"
resolved_cpu_shader_timeout_ms="${cpu_shader_timeout_ms:-16}"
resolved_cpu_shader_reprobe_interval_frames="${cpu_shader_reprobe_interval_frames:-120}"
resolved_cpu_shader_enable_minimal_runtime="${cpu_shader_enable_minimal_runtime:-false}"
echo "[software-compat] resolved-cpu-shader-config mode=$resolved_cpu_shader_mode backend=$resolved_cpu_shader_backend timeout-ms=$resolved_cpu_shader_timeout_ms reprobe-interval-frames=$resolved_cpu_shader_reprobe_interval_frames enable-minimal-runtime=$resolved_cpu_shader_enable_minimal_runtime"
if [[ "$resolved_cpu_shader_mode" == "off" ]]; then
  echo "[software-compat] note: cpu-shader-mode=off always falls back to platform route while custom shaders are active."
elif [[ "$resolved_cpu_shader_mode" == "safe" && "$resolved_cpu_shader_timeout_ms" == "0" ]]; then
  echo "[software-compat] note: cpu-shader-mode=safe with timeout 0 forces platform-route fallback."
elif [[ "$resolved_cpu_shader_backend" == "off" ]]; then
  echo "[software-compat] note: cpu-shader-backend=off disables CPU custom-shader capability; safe/full will fallback while shaders are active."
fi
if [[ "$resolved_cpu_shader_mode" == "full" || "$resolved_cpu_shader_mode" == "safe" ]]; then
  echo "[software-compat] note: cpu-shader-mode=safe/full may fallback to platform route while custom shaders are active when CPU custom-shader execution capability is unavailable."
fi
if [[ "$resolved_cpu_shader_backend" == "vulkan_swiftshader" && "$resolved_cpu_shader_mode" != "off" ]]; then
  echo "[software-compat] note: inspect runtime shader_capability_reason/hint_source/hint_path/hint_readable logs when diagnosing custom-shader CPU-route fallback."
fi
if [[ -n "$expect_software_route_backend" ]]; then
  echo "[software-compat] expect-software-route-backend=$expect_software_route_backend"
fi
echo "[software-compat] phase=build-command"
print_cmd "${cmd[@]}"

log_file="$(mktemp -t ghostty-software-compat.XXXXXX.log)"
trap 'rm -f "$log_file"; rm -rf "$cache_dir"; if [[ -n "$fake_swiftshader_hint_dir" ]]; then rm -rf "$fake_swiftshader_hint_dir"; fi; if [[ "$had_prev_vk_driver_files" == "true" ]]; then export VK_DRIVER_FILES="$prev_vk_driver_files"; else unset VK_DRIVER_FILES; fi' EXIT

if "${cmd[@]}" 2>&1 | tee "$log_file"; then
  echo "[software-compat] phase=options-snapshot"
  if [[ -n "$expect_cpu_effective" || -n "$expect_cpu_shader_mode" || -n "$expect_cpu_shader_backend" || -n "$expect_cpu_shader_timeout_ms" || -n "$expect_cpu_shader_reprobe_interval_frames" || -n "$expect_cpu_shader_enable_minimal_runtime" || -n "$expect_cpu_frame_damage_mode" || -n "$expect_cpu_damage_rect_cap" || -n "$expect_cpu_publish_warning_threshold_ms" || -n "$expect_cpu_publish_warning_consecutive_limit" || -n "$expect_software_route_backend" ]]; then
    options_file=""
    options_candidates=()
    while IFS= read -r candidate; do
      options_candidates+=("$candidate")
      if grep -Eq 'software_renderer_cpu_effective|software_renderer_cpu_shader_mode|software_renderer_cpu_shader_backend|software_renderer_cpu_shader_timeout_ms|software_renderer_cpu_shader_reprobe_interval_frames|software_renderer_cpu_shader_enable_minimal_runtime|software_renderer_cpu_frame_damage_mode|software_renderer_cpu_damage_rect_cap|software_renderer_cpu_publish_warning_threshold_ms|software_renderer_cpu_publish_warning_consecutive_limit|software_renderer_route_backend' "$candidate"; then
        options_file="$candidate"
        break
      fi
    done < <(find "$cache_dir" -type f -name options.zig 2>/dev/null || true)

    if [[ -z "$options_file" ]]; then
      options_candidates_count="${#options_candidates[@]}"
      options_preview="<none>"
      if (( options_candidates_count > 0 )); then
        options_preview="$(printf '%s,' "${options_candidates[@]:0:5}")"
        options_preview="${options_preview%,}"
      fi
      report_failure \
        "environment options-zig-missing" \
        "verify Zig cache layout and build options export symbols" \
        "assertions requested but options.zig with CPU symbols was not found expected-cpu-effective=${expect_cpu_effective:-<unset>} expected-cpu-shader-mode=${expect_cpu_shader_mode:-<unset>} expected-cpu-shader-backend=${expect_cpu_shader_backend:-<unset>} expected-cpu-shader-timeout-ms=${expect_cpu_shader_timeout_ms:-<unset>} expected-cpu-shader-reprobe-interval-frames=${expect_cpu_shader_reprobe_interval_frames:-<unset>} expected-cpu-shader-enable-minimal-runtime=${expect_cpu_shader_enable_minimal_runtime:-<unset>} expected-cpu-frame-damage-mode=${expect_cpu_frame_damage_mode:-<unset>} expected-cpu-damage-rect-cap=${expect_cpu_damage_rect_cap:-<unset>} expected-cpu-publish-warning-threshold-ms=${expect_cpu_publish_warning_threshold_ms:-<unset>} expected-cpu-publish-warning-consecutive-limit=${expect_cpu_publish_warning_consecutive_limit:-<unset>} expected-software-route-backend=${expect_software_route_backend:-<unset>}" \
        "cache-root=$cache_dir options-candidates=$options_candidates_count" \
        "options-candidates-preview=$options_preview"
    fi

    options_cpu_effective="$(sed -nE 's/.*software_renderer_cpu_effective[^=]*=[[:space:]]*(true|false).*/\1/p' "$options_file" | head -n 1)"
    options_cpu_shader_mode="$(sed -nE 's/.*software_renderer_cpu_shader_mode[^=]*=[[:space:]]*\.?([[:alnum:]_]+).*/\1/p' "$options_file" | head -n 1)"
    options_cpu_shader_backend="$(sed -nE 's/.*software_renderer_cpu_shader_backend[^=]*=[[:space:]]*\.?([[:alnum:]_]+).*/\1/p' "$options_file" | head -n 1)"
    options_cpu_shader_timeout_ms="$(sed -nE 's/.*software_renderer_cpu_shader_timeout_ms[^=]*=[[:space:]]*([0-9]+).*/\1/p' "$options_file" | head -n 1)"
    options_cpu_shader_reprobe_interval_frames="$(sed -nE 's/.*software_renderer_cpu_shader_reprobe_interval_frames[^=]*=[[:space:]]*([0-9]+).*/\1/p' "$options_file" | head -n 1)"
    options_cpu_shader_enable_minimal_runtime="$(sed -nE 's/.*software_renderer_cpu_shader_enable_minimal_runtime[^=]*=[[:space:]]*(true|false).*/\1/p' "$options_file" | head -n 1)"
    options_cpu_frame_damage_mode="$(sed -nE 's/.*software_renderer_cpu_frame_damage_mode[^=]*=[[:space:]]*\.?([[:alnum:]_]+).*/\1/p' "$options_file" | head -n 1)"
    options_cpu_damage_rect_cap="$(sed -nE 's/.*software_renderer_cpu_damage_rect_cap[^=]*=[[:space:]]*([0-9]+).*/\1/p' "$options_file" | head -n 1)"
    options_cpu_publish_warning_threshold_ms="$(sed -nE 's/.*software_renderer_cpu_publish_warning_threshold_ms[^=]*=[[:space:]]*([0-9]+).*/\1/p' "$options_file" | head -n 1)"
    options_cpu_publish_warning_consecutive_limit="$(sed -nE 's/.*software_renderer_cpu_publish_warning_consecutive_limit[^=]*=[[:space:]]*([0-9]+).*/\1/p' "$options_file" | head -n 1)"
    options_software_route_backend="$(sed -nE 's/.*software_renderer_route_backend[^=]*=[[:space:]]*\.?([[:alnum:]_]+).*/\1/p' "$options_file" | head -n 1)"

    if [[ -z "$options_cpu_effective" ]]; then options_cpu_effective="unknown"; fi
    if [[ -z "$options_cpu_shader_mode" ]]; then options_cpu_shader_mode="unknown"; fi
    if [[ -z "$options_cpu_shader_backend" ]]; then options_cpu_shader_backend="unknown"; fi
    if [[ -z "$options_cpu_shader_timeout_ms" ]]; then options_cpu_shader_timeout_ms="unknown"; fi
    if [[ -z "$options_cpu_shader_reprobe_interval_frames" ]]; then options_cpu_shader_reprobe_interval_frames="unknown"; fi
    if [[ -z "$options_cpu_shader_enable_minimal_runtime" ]]; then options_cpu_shader_enable_minimal_runtime="unknown"; fi
    if [[ -z "$options_cpu_frame_damage_mode" ]]; then options_cpu_frame_damage_mode="unknown"; fi
    if [[ -z "$options_cpu_damage_rect_cap" ]]; then options_cpu_damage_rect_cap="unknown"; fi
    if [[ -z "$options_cpu_publish_warning_threshold_ms" ]]; then options_cpu_publish_warning_threshold_ms="unknown"; fi
    if [[ -z "$options_cpu_publish_warning_consecutive_limit" ]]; then options_cpu_publish_warning_consecutive_limit="unknown"; fi
    if [[ -z "$options_software_route_backend" ]]; then options_software_route_backend="unknown"; fi

    echo "[software-compat] options-snapshot file=$options_file cpu-effective=$options_cpu_effective cpu-shader-mode=$options_cpu_shader_mode cpu-shader-backend=$options_cpu_shader_backend cpu-shader-timeout-ms=$options_cpu_shader_timeout_ms cpu-shader-reprobe-interval-frames=$options_cpu_shader_reprobe_interval_frames cpu-shader-enable-minimal-runtime=$options_cpu_shader_enable_minimal_runtime cpu-frame-damage-mode=$options_cpu_frame_damage_mode cpu-damage-rect-cap=$options_cpu_damage_rect_cap cpu-publish-warning-threshold-ms=$options_cpu_publish_warning_threshold_ms cpu-publish-warning-consecutive-limit=$options_cpu_publish_warning_consecutive_limit software-route-backend=$options_software_route_backend"

    if [[ -n "$expect_cpu_effective" ]]; then
      if ! grep -Eq "software_renderer_cpu_effective[^=]*=[[:space:]]*$expect_cpu_effective([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-effective mismatch expected=$expect_cpu_effective actual=$options_cpu_effective file=$options_file"
      fi
      echo "[software-compat] cpu-effective assertion matched expected=$expect_cpu_effective"
    fi

    if [[ -n "$expect_cpu_shader_mode" ]]; then
      if ! grep -Eq "software_renderer_cpu_shader_mode[^=]*=[[:space:]]*\\.?$expect_cpu_shader_mode([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-shader-mode mismatch expected=$expect_cpu_shader_mode actual=$options_cpu_shader_mode file=$options_file"
      fi
      echo "[software-compat] cpu-shader-mode assertion matched expected=$expect_cpu_shader_mode"
    fi

    if [[ -n "$expect_cpu_shader_backend" ]]; then
      if ! grep -Eq "software_renderer_cpu_shader_backend[^=]*=[[:space:]]*\\.?$expect_cpu_shader_backend([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-shader-backend mismatch expected=$expect_cpu_shader_backend actual=$options_cpu_shader_backend file=$options_file"
      fi
      echo "[software-compat] cpu-shader-backend assertion matched expected=$expect_cpu_shader_backend"
    fi

    if [[ -n "$expect_cpu_shader_timeout_ms" ]]; then
      if ! grep -Eq "software_renderer_cpu_shader_timeout_ms[^=]*=[[:space:]]*$expect_cpu_shader_timeout_ms([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-shader-timeout-ms mismatch expected=$expect_cpu_shader_timeout_ms actual=$options_cpu_shader_timeout_ms file=$options_file"
      fi
      echo "[software-compat] cpu-shader-timeout-ms assertion matched expected=$expect_cpu_shader_timeout_ms"
    fi

    if [[ -n "$expect_cpu_shader_reprobe_interval_frames" ]]; then
      if ! grep -Eq "software_renderer_cpu_shader_reprobe_interval_frames[^=]*=[[:space:]]*$expect_cpu_shader_reprobe_interval_frames([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-shader-reprobe-interval-frames mismatch expected=$expect_cpu_shader_reprobe_interval_frames actual=$options_cpu_shader_reprobe_interval_frames file=$options_file"
      fi
      echo "[software-compat] cpu-shader-reprobe-interval-frames assertion matched expected=$expect_cpu_shader_reprobe_interval_frames"
    fi

    if [[ -n "$expect_cpu_shader_enable_minimal_runtime" ]]; then
      if ! grep -Eq "software_renderer_cpu_shader_enable_minimal_runtime[^=]*=[[:space:]]*$expect_cpu_shader_enable_minimal_runtime([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-shader-enable-minimal-runtime mismatch expected=$expect_cpu_shader_enable_minimal_runtime actual=$options_cpu_shader_enable_minimal_runtime file=$options_file"
      fi
      echo "[software-compat] cpu-shader-enable-minimal-runtime assertion matched expected=$expect_cpu_shader_enable_minimal_runtime"
    fi

    if [[ -n "$expect_cpu_frame_damage_mode" ]]; then
      if ! grep -Eq "software_renderer_cpu_frame_damage_mode[^=]*=[[:space:]]*\\.?$expect_cpu_frame_damage_mode([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-frame-damage-mode mismatch expected=$expect_cpu_frame_damage_mode actual=$options_cpu_frame_damage_mode file=$options_file"
      fi
      echo "[software-compat] cpu-frame-damage-mode assertion matched expected=$expect_cpu_frame_damage_mode"
    fi

    if [[ -n "$expect_cpu_damage_rect_cap" ]]; then
      if ! grep -Eq "software_renderer_cpu_damage_rect_cap[^=]*=[[:space:]]*$expect_cpu_damage_rect_cap([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-damage-rect-cap mismatch expected=$expect_cpu_damage_rect_cap actual=$options_cpu_damage_rect_cap file=$options_file"
      fi
      echo "[software-compat] cpu-damage-rect-cap assertion matched expected=$expect_cpu_damage_rect_cap"
    fi

    if [[ -n "$expect_cpu_publish_warning_threshold_ms" ]]; then
      if ! grep -Eq "software_renderer_cpu_publish_warning_threshold_ms[^=]*=[[:space:]]*$expect_cpu_publish_warning_threshold_ms([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-publish-warning-threshold-ms mismatch expected=$expect_cpu_publish_warning_threshold_ms actual=$options_cpu_publish_warning_threshold_ms file=$options_file"
      fi
      echo "[software-compat] cpu-publish-warning-threshold-ms assertion matched expected=$expect_cpu_publish_warning_threshold_ms"
    fi

    if [[ -n "$expect_cpu_publish_warning_consecutive_limit" ]]; then
      if ! grep -Eq "software_renderer_cpu_publish_warning_consecutive_limit[^=]*=[[:space:]]*$expect_cpu_publish_warning_consecutive_limit([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-publish-warning-consecutive-limit mismatch expected=$expect_cpu_publish_warning_consecutive_limit actual=$options_cpu_publish_warning_consecutive_limit file=$options_file"
      fi
      echo "[software-compat] cpu-publish-warning-consecutive-limit assertion matched expected=$expect_cpu_publish_warning_consecutive_limit"
    fi

    if [[ -n "$expect_software_route_backend" ]]; then
      if ! grep -Eq "software_renderer_route_backend[^=]*=[[:space:]]*\\.?$expect_software_route_backend([[:space:]]|,|;)" "$options_file"; then
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "software-route-backend mismatch expected=$expect_software_route_backend actual=$options_software_route_backend file=$options_file"
      fi
      echo "[software-compat] software-route-backend assertion matched expected=$expect_software_route_backend"
    fi

  fi

  if [[ -n "$expect_cpu_shader_capability_status" || -n "$expect_cpu_shader_capability_reason" || -n "$expect_cpu_shader_capability_hint_source" || -n "$expect_cpu_shader_capability_hint_readable" ]]; then
    echo "[software-compat] phase=capability-assert"
    capability_line="$(grep -E 'software renderer cpu shader capability kv ' "$log_file" | tail -n 1 || true)"
    if [[ -z "$capability_line" ]]; then
      report_failure \
        "assertion runtime-log-missing" \
        "expected structured cpu shader capability kv log line was not found" \
        "expected-status=${expect_cpu_shader_capability_status:-<unset>} expected-reason=${expect_cpu_shader_capability_reason:-<unset>} expected-hint-source=${expect_cpu_shader_capability_hint_source:-<unset>} expected-hint-readable=${expect_cpu_shader_capability_hint_readable:-<unset>}"
    fi

    observed_capability_status="$(extract_log_kv_field "$capability_line" "status" || true)"
    observed_capability_reason="$(extract_log_kv_field "$capability_line" "reason" || true)"
    observed_capability_hint_source="$(extract_log_kv_field "$capability_line" "hint_source" || true)"
    observed_capability_hint_readable="$(extract_log_kv_field "$capability_line" "hint_readable" || true)"
    observed_capability_min_runtime_enabled="$(extract_log_kv_field "$capability_line" "minimal_runtime_enabled" || true)"
    if [[ -z "$observed_capability_status" ]]; then observed_capability_status="unknown"; fi
    if [[ -z "$observed_capability_reason" ]]; then observed_capability_reason="n/a"; fi
    if [[ -z "$observed_capability_hint_source" ]]; then observed_capability_hint_source="unknown"; fi
    if [[ -z "$observed_capability_hint_readable" ]]; then observed_capability_hint_readable="unknown"; fi
    if [[ -z "$observed_capability_min_runtime_enabled" ]]; then observed_capability_min_runtime_enabled="unknown"; fi

    echo "[software-compat] capability-log-snapshot status=$observed_capability_status reason=$observed_capability_reason hint_source=$observed_capability_hint_source hint_readable=$observed_capability_hint_readable minimal_runtime_enabled=$observed_capability_min_runtime_enabled"

    if [[ -n "$expect_cpu_shader_capability_status" && "$observed_capability_status" != "$expect_cpu_shader_capability_status" ]]; then
      report_failure \
        "assertion runtime-log-mismatch" \
        "cpu shader capability status mismatch in runtime logs" \
        "expected=$expect_cpu_shader_capability_status actual=$observed_capability_status line=$capability_line"
    fi
    if [[ -n "$expect_cpu_shader_capability_reason" && "$observed_capability_reason" != "$expect_cpu_shader_capability_reason" ]]; then
      report_failure \
        "assertion runtime-log-mismatch" \
        "cpu shader capability reason mismatch in runtime logs" \
        "expected=$expect_cpu_shader_capability_reason actual=$observed_capability_reason line=$capability_line"
    fi
    if [[ -n "$expect_cpu_shader_capability_hint_source" && "$observed_capability_hint_source" != "$expect_cpu_shader_capability_hint_source" ]]; then
      report_failure \
        "assertion runtime-log-mismatch" \
        "cpu shader capability hint source mismatch in runtime logs" \
        "expected=$expect_cpu_shader_capability_hint_source actual=$observed_capability_hint_source line=$capability_line"
    fi
    if [[ -n "$expect_cpu_shader_capability_hint_readable" && "$observed_capability_hint_readable" != "$expect_cpu_shader_capability_hint_readable" ]]; then
      report_failure \
        "assertion runtime-log-mismatch" \
        "cpu shader capability hint readability mismatch in runtime logs" \
        "expected=$expect_cpu_shader_capability_hint_readable actual=$observed_capability_hint_readable line=$capability_line"
    fi

    echo "[software-compat] cpu-shader-capability assertions matched"
  fi

  if [[ -n "$expect_cpu_damage_overflow" ]]; then
    echo "[software-compat] phase=damage-assert"
    damage_lines="$(grep -E 'software renderer cpu damage kv ' "$log_file" || true)"
    if [[ "$expect_cpu_damage_overflow" == "0" ]]; then
      if [[ -n "$damage_lines" ]]; then
        observed_cpu_damage_overflow="$(printf '%s\n' "$damage_lines" | sed -nE 's/.*overflow_count=([0-9]+).*/\1/p' | tail -n 1)"
        observed_cpu_damage_rect_count="$(printf '%s\n' "$damage_lines" | sed -nE 's/.*rect_count=([0-9]+).*/\1/p' | tail -n 1)"
        if [[ -z "$observed_cpu_damage_overflow" ]]; then observed_cpu_damage_overflow="unknown"; fi
        if [[ -z "$observed_cpu_damage_rect_count" ]]; then observed_cpu_damage_rect_count="unknown"; fi
        echo "[software-compat] damage-log-snapshot rect_count=$observed_cpu_damage_rect_count overflow_count=$observed_cpu_damage_overflow"
        report_failure \
          "assertion runtime-log-mismatch" \
          "cpu damage overflow mismatch in runtime logs" \
          "expected=0 actual=$observed_cpu_damage_overflow"
      fi

      echo "[software-compat] damage-log-snapshot rect_count=0 overflow_count=0"
      echo "[software-compat] cpu-damage-overflow assertion matched"
    elif [[ -z "$damage_lines" ]]; then
      report_failure \
        "assertion runtime-log-missing" \
        "expected structured cpu damage kv log line was not found" \
        "expected-overflow=$expect_cpu_damage_overflow"
    else
      damage_line=""
      observed_cpu_damage_overflow="unknown"
      observed_cpu_damage_rect_count="unknown"
      while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        observed_overflow="$(extract_log_kv_field "$candidate" "overflow_count" || true)"
        observed_rect_count="$(extract_log_kv_field "$candidate" "rect_count" || true)"
        if [[ -n "$observed_overflow" ]]; then
          observed_cpu_damage_overflow="$observed_overflow"
        fi
        if [[ -n "$observed_rect_count" ]]; then
          observed_cpu_damage_rect_count="$observed_rect_count"
        fi
        if [[ "$observed_overflow" == "$expect_cpu_damage_overflow" ]]; then
          damage_line="$candidate"
          break
        fi
      done <<< "$damage_lines"

      echo "[software-compat] damage-log-snapshot rect_count=$observed_cpu_damage_rect_count overflow_count=$observed_cpu_damage_overflow"

      if [[ -z "$damage_line" ]]; then
        report_failure \
          "assertion runtime-log-mismatch" \
          "cpu damage overflow mismatch in runtime logs" \
          "expected=$expect_cpu_damage_overflow actual=$observed_cpu_damage_overflow"
      fi

      echo "[software-compat] cpu-damage-overflow assertion matched"
    fi
  fi

  if [[ -n "$expect_cpu_publish_retry_reason" ]]; then
    echo "[software-compat] phase=publish-retry-assert"
    publish_retry_lines="$(grep -E 'software renderer cpu publish retry kv ' "$log_file" || true)"
    if [[ -z "$publish_retry_lines" ]]; then
      report_failure \
        "assertion runtime-log-missing" \
        "expected structured cpu publish retry kv log line was not found" \
        "expected-reason=$expect_cpu_publish_retry_reason"
    fi

    publish_retry_line=""
    observed_publish_retry_reason="unknown"
    observed_publish_retry_count="unknown"
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      observed_reason="$(extract_log_kv_field "$candidate" "reason" || true)"
      if [[ "$observed_reason" == "$expect_cpu_publish_retry_reason" ]]; then
        publish_retry_line="$candidate"
        observed_publish_retry_reason="$observed_reason"
        observed_publish_retry_count="$(extract_log_kv_field "$candidate" "retry_count" || true)"
        break
      fi
    done <<< "$publish_retry_lines"

    echo "[software-compat] publish-retry-log-snapshot reason=$observed_publish_retry_reason retry_count=$observed_publish_retry_count"

    if [[ -z "$publish_retry_line" ]]; then
      report_failure \
        "assertion runtime-log-mismatch" \
        "cpu publish retry reason mismatch in runtime logs" \
        "expected=$expect_cpu_publish_retry_reason actual=$observed_publish_retry_reason"
    fi

    echo "[software-compat] cpu-publish-retry assertion matched"
  fi

  if [[ -n "$expect_cpu_publish_warning" ]]; then
    echo "[software-compat] phase=publish-warning-assert"
    publish_warning_line="$(grep -E 'software renderer cpu publish warning kv ' "$log_file" | tail -n 1 || true)"
    publish_warning_present="false"
    if [[ -n "$publish_warning_line" ]]; then
      publish_warning_present="true"
    fi

    echo "[software-compat] publish-warning-log-snapshot present=$publish_warning_present"

    if [[ "$expect_cpu_publish_warning" == "true" && "$publish_warning_present" != "true" ]]; then
      report_failure \
        "assertion runtime-log-missing" \
        "expected structured cpu publish warning kv log line was not found" \
        "expected-warning=$expect_cpu_publish_warning"
    fi
    if [[ "$expect_cpu_publish_warning" == "false" && "$publish_warning_present" != "false" ]]; then
      report_failure \
        "assertion runtime-log-mismatch" \
        "cpu publish warning presence mismatch in runtime logs" \
        "expected=$expect_cpu_publish_warning actual=$publish_warning_present line=$publish_warning_line"
    fi

    echo "[software-compat] cpu-publish-warning assertion matched"
  fi

  if [[ -n "$expect_cpu_publish_success" ]]; then
    echo "[software-compat] phase=publish-success-assert"
    publish_success_line="$(grep -E 'software renderer cpu publish success kv ' "$log_file" | tail -n 1 || true)"
    publish_success_present="false"
    publish_success_pending="unknown"
    publish_success_retry_count="unknown"
    publish_success_frame_ms="unknown"
    if [[ -n "$publish_success_line" ]]; then
      publish_success_present="true"
      publish_success_pending="$(extract_log_kv_field "$publish_success_line" "publish_pending" || true)"
      publish_success_retry_count="$(extract_log_kv_field "$publish_success_line" "retry_count" || true)"
      publish_success_frame_ms="$(extract_log_kv_field "$publish_success_line" "last_cpu_frame_ms" || true)"
    fi

    echo "[software-compat] publish-success-log-snapshot present=$publish_success_present publish_pending=$publish_success_pending retry_count=$publish_success_retry_count last_cpu_frame_ms=$publish_success_frame_ms"

    if [[ "$expect_cpu_publish_success" == "true" && "$publish_success_present" != "true" ]]; then
      report_failure \
        "assertion runtime-log-missing" \
        "expected structured cpu publish success kv log line was not found" \
        "expected-success=$expect_cpu_publish_success"
    fi
    if [[ "$expect_cpu_publish_success" == "false" && "$publish_success_present" != "false" ]]; then
      report_failure \
        "assertion runtime-log-mismatch" \
        "cpu publish success presence mismatch in runtime logs" \
        "expected=$expect_cpu_publish_success actual=$publish_success_present line=$publish_success_line"
    fi
    if [[ "$expect_cpu_publish_success" == "true" ]]; then
      if [[ "$publish_success_pending" != "false" ]]; then
        report_failure \
          "assertion runtime-log-mismatch" \
          "cpu publish success pending state mismatch in runtime logs" \
          "expected=false actual=${publish_success_pending:-<unset>} line=$publish_success_line"
      fi
      if [[ -z "$publish_success_frame_ms" || ! "$publish_success_frame_ms" =~ ^[0-9]+$ ]]; then
        report_failure \
          "assertion runtime-log-mismatch" \
          "cpu publish success frame latency missing or invalid in runtime logs" \
          "actual=${publish_success_frame_ms:-<unset>} line=$publish_success_line"
      fi
      if [[ -z "$publish_success_retry_count" || ! "$publish_success_retry_count" =~ ^[0-9]+$ ]]; then
        report_failure \
          "assertion runtime-log-mismatch" \
          "cpu publish success retry count missing or invalid in runtime logs" \
          "actual=${publish_success_retry_count:-<unset>} line=$publish_success_line"
      fi
    fi

    echo "[software-compat] cpu-publish-success assertion matched"
  fi

  echo "[software-compat] phase=success"
  echo "[software-compat] success"
  exit 0
fi

if grep -Eq 'recompile with -fPIC|ld\.lld: relocation' "$log_file"; then
  report_failure \
    "environment toolchain-linker-pic" \
    "verify host/runner and third-party archive PIC compatibility"
fi

if grep -Eq 'xcodebuild.*(CodeSign|codesign)|Library .* not found|Testing cancelled because the build failed' "$log_file"; then
  report_failure \
    "environment xcode-build-chain" \
    "verify Xcode selection and build environment"
fi

report_failure "logic-or-runtime" "inspect logs above for regression details"
