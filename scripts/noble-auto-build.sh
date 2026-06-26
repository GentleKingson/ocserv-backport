#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_dscverify.sh
. "${SCRIPT_DIR}/_dscverify.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

CORE_PACKAGES=(
  git ca-certificates curl gnupg build-essential fakeroot devscripts dpkg-dev
  debian-archive-keyring debian-keyring debian-maintainers sbuild schroot
  debootstrap lintian python3 python3-yaml bats shellcheck
)

CORE_COMMANDS=(
  git curl gpg dpkg-buildpackage dscverify dpkg-source sbuild schroot
  debootstrap lintian python3 bats shellcheck
)

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

print_core_install_guidance() {
  printf 'Install core build dependencies with:\n' >&2
  printf '  sudo apt-get update\n' >&2
  printf '  sudo apt-get install -y --no-install-recommends' >&2
  printf ' %s' "${CORE_PACKAGES[@]}" >&2
  printf '\n' >&2
}

check_core_dependencies() {
  local cmd missing_count=0

  for cmd in "${CORE_COMMANDS[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      log "missing required command: ${cmd}"
      missing_count=$((missing_count + 1))
    fi
  done

  if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import yaml' >/dev/null 2>&1; then
    log "missing required Python module: yaml (install package python3-yaml)"
    missing_count=$((missing_count + 1))
  fi

  if [[ "${missing_count}" -gt 0 ]]; then
    print_core_install_guidance
    return 1
  fi
}

check_debian_dscverify_keyrings() {
  local keyring readable_count=0

  while IFS= read -r keyring; do
    [[ -n "${keyring}" ]] || continue
    if [[ -r "${keyring}" ]]; then
      log "using Debian dscverify keyring: ${keyring}"
      readable_count=$((readable_count + 1))
    fi
  done < <(dscverify_candidate_keyrings)

  if [[ "${readable_count}" -eq 0 ]]; then
    log "no readable Debian dscverify keyrings found."
    log "Install them with: sudo apt-get install -y --no-install-recommends debian-keyring debian-maintainers"
    return 1
  fi
}

provision_core_dependencies() {
  log "installing core build dependencies"
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y --no-install-recommends "${CORE_PACKAGES[@]}"
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

if [[ "${PROVISION}" -eq 1 ]]; then
  provision_core_dependencies
fi

check_core_dependencies || die "missing core build dependencies"
check_debian_dscverify_keyrings || die "missing readable Debian dscverify keyring"

cd -- "${REPO_ROOT}"

log "noble-auto-build foundation ready: TARGET_ARCH=${TARGET_ARCH} mirror=${NOBLE_AUTO_BUILD_MIRROR} provision=${PROVISION} sudo=${sudo_mode}"
