#!/usr/bin/env bash

set -euo pipefail

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
system_path="${SR_CI_SYSTEM_PATH:-}"
dry_run="${SR_CI_DRY_RUN:-false}"

if [[ "$dry_run" != "true" && "$dry_run" != "false" ]]; then
  echo "invalid SR_CI_DRY_RUN: $dry_run (expected: true|false)" >&2
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

allow_legacy_os=false
target_os=""
target_major=""
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
        allow_legacy_os=true
      fi
    else
      echo "Unrecognized linux target format: $target" >&2
      exit 1
    fi
  else
    if [[ "$target" =~ ^[^-]+-macos\.([0-9]+)(\..*)?$ ]]; then
      target_major="${BASH_REMATCH[1]}"
      if (( target_major < 11 )); then
        allow_legacy_os=true
      fi
    else
      echo "Unrecognized macOS target format: $target" >&2
      exit 1
    fi
  fi
fi

if [[ -n "$force_allow_legacy_os" ]]; then
  allow_legacy_os="$force_allow_legacy_os"
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
if [[ -z "$resolved_fake_swiftshader_hint" ]]; then resolved_fake_swiftshader_hint=false; fi
if [[ -z "$resolved_cpu_shader_mode" ]]; then resolved_cpu_shader_mode=full; fi
if [[ -z "$resolved_cpu_shader_backend" ]]; then resolved_cpu_shader_backend=vulkan_swiftshader; fi
if [[ -z "$resolved_cpu_shader_timeout_ms" ]]; then resolved_cpu_shader_timeout_ms=16; fi
if [[ -z "$resolved_cpu_shader_reprobe_interval_frames" ]]; then resolved_cpu_shader_reprobe_interval_frames=120; fi
if [[ -z "$resolved_cpu_shader_enable_minimal_runtime" ]]; then resolved_cpu_shader_enable_minimal_runtime=false; fi
if [[ -z "$expect_cpu_shader_backend" && -n "$cpu_shader_mode" && -z "$cpu_shader_backend" ]]; then
  expect_cpu_shader_backend=vulkan_swiftshader
fi
if [[ -z "$expect_cpu_effective" ]]; then expect_cpu_effective="<unset>"; fi

echo "[software-renderer-ci] $SR_CI_OS target-label=$target_label transport-label=$transport_label target=${target:-default} allow-legacy-os=$allow_legacy_os gate-expected-cpu-effective=$target_gate_expected_cpu_effective matrix-expect-cpu-effective=$expect_cpu_effective app-runtime=$app_runtime"
echo "[software-renderer-ci] $SR_CI_OS resolved-cpu-shader mode=$resolved_cpu_shader_mode backend=$resolved_cpu_shader_backend timeout-ms=$resolved_cpu_shader_timeout_ms reprobe-interval-frames=$resolved_cpu_shader_reprobe_interval_frames enable-minimal-runtime=$resolved_cpu_shader_enable_minimal_runtime fake-swiftshader-hint=$resolved_fake_swiftshader_hint expect-cpu-shader-backend=${expect_cpu_shader_backend:-<unset>}"
if [[ "$allow_legacy_os" == "true" ]]; then
  echo "[software-renderer-ci] $SR_CI_OS note: allow-legacy-os only bypasses build target-version gate; runtime fallback gates still apply."
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
  echo "SR_CI_SYSTEM_PATH is required for macOS software-renderer cpu-path CI" >&2
  exit 1
fi

compat_args=(
  --mode test
  --transport "$SR_CI_TRANSPORT_MODE"
  --allow-legacy-os="$allow_legacy_os"
  --expected-host-os "$SR_CI_OS"
  --mismatch-policy fail
  --expect-software-route-backend "$route_backend"
)
if [[ -n "$cpu_shader_mode" ]]; then
  compat_args+=(--cpu-shader-mode "$cpu_shader_mode")
  compat_args+=(--expect-cpu-shader-mode "$cpu_shader_mode")
