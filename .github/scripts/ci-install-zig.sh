#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[ci-install-zig] $*" >&2
}

die() {
  echo "[ci-install-zig] error: $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
zon_file="$repo_root/build.zig.zon"

require_cmd curl
require_cmd sed
require_cmd tar
require_cmd uname
require_cmd mktemp

os="$(uname -s)"
arch="$(uname -m)"

if [[ "$os" != "Linux" ]]; then
  die "unsupported OS: $os (expected: Linux)"
fi
if [[ "$arch" != "x86_64" ]]; then
  die "unsupported arch: $arch (expected: x86_64)"
fi

if [[ ! -f "$zon_file" ]]; then
  die "missing $zon_file"
fi

zig_version="$(
  sed -nE 's/.*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$zon_file" \
    | head -n1
)"
if [[ -z "$zig_version" ]]; then
  die "failed to parse minimum_zig_version from $zon_file"
fi

install_dir="${ZIG_INSTALL_DIR:-"$repo_root/.ci/zig/$zig_version"}"
if [[ "$install_dir" != /* ]]; then
  install_dir="$repo_root/$install_dir"
fi

zig_bin="$install_dir/zig"

log "minimum_zig_version=$zig_version"
if [[ -n "${ZIG_INSTALL_DIR:-}" ]]; then
  log "ZIG_INSTALL_DIR=$ZIG_INSTALL_DIR"
fi
log "install_dir=$install_dir"

if [[ -x "$zig_bin" ]]; then
  installed_version="$("$zig_bin" version || true)"
  if [[ "$installed_version" == "$zig_version" ]]; then
    log "zig already installed: $zig_bin (version=$installed_version)"
  else
    if [[ -n "${ZIG_INSTALL_DIR:-}" ]]; then
      die "existing zig at $zig_bin has version '$installed_version' (expected: $zig_version); clean $install_dir or set a version-specific ZIG_INSTALL_DIR"
    fi
    log "existing zig version mismatch (found=$installed_version expected=$zig_version), reinstalling"
    rm -rf -- "$install_dir"
  fi
fi

if [[ ! -x "$zig_bin" ]]; then
  tarball="zig-linux-x86_64-$zig_version.tar.xz"
  url_release="https://ziglang.org/download/$zig_version/$tarball"
  url_builds="https://ziglang.org/builds/$tarball"

  tmp_dir="$(mktemp -d)"
  cleanup() { rm -rf -- "$tmp_dir"; }
  trap cleanup EXIT

  archive="$tmp_dir/$tarball"
  download_url=""

  log "download_url(primary)=$url_release"
  if curl -fL --retry 5 --retry-delay 2 -o "$archive" "$url_release"; then
    download_url="$url_release"
  else
    rm -f -- "$archive"
    log "download_url(fallback)=$url_builds"
    if curl -fL --retry 5 --retry-delay 2 -o "$archive" "$url_builds"; then
      download_url="$url_builds"
    else
      die "failed to download Zig archive from both URLs"
    fi
  fi

  log "download_url=$download_url"

  tar -xJf "$archive" -C "$tmp_dir"

  extracted_dir="$tmp_dir/zig-linux-x86_64-$zig_version"
  if [[ ! -d "$extracted_dir" ]]; then
    extracted_dir="$(find "$tmp_dir" -maxdepth 1 -type d -name 'zig-linux-x86_64-*' | head -n1 || true)"
  fi
  if [[ -z "$extracted_dir" || ! -d "$extracted_dir" ]]; then
    die "failed to find extracted zig directory in $tmp_dir"
  fi
  if [[ ! -x "$extracted_dir/zig" ]]; then
    die "extracted zig binary not found at $extracted_dir/zig"
  fi

  mkdir -p -- "$(dirname -- "$install_dir")"
  if [[ -e "$install_dir" ]]; then
    if [[ -n "${ZIG_INSTALL_DIR:-}" ]]; then
      die "install_dir already exists: $install_dir (refusing to overwrite because ZIG_INSTALL_DIR is set)"
    fi
    rm -rf -- "$install_dir"
  fi

  mv -- "$extracted_dir" "$install_dir"

  zig_bin="$install_dir/zig"
fi

zig_version_actual="$("$zig_bin" version)"
log "zig_bin=$zig_bin"
log "zig version=$zig_version_actual"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$install_dir" >>"$GITHUB_PATH"
  log "added to GITHUB_PATH: $install_dir"
else
  log "GITHUB_PATH is not set; printing a sourceable export line to stdout"
  echo "export PATH=\"${install_dir}:\$PATH\""
fi

