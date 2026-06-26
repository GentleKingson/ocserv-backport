#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/noble-auto-build.sh [--provision]

Prepare the Ubuntu 24.04 Noble auto-build wrapper.

Options:
  --provision  Prepare host build prerequisites before running.
  -h, --help   Show this help.
EOF
}

usage_stderr() {
  usage >&2
}

PROVISION=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --provision)
      PROVISION=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage_stderr
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
  shift
done

[[ "$#" -eq 0 ]] || die "unexpected argument: $1"

validate_noble_host() {
  local os_release_path="${NOBLE_AUTO_BUILD_OS_RELEASE_PATH:-/etc/os-release}"
  local ID="" VERSION_CODENAME="" UBUNTU_CODENAME=""

  [[ -r "${os_release_path}" ]] || die "requires Ubuntu 24.04 Noble; cannot read ${os_release_path}"

  # shellcheck source=/etc/os-release disable=SC1091
  . "${os_release_path}"

  if [[ "${ID}" != "ubuntu" || ( "${VERSION_CODENAME:-}" != "noble" && "${UBUNTU_CODENAME:-}" != "noble" ) ]]; then
    die "requires Ubuntu 24.04 Noble (found ID=${ID:-unknown} VERSION_CODENAME=${VERSION_CODENAME:-unknown})"
  fi
}

select_noble_mirror() {
  case "${TARGET_ARCH}" in
    amd64)
      printf '%s\n' "http://archive.ubuntu.com/ubuntu"
      ;;
    arm64)
      printf '%s\n' "http://ports.ubuntu.com/ubuntu-ports"
      ;;
    *)
      die "unsupported TARGET_ARCH=${TARGET_ARCH}; supported architectures: amd64, arm64"
      ;;
  esac
}

TARGET_ARCH="${TARGET_ARCH:-amd64}"
export TARGET_ARCH

validate_noble_host

NOBLE_AUTO_BUILD_MIRROR="${NOBLE_AUTO_BUILD_MIRROR:-$(select_noble_mirror)}"
export NOBLE_AUTO_BUILD_MIRROR

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

if [[ "${#SUDO[@]}" -eq 0 ]]; then
  sudo_mode="root"
else
  sudo_mode="${SUDO[*]}"
fi

cd -- "${REPO_ROOT}"

log "noble-auto-build foundation ready: TARGET_ARCH=${TARGET_ARCH} mirror=${NOBLE_AUTO_BUILD_MIRROR} provision=${PROVISION} sudo=${sudo_mode}"