fi
if [[ -n "$cpu_shader_backend" ]]; then
  compat_args+=(--cpu-shader-backend "$cpu_shader_backend")
fi
if [[ -n "$expect_cpu_shader_backend" ]]; then
  compat_args+=(--expect-cpu-shader-backend "$expect_cpu_shader_backend")
fi
if [[ -n "$cpu_shader_timeout_ms" ]]; then
  compat_args+=(--cpu-shader-timeout-ms "$cpu_shader_timeout_ms")
  compat_args+=(--expect-cpu-shader-timeout-ms "$cpu_shader_timeout_ms")
fi
if [[ -n "$cpu_shader_reprobe_interval_frames" ]]; then
  compat_args+=(--cpu-shader-reprobe-interval-frames "$cpu_shader_reprobe_interval_frames")
fi
if [[ -n "$cpu_shader_enable_minimal_runtime" ]]; then
  compat_args+=(--cpu-shader-enable-minimal-runtime "$cpu_shader_enable_minimal_runtime")
  compat_args+=(--expect-cpu-shader-enable-minimal-runtime "$cpu_shader_enable_minimal_runtime")
fi
if [[ -n "$inject_fake_swiftshader_hint" ]]; then
  compat_args+=(--inject-fake-swiftshader-hint "$inject_fake_swiftshader_hint")
fi
if [[ -n "$expect_cpu_shader_capability_status" ]]; then
  compat_args+=(--expect-cpu-shader-capability-status "$expect_cpu_shader_capability_status")
fi
if [[ -n "$expect_cpu_shader_capability_reason" ]]; then
  compat_args+=(--expect-cpu-shader-capability-reason "$expect_cpu_shader_capability_reason")
fi
if [[ -n "$expect_cpu_shader_capability_hint_source" ]]; then
  compat_args+=(--expect-cpu-shader-capability-hint-source "$expect_cpu_shader_capability_hint_source")
fi
if [[ -n "$expect_cpu_shader_capability_hint_readable" ]]; then
  compat_args+=(--expect-cpu-shader-capability-hint-readable "$expect_cpu_shader_capability_hint_readable")
fi
if [[ -n "$cpu_frame_damage_mode" ]]; then
  compat_args+=(--cpu-frame-damage-mode "$cpu_frame_damage_mode")
  compat_args+=(--expect-cpu-frame-damage-mode "$cpu_frame_damage_mode")
fi
if [[ -n "$cpu_damage_rect_cap" ]]; then
  compat_args+=(--cpu-damage-rect-cap "$cpu_damage_rect_cap")
  compat_args+=(--expect-cpu-damage-rect-cap "$cpu_damage_rect_cap")
fi
if [[ -n "$cpu_publish_warning_threshold_ms" ]]; then
  compat_args+=(--cpu-publish-warning-threshold-ms "$cpu_publish_warning_threshold_ms")
fi
if [[ -n "$cpu_publish_warning_consecutive_limit" ]]; then
  compat_args+=(--cpu-publish-warning-consecutive-limit "$cpu_publish_warning_consecutive_limit")
fi
if [[ -n "$target" ]]; then
  compat_args+=(--target "$target")
fi
if [[ "$expect_cpu_effective" != "<unset>" ]]; then
  compat_args+=(--expect-cpu-effective "$expect_cpu_effective")
fi
if [[ "$SR_CI_OS" == "linux" ]]; then
  compat_args+=(--app-runtime "$app_runtime")
else
  compat_args+=(--system "$system_path")
fi

if [[ "$dry_run" == "true" ]]; then
  printf "[software-renderer-ci] dry-run compat-check command: %q" "./.github/scripts/software-renderer-compat-check.sh"
  for arg in "${compat_args[@]}"; do
    printf " %q" "$arg"
  done
  printf "\n"
  exit 0
fi

nix develop -c \
  ./.github/scripts/software-renderer-compat-check.sh \
  "${compat_args[@]}"
