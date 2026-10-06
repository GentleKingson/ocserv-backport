#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
# shellcheck source=scripts/_dscverify.sh
. "${SCRIPT_DIR}/_dscverify.sh"
# shellcheck source=scripts/_auto_build.sh
. "${SCRIPT_DIR}/_auto_build.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

AUTO_BUILD_NAME="noble-auto-build"
AUTO_BUILD_LABEL="Noble"
AUTO_BUILD_DESCRIPTION="Ubuntu 24.04 Noble"
AUTO_BUILD_ENV_PREFIX="NOBLE"

CORE_PACKAGES=(
  git ca-certificates curl gnupg build-essential fakeroot devscripts dpkg-dev
  debhelper
  debian-archive-keyring debian-keyring debian-maintainers sbuild schroot
  debootstrap lintian python3 python3-yaml bats shellcheck
)

CORE_COMMANDS=(
  git curl gpg dpkg-buildpackage dscverify dpkg-source dh sbuild schroot
  debootstrap lintian python3 bats shellcheck
)

SBUILD_CHROOT_SUITE="noble"
SBUILD_CHROOT_SUFFIX=""
SBUILD_CHROOT_EXTRA_ARGS=("--components=${SBUILD_CHROOT_COMPONENTS:-main,universe}")

auto_build_parse_args "$@"

# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"

validate_noble_host() {
  read_host_os "Ubuntu 24.04 Noble"

  if [[ "${HOST_ID}" != "ubuntu" || "${HOST_CODENAME}" != "noble" ]]; then
    die "requires Ubuntu 24.04 Noble (found ID=${HOST_ID:-unknown} VERSION_CODENAME=${HOST_CODENAME:-unknown})"
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

run_noble_build() {
  local docker_cmd

  docker_cmd="$(docker_command_for_make)"
  log "running make noble-build with NOBLE_DOCKER_CMD=${docker_cmd}"
  NOBLE_DOCKER_CMD="${docker_cmd}" make noble-build
}

validate_noble_host

log "Ubuntu Noble target architecture: ${TARGET_ARCH}"
if [[ -n "${NOBLE_NATIVE_ARCH:-}" ]]; then
  log "Ubuntu Noble native architecture: ${NOBLE_NATIVE_ARCH}"
fi
warn_if_non_native_target

NOBLE_AUTO_BUILD_MIRROR="${NOBLE_AUTO_BUILD_MIRROR:-$(select_noble_mirror)}"
AUTO_BUILD_MIRROR="${NOBLE_AUTO_BUILD_MIRROR}"
export NOBLE_AUTO_BUILD_MIRROR

auto_build_init_privileges
auto_build_prepare_host

cd -- "${REPO_ROOT}"

log "noble-auto-build foundation ready: TARGET_ARCH=${TARGET_ARCH} mirror=${NOBLE_AUTO_BUILD_MIRROR} provision=${PROVISION} sudo=${SUDO_MODE}"
run_noble_build
print_build_artifacts noble-auto-build \
  "${TARGET_BUILD_ROOT}/binary/ocserv/ocserv_*.deb"
