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
    [--expect-cpu-effective <true|false>] \
    [--expect-cpu-shader-mode <off|safe|full>] \
    [--app-runtime <runtime>] \
    [--system <deps-path>] \
    [--expected-host-os <linux|macos>] \
    [--mismatch-policy <skip|fail>] \
    [--mode <build|test>]

Examples:
  .github/scripts/software-renderer-compat-check.sh \
    --target x86_64-linux.5.3.0 \
    --app-runtime none

  .github/scripts/software-renderer-compat-check.sh \
    --transport native \
    --target x86_64-macos.13.0.0 \
    --allow-legacy-os true \
    --system /path/to/deps
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

mode="test"
transport="auto"
target=""
allow_legacy_os="false"
cpu_shader_mode=""
cpu_shader_timeout_ms=""
expect_cpu_effective=""
expect_cpu_shader_mode=""
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

if [[ -n "$expect_cpu_effective" && "$expect_cpu_effective" != "true" && "$expect_cpu_effective" != "false" ]]; then
  echo "invalid --expect-cpu-effective: $expect_cpu_effective" >&2
  exit 2
fi

if [[ -n "$expect_cpu_shader_mode" && "$expect_cpu_shader_mode" != "off" && "$expect_cpu_shader_mode" != "safe" && "$expect_cpu_shader_mode" != "full" ]]; then
  echo "invalid --expect-cpu-shader-mode: $expect_cpu_shader_mode (expected: off|safe|full)" >&2
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

echo "[software-compat] host=$host_os mode=$mode transport=$transport allow-legacy-os=$allow_legacy_os cpu-shader-mode=${cpu_shader_mode:-default} cpu-shader-timeout-ms=${cpu_shader_timeout_ms:-default} target=${target:-default}"
echo "[software-compat] cmd: ${cmd[*]}"

log_file="$(mktemp -t ghostty-software-compat.XXXXXX.log)"
trap 'rm -f "$log_file"; rm -rf "$cache_dir"' EXIT

if "${cmd[@]}" 2>&1 | tee "$log_file"; then
  if [[ -n "$expect_cpu_effective" || -n "$expect_cpu_shader_mode" ]]; then
    options_file=""
    while IFS= read -r candidate; do
      if grep -Eq 'software_renderer_cpu_effective|software_renderer_cpu_shader_mode' "$candidate"; then
        options_file="$candidate"
        break
      fi
    done < <(find "$cache_dir/c" -type f -name options.zig 2>/dev/null || true)

    if [[ -z "$options_file" ]]; then
      echo "[software-compat] assertions requested but options.zig not found in cache expected-cpu-effective=${expect_cpu_effective:-<unset>} expected-cpu-shader-mode=${expect_cpu_shader_mode:-<unset>}"
      exit 1
    fi

    if [[ -n "$expect_cpu_effective" ]]; then
      if ! grep -Eq "software_renderer_cpu_effective[^=]*=[[:space:]]*$expect_cpu_effective([[:space:]]|,|;)" "$options_file"; then
        actual_cpu_effective="$(sed -nE 's/.*software_renderer_cpu_effective[^=]*=[[:space:]]*(true|false).*/\1/p' "$options_file" | head -n 1)"
        if [[ -z "$actual_cpu_effective" ]]; then
          actual_cpu_effective="unknown"
        fi
        echo "[software-compat] cpu-effective mismatch expected=$expect_cpu_effective actual=$actual_cpu_effective file=$options_file"
        exit 1
      fi
      echo "[software-compat] cpu-effective assertion matched expected=$expect_cpu_effective"
    fi

    if [[ -n "$expect_cpu_shader_mode" ]]; then
      if ! grep -Eq "software_renderer_cpu_shader_mode[^=]*=[[:space:]]*\\.?$expect_cpu_shader_mode([[:space:]]|,|;)" "$options_file"; then
        actual_cpu_shader_mode="$(sed -nE 's/.*software_renderer_cpu_shader_mode[^=]*=[[:space:]]*\.?([[:alnum:]_]+).*/\1/p' "$options_file" | head -n 1)"
        if [[ -z "$actual_cpu_shader_mode" ]]; then
          actual_cpu_shader_mode="unknown"
        fi
        echo "[software-compat] cpu-shader-mode mismatch expected=$expect_cpu_shader_mode actual=$actual_cpu_shader_mode file=$options_file"
        exit 1
      fi
      echo "[software-compat] cpu-shader-mode assertion matched expected=$expect_cpu_shader_mode"
    fi
  fi

  echo "[software-compat] success"
  exit 0
fi

if grep -Eq 'recompile with -fPIC|ld\.lld: relocation' "$log_file"; then
  echo "[software-compat] failure-class=environment toolchain-linker-pic"
  echo "[software-compat] hint: verify host/runner and third-party archive PIC compatibility"
  exit 1
fi

if grep -Eq 'xcodebuild.*(CodeSign|codesign)|Library .* not found|Testing cancelled because the build failed' "$log_file"; then
  echo "[software-compat] failure-class=environment xcode-build-chain"
  echo "[software-compat] hint: verify Xcode selection and build environment"
  exit 1
fi

echo "[software-compat] failure-class=logic-or-runtime"
echo "[software-compat] hint: inspect logs above for regression details"
exit 1
