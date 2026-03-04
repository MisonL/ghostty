#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  .github/scripts/software-renderer-compat-check.sh \
    [--transport <auto|shared|native>] \
    [--target <zig-target>] \
    [--allow-legacy-os <true|false>] \
    [--cpu-shader-mode <off|safe|full>] \
    [--cpu-shader-timeout-ms <u32>] \
    [--cpu-frame-damage-mode <off|rects>] \
    [--cpu-damage-rect-cap <u16>] \
    [--expect-cpu-effective <true|false>] \
    [--expect-cpu-shader-mode <off|safe|full>] \
    [--expect-cpu-shader-timeout-ms <u32>] \
    [--expect-cpu-frame-damage-mode <off|rects>] \
    [--expect-cpu-damage-rect-cap <u16>] \
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
    --target x86_64-macos.11.0.0 \
    --allow-legacy-os true \
    --system /path/to/deps

Notes:
  --allow-legacy-os=true is intended for legacy-target compatibility checks,
  e.g. macOS 11 / Linux 5.0 scenarios.
  --target accepts shorthand (e.g. x86_64-macos.11, x86_64-linux.5.0) and is
  auto-normalized to <major>.<minor>.<patch> for Zig.
  cpu-shader-mode=safe/full currently falls back to platform route while custom
  shaders are active unless CPU custom-shader execution capability is available.
  In safe mode, timeout must be > 0.
EOF
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

mode="test"
transport="auto"
target=""
allow_legacy_os="false"
cpu_shader_mode=""
cpu_shader_timeout_ms=""
cpu_frame_damage_mode=""
cpu_damage_rect_cap=""
expect_cpu_effective=""
expect_cpu_shader_mode=""
expect_cpu_shader_timeout_ms=""
expect_cpu_frame_damage_mode=""
expect_cpu_damage_rect_cap=""
expect_software_route_backend=""
app_runtime=""
system_path=""
expected_host_os=""
mismatch_policy="skip"

while (($# > 0)); do
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
    --cpu-shader-timeout-ms=*)
      cpu_shader_timeout_ms="${1#*=}"
      shift
      ;;
    --cpu-shader-timeout-ms)
      cpu_shader_timeout_ms="${2:-}"
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
    --expect-cpu-shader-timeout-ms=*)
      expect_cpu_shader_timeout_ms="${1#*=}"
      shift
      ;;
    --expect-cpu-shader-timeout-ms)
      expect_cpu_shader_timeout_ms="${2:-}"
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

