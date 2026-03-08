#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  scripts/local-project-smoke.sh [--quick] [--skip-windows] [--skip-core] [--skip-libghostty]

说明:
  这是本项目本地优先的最小验证入口，用来替代仓库专属 Project CI 的自动触发。

默认执行:
  1. Zig 核心测试: zig build test -Dskip-macos-ui-tests=true
  2. Windows D3D12 smoke 交叉构建
  3. libghostty software-host 示例构建/运行

可选项:
  --quick           只跑 Zig 核心测试 + Windows D3D12 smoke 交叉构建
  --skip-windows    跳过 Windows D3D12 smoke 交叉构建
  --skip-core       跳过 Zig 核心测试
  --skip-libghostty 跳过 libghostty software-host 示例
  -h, --help        显示帮助
EOF
}

run_core=true
run_windows=true
run_libghostty=true

while (($# > 0)); do
  case "$1" in
    --quick)
      run_libghostty=false
      shift
      ;;
    --skip-windows)
      run_windows=false
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

echo "[local-smoke] success"
