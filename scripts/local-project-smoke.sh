#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  scripts/local-project-smoke.sh [--quick] [--full] [--skip-windows] [--skip-core] [--skip-libghostty] [--win32-native] [--win32-core-draw] [--software-renderer-contracts]

说明:
  这是本项目本地优先的默认验收入口。
  默认验收 = 本地脚本 + 手动触发 Project CI 的最小 Win32 native smoke。

默认执行:
  1. Zig 核心测试: zig build test -Dskip-macos-ui-tests=true
  2. Windows D3D12 smoke 交叉构建
  3. libghostty software-host 示例构建/运行
  4. software-renderer contracts: compat/selftest + 当前主机可执行的 cpu-path contracts

可选项:
  --quick                        只跑 Zig 核心测试 + Windows D3D12 smoke 交叉构建
  --full                         在默认验收上追加本机可执行的 Win32 native/core-draw smoke
  --skip-windows                 跳过 Windows 相关 smoke（交叉构建 + native + core-draw）
  --skip-core       跳过 Zig 核心测试
  --skip-libghostty 跳过 libghostty software-host 示例
  --win32-native                 追加运行本机 Win32 native smoke（仅 Windows）
  --win32-core-draw              追加运行本机 Win32 core-draw smoke（仅 Windows）
  --software-renderer-contracts  追加运行 software-renderer contracts（可覆盖 --quick）
  -h, --help        显示帮助
EOF
}

run_core=true
run_windows=true
run_libghostty=true
run_software_renderer_contracts=true
run_win32_native=false
run_win32_core_draw=false

while (($# > 0)); do
  case "$1" in
    --quick)
      run_libghostty=false
      run_software_renderer_contracts=false
      run_win32_native=false
      run_win32_core_draw=false
      shift
      ;;
    --full)
      run_libghostty=true
      run_software_renderer_contracts=true
      run_win32_native=true
      run_win32_core_draw=true
      shift
      ;;
    --skip-windows)
      run_windows=false
      run_win32_native=false
      run_win32_core_draw=false
      shift
      ;;
    --skip-core)
      run_core=false
      shift
      ;;
    --skip-libghostty)
      run_libghostty=false
      shift
      ;;
    --win32-native)
      run_win32_native=true
      shift
      ;;
    --win32-core-draw)
      run_win32_core_draw=true
      shift
      ;;
    --software-renderer-contracts)
      run_software_renderer_contracts=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

have_nix=false
if command -v nix >/dev/null 2>&1; then
  have_nix=true
fi

host_os="unknown"
case "$(uname -s)" in
  Linux) host_os="linux" ;;
  Darwin) host_os="macos" ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT) host_os="windows" ;;
esac

pwsh_cmd=""
if command -v pwsh >/dev/null 2>&1; then
  pwsh_cmd="pwsh"
elif command -v powershell.exe >/dev/null 2>&1; then
  pwsh_cmd="powershell.exe"
fi

log_dir="$repo_root/local-logs"
mkdir -p "$log_dir"

run_step() {
  local label="$1"
  shift
  echo "[local-smoke] phase=$label start"
  "$@" 2>&1 | tee "$log_dir/$label.log"
  echo "[local-smoke] phase=$label success"
}

if [[ "$run_core" == true ]]; then
  run_step \
    zig-core-tests \
    zig build test -Dskip-macos-ui-tests=true
fi

if [[ "$run_windows" == true ]]; then
  run_step \
    windows-d3d12-cross-build \
    zig build \
      -Dtarget=x86_64-windows-gnu \
      -Dfont-backend=directwrite \
      -Dapp-runtime=win32 \
      -Drenderer=d3d12 \
      -Dci-windows-smoke-minimal=true \
      -Demit-exe=true
fi

if [[ "$run_libghostty" == true ]]; then
  if [[ "$have_nix" == true ]]; then
    run_step \
      linux-libghostty-software-host \
      bash -lc 'cd example/c-libghostty-software-host && nix --accept-flake-config develop -c zig build run'
  else
    echo "[local-smoke] phase=linux-libghostty-software-host skipped reason=nix-not-found"
  fi
fi

if [[ "$run_software_renderer_contracts" == true ]]; then
  run_step \
    software-renderer-compat-selftest \
    ./.github/scripts/software-renderer-compat-check-selftest.sh
  run_step \
    software-renderer-cpu-path-selftest \
    ./.github/scripts/software-renderer-cpu-path-ci-selftest.sh

  if [[ "$have_nix" != true ]]; then
    echo "[local-smoke] phase=software-renderer-contracts skipped reason=nix-not-found"
  else
    case "$host_os" in
      linux)
        run_step \
          software-renderer-contracts-linux \
          bash -lc 'SR_CI_OS=linux SR_CI_TRANSPORT_MODE=auto ./.github/scripts/software-renderer-cpu-path-ci.sh'
        ;;
      macos)
        run_step \
          software-renderer-contracts-macos \
          bash -lc 'nix --accept-flake-config build -L .#deps && SYSTEM_PATH="$(readlink ./result)" && SR_CI_OS=macos SR_CI_TRANSPORT_MODE=auto SR_CI_SYSTEM_PATH="$SYSTEM_PATH" ./.github/scripts/software-renderer-cpu-path-ci.sh'
        ;;
      *)
        echo "[local-smoke] phase=software-renderer-contracts skipped reason=unsupported-host-os host=$host_os"
        ;;
    esac
  fi
fi

run_windows_runtime_smoke() {
  local mode="$1"
  local label="$2"

  if [[ "$host_os" != "windows" ]]; then
    echo "[local-smoke] phase=$label skipped reason=host-not-windows host=$host_os"
    return
  fi
  if [[ -z "$pwsh_cmd" ]]; then
    echo "[local-smoke] phase=$label skipped reason=pwsh-not-found"
    return
  fi

  run_step \
    "$label" \
    "$pwsh_cmd" -NoLogo -NoProfile -File ./.github/scripts/windows-win32-d3d12-smoke.ps1 -Mode "$mode"
}

if [[ "$run_win32_native" == true ]]; then
  run_windows_runtime_smoke native windows-win32-native-smoke
fi

if [[ "$run_win32_core_draw" == true ]]; then
  run_windows_runtime_smoke core-draw windows-win32-core-draw-smoke
fi

echo "[local-smoke] success"