if [[ -n "$cpu_shader_timeout_ms" ]]; then
  if ! [[ "$cpu_shader_timeout_ms" =~ ^[0-9]+$ ]]; then
    echo "invalid --cpu-shader-timeout-ms: $cpu_shader_timeout_ms (expected: u32)" >&2
    exit 2
  fi
  if (( ${#cpu_shader_timeout_ms} > 10 )) || {
    (( ${#cpu_shader_timeout_ms} == 10 )) && (( cpu_shader_timeout_ms > 4294967295 ))
  }; then
    echo "invalid --cpu-shader-timeout-ms: $cpu_shader_timeout_ms (expected: 0..4294967295)" >&2
    exit 2
  fi
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
    (( ${#cpu_damage_rect_cap} == 5 )) && (( cpu_damage_rect_cap > 65535 ))
  }; then
    echo "invalid --cpu-damage-rect-cap: $cpu_damage_rect_cap (expected: 0..65535)" >&2
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

if [[ -n "$expect_cpu_shader_timeout_ms" ]]; then
  if ! [[ "$expect_cpu_shader_timeout_ms" =~ ^[0-9]+$ ]]; then
    echo "invalid --expect-cpu-shader-timeout-ms: $expect_cpu_shader_timeout_ms (expected: u32)" >&2
    exit 2
  fi
  if (( ${#expect_cpu_shader_timeout_ms} > 10 )) || {
    (( ${#expect_cpu_shader_timeout_ms} == 10 )) && (( expect_cpu_shader_timeout_ms > 4294967295 ))
  }; then
    echo "invalid --expect-cpu-shader-timeout-ms: $expect_cpu_shader_timeout_ms (expected: 0..4294967295)" >&2
    exit 2
  fi
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
    (( ${#expect_cpu_damage_rect_cap} == 5 )) && (( expect_cpu_damage_rect_cap > 65535 ))
  }; then
    echo "invalid --expect-cpu-damage-rect-cap: $expect_cpu_damage_rect_cap (expected: 0..65535)" >&2
    exit 2
  fi
fi

if [[ -n "$expect_software_route_backend" && "$expect_software_route_backend" != "opengl" && "$expect_software_route_backend" != "metal" ]]; then
  echo "invalid --expect-software-route-backend: $expect_software_route_backend (expected: opengl|metal)" >&2
  exit 2
fi

if [[ "$mode" != "build" && "$mode" != "test" ]]; then
  echo "invalid --mode: $mode" >&2
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
cmd+=(-Drenderer=software)
cmd+=(-Dsoftware-renderer-cpu-mvp=true)
cmd+=("-Dsoftware-renderer-cpu-allow-legacy-os=$allow_legacy_os")
if [[ -n "$cpu_shader_mode" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-shader-mode=$cpu_shader_mode")
fi
if [[ -n "$cpu_shader_timeout_ms" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-shader-timeout-ms=$cpu_shader_timeout_ms")
fi
if [[ -n "$cpu_frame_damage_mode" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-frame-damage-mode=$cpu_frame_damage_mode")
fi
if [[ -n "$cpu_damage_rect_cap" ]]; then
  cmd+=("-Dsoftware-renderer-cpu-damage-rect-cap=$cpu_damage_rect_cap")
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

echo "[software-compat] host=$host_os mode=$mode transport=$transport allow-legacy-os=$allow_legacy_os cpu-shader-mode=${cpu_shader_mode:-default} cpu-shader-timeout-ms=${cpu_shader_timeout_ms:-default} cpu-frame-damage-mode=${cpu_frame_damage_mode:-default} cpu-damage-rect-cap=${cpu_damage_rect_cap:-default} target=${target:-default}"
if [[ "${cpu_shader_mode:-full}" == "full" || "${cpu_shader_mode:-safe}" == "safe" ]]; then
  echo "[software-compat] note: cpu-shader-mode=safe/full currently falls back to platform route while custom shaders are active unless CPU custom-shader execution capability is available."
fi
if [[ "${cpu_shader_mode:-}" == "safe" && -n "${cpu_shader_timeout_ms:-}" && "$cpu_shader_timeout_ms" == "0" ]]; then
  echo "[software-compat] note: cpu-shader-mode=safe with timeout 0 forces platform-route fallback."
fi
if [[ -n "$expect_software_route_backend" ]]; then
  echo "[software-compat] expect-software-route-backend=$expect_software_route_backend"
fi
echo "[software-compat] cmd: ${cmd[*]}"

log_file="$(mktemp -t ghostty-software-compat.XXXXXX.log)"
trap 'rm -f "$log_file"; rm -rf "$cache_dir"' EXIT

if "${cmd[@]}" 2>&1 | tee "$log_file"; then
  if [[ -n "$expect_cpu_effective" || -n "$expect_cpu_shader_mode" || -n "$expect_cpu_shader_timeout_ms" || -n "$expect_cpu_frame_damage_mode" || -n "$expect_cpu_damage_rect_cap" || -n "$expect_software_route_backend" ]]; then
    options_file=""
    options_candidates=()
    while IFS= read -r candidate; do
      options_candidates+=("$candidate")
      if grep -Eq 'software_renderer_cpu_effective|software_renderer_cpu_shader_mode|software_renderer_cpu_shader_timeout_ms|software_renderer_cpu_frame_damage_mode|software_renderer_cpu_damage_rect_cap|software_renderer_route_backend' "$candidate"; then
        options_file="$candidate"
        break
      fi
    done < <(find "$cache_dir/c" -type f -name options.zig 2>/dev/null || true)

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
        "assertions requested but options.zig with CPU symbols was not found expected-cpu-effective=${expect_cpu_effective:-<unset>} expected-cpu-shader-mode=${expect_cpu_shader_mode:-<unset>} expected-cpu-shader-timeout-ms=${expect_cpu_shader_timeout_ms:-<unset>} expected-cpu-frame-damage-mode=${expect_cpu_frame_damage_mode:-<unset>} expected-cpu-damage-rect-cap=${expect_cpu_damage_rect_cap:-<unset>} expected-software-route-backend=${expect_software_route_backend:-<unset>}" \
        "cache-root=$cache_dir/c options-candidates=$options_candidates_count" \
        "options-candidates-preview=$options_preview"
    fi

    if [[ -n "$expect_cpu_effective" ]]; then
      if ! grep -Eq "software_renderer_cpu_effective[^=]*=[[:space:]]*$expect_cpu_effective([[:space:]]|,|;)" "$options_file"; then
        actual_cpu_effective="$(sed -nE 's/.*software_renderer_cpu_effective[^=]*=[[:space:]]*(true|false).*/\1/p' "$options_file" | head -n 1)"
        if [[ -z "$actual_cpu_effective" ]]; then
          actual_cpu_effective="unknown"
        fi
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-effective mismatch expected=$expect_cpu_effective actual=$actual_cpu_effective file=$options_file"
      fi
      echo "[software-compat] cpu-effective assertion matched expected=$expect_cpu_effective"
    fi

    if [[ -n "$expect_cpu_shader_mode" ]]; then
      if ! grep -Eq "software_renderer_cpu_shader_mode[^=]*=[[:space:]]*\\.?$expect_cpu_shader_mode([[:space:]]|,|;)" "$options_file"; then
        actual_cpu_shader_mode="$(sed -nE 's/.*software_renderer_cpu_shader_mode[^=]*=[[:space:]]*\.?([[:alnum:]_]+).*/\1/p' "$options_file" | head -n 1)"
        if [[ -z "$actual_cpu_shader_mode" ]]; then
          actual_cpu_shader_mode="unknown"
        fi
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-shader-mode mismatch expected=$expect_cpu_shader_mode actual=$actual_cpu_shader_mode file=$options_file"
      fi
      echo "[software-compat] cpu-shader-mode assertion matched expected=$expect_cpu_shader_mode"
    fi

    if [[ -n "$expect_cpu_shader_timeout_ms" ]]; then
      if ! grep -Eq "software_renderer_cpu_shader_timeout_ms[^=]*=[[:space:]]*$expect_cpu_shader_timeout_ms([[:space:]]|,|;)" "$options_file"; then
        actual_cpu_shader_timeout_ms="$(sed -nE 's/.*software_renderer_cpu_shader_timeout_ms[^=]*=[[:space:]]*([0-9]+).*/\1/p' "$options_file" | head -n 1)"
        if [[ -z "$actual_cpu_shader_timeout_ms" ]]; then
          actual_cpu_shader_timeout_ms="unknown"
        fi
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-shader-timeout-ms mismatch expected=$expect_cpu_shader_timeout_ms actual=$actual_cpu_shader_timeout_ms file=$options_file"
      fi
      echo "[software-compat] cpu-shader-timeout-ms assertion matched expected=$expect_cpu_shader_timeout_ms"
    fi

    if [[ -n "$expect_cpu_frame_damage_mode" ]]; then
      if ! grep -Eq "software_renderer_cpu_frame_damage_mode[^=]*=[[:space:]]*\\.?$expect_cpu_frame_damage_mode([[:space:]]|,|;)" "$options_file"; then
        actual_cpu_frame_damage_mode="$(sed -nE 's/.*software_renderer_cpu_frame_damage_mode[^=]*=[[:space:]]*\.?([[:alnum:]_]+).*/\1/p' "$options_file" | head -n 1)"
        if [[ -z "$actual_cpu_frame_damage_mode" ]]; then
          actual_cpu_frame_damage_mode="unknown"
        fi
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-frame-damage-mode mismatch expected=$expect_cpu_frame_damage_mode actual=$actual_cpu_frame_damage_mode file=$options_file"
      fi
      echo "[software-compat] cpu-frame-damage-mode assertion matched expected=$expect_cpu_frame_damage_mode"
    fi

    if [[ -n "$expect_cpu_damage_rect_cap" ]]; then
      if ! grep -Eq "software_renderer_cpu_damage_rect_cap[^=]*=[[:space:]]*$expect_cpu_damage_rect_cap([[:space:]]|,|;)" "$options_file"; then
        actual_cpu_damage_rect_cap="$(sed -nE 's/.*software_renderer_cpu_damage_rect_cap[^=]*=[[:space:]]*([0-9]+).*/\1/p' "$options_file" | head -n 1)"
        if [[ -z "$actual_cpu_damage_rect_cap" ]]; then
          actual_cpu_damage_rect_cap="unknown"
        fi
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "cpu-damage-rect-cap mismatch expected=$expect_cpu_damage_rect_cap actual=$actual_cpu_damage_rect_cap file=$options_file"
      fi
      echo "[software-compat] cpu-damage-rect-cap assertion matched expected=$expect_cpu_damage_rect_cap"
    fi

    if [[ -n "$expect_software_route_backend" ]]; then
      if ! grep -Eq "software_renderer_route_backend[^=]*=[[:space:]]*\\.?$expect_software_route_backend([[:space:]]|,|;)" "$options_file"; then
        actual_software_route_backend="$(sed -nE 's/.*software_renderer_route_backend[^=]*=[[:space:]]*\.?([[:alnum:]_]+).*/\1/p' "$options_file" | head -n 1)"
        if [[ -z "$actual_software_route_backend" ]]; then
          actual_software_route_backend="unknown"
        fi
        report_failure \
          "assertion config-mismatch" \
          "expected build option value does not match generated options.zig" \
          "software-route-backend mismatch expected=$expect_software_route_backend actual=$actual_software_route_backend file=$options_file"
      fi
      echo "[software-compat] software-route-backend assertion matched expected=$expect_software_route_backend"
    fi

  fi

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
