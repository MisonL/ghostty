#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  .github/scripts/software-renderer-compat-check.sh \
    --transport <auto|shared|native> \
    [--target <zig-target>] \
    [--app-runtime <runtime>] \
    [--system <deps-path>] \
    [--mismatch-policy <skip|fail>] \
    [--mode <build|test>]

Examples:
  .github/scripts/software-renderer-compat-check.sh \
    --transport auto \
    --target x86_64-linux.5.3.0 \
    --app-runtime none

  .github/scripts/software-renderer-compat-check.sh \
    --transport native \
    --target x86_64-macos.13.0.0 \
    --system /path/to/deps
EOF
}

mode="test"
transport=""
target=""
app_runtime=""
system_path=""
mismatch_policy="skip"

while (($# > 0)); do
  case "$1" in
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    --transport)
      transport="${2:-}"
      shift 2
      ;;
    --target)
      target="${2:-}"
      shift 2
      ;;
    --app-runtime)
      app_runtime="${2:-}"
      shift 2
      ;;
    --system)
      system_path="${2:-}"
      shift 2
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

if [[ -z "$transport" ]]; then
  echo "missing required arg: --transport" >&2
  usage >&2
  exit 2
fi

if [[ "$transport" != "auto" && "$transport" != "shared" && "$transport" != "native" ]]; then
  echo "invalid --transport: $transport" >&2
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

host_os="unknown"
case "$(uname -s)" in
  Linux) host_os="linux" ;;
  Darwin) host_os="macos" ;;
esac

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

cmd=(zig build)
if [[ "$mode" == "test" ]]; then
  cmd+=(test)
fi
cmd+=(-Drenderer=software)
cmd+=(-Dsoftware-renderer-cpu-mvp=true)
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

echo "[software-compat] host=$host_os mode=$mode transport=$transport target=${target:-default}"
echo "[software-compat] cmd: ${cmd[*]}"

log_file="$(mktemp -t ghostty-software-compat.XXXXXX.log)"
trap 'rm -f "$log_file"' EXIT

if "${cmd[@]}" 2>&1 | tee "$log_file"; then
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
