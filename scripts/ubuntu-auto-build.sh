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

TARGET_SUITE="${TARGET_SUITE:-${TARGET_DISTRIBUTION:-noble}}"
case "${TARGET_SUITE}" in
  noble)
    AUTO_BUILD_NAME="noble-auto-build"
    AUTO_BUILD_LABEL="Noble"
    AUTO_BUILD_DESCRIPTION="Ubuntu 24.04 Noble"
    AUTO_BUILD_ENV_PREFIX="NOBLE"
    ;;
  resolute)
    AUTO_BUILD_NAME="resolute-auto-build"
    AUTO_BUILD_LABEL="Resolute"
    AUTO_BUILD_DESCRIPTION="Ubuntu 26.04 Resolute"
    AUTO_BUILD_ENV_PREFIX="RESOLUTE"
    ;;
  *)
    die "unsupported Ubuntu suite: ${TARGET_SUITE} (supported: noble, resolute)"
    ;;
esac

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

SBUILD_CHROOT_SUITE="${TARGET_SUITE}"
SBUILD_CHROOT_SUFFIX=""
SBUILD_CHROOT_EXTRA_ARGS=("--components=${SBUILD_CHROOT_COMPONENTS:-main,universe}")

auto_build_parse_args "$@"

# shellcheck source=scripts/ubuntu-env.sh
. "${SCRIPT_DIR}/ubuntu-env.sh"

validate_ubuntu_host() {
  read_host_os "${UBUNTU_DESCRIPTION}"

  if [[ "${HOST_ID}" != "ubuntu" || "${HOST_CODENAME}" != "${TARGET_SUITE}" ]]; then
    die "requires ${UBUNTU_DESCRIPTION} (found ID=${HOST_ID:-unknown} VERSION_CODENAME=${HOST_CODENAME:-unknown})"
  fi
}

select_ubuntu_mirror() {
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

run_ubuntu_build() {
  local docker_cmd docker_var
  docker_cmd="$(docker_command_for_make)"
  docker_var="${UBUNTU_ENV_PREFIX}_DOCKER_CMD"
  log "running make ${TARGET_SUITE}-build with ${docker_var}=${docker_cmd}"
  (
    export "${docker_var}=${docker_cmd}"
    make "${TARGET_SUITE}-build"
  )
}

validate_ubuntu_host

log "Ubuntu ${UBUNTU_SUITE_LABEL} target architecture: ${TARGET_ARCH}"
if [[ -n "${UBUNTU_NATIVE_ARCH:-}" ]]; then
  log "Ubuntu ${UBUNTU_SUITE_LABEL} native architecture: ${UBUNTU_NATIVE_ARCH}"
fi
warn_if_non_native_target

AUTO_BUILD_MIRROR="$(auto_build_env MIRROR "$(select_ubuntu_mirror)")"
export AUTO_BUILD_MIRROR

auto_build_init_privileges
auto_build_prepare_host

cd -- "${REPO_ROOT}"

log "${AUTO_BUILD_NAME} foundation ready: TARGET_ARCH=${TARGET_ARCH} mirror=${AUTO_BUILD_MIRROR} provision=${PROVISION} sudo=${SUDO_MODE}"
run_ubuntu_build
print_build_artifacts "${AUTO_BUILD_NAME}" \
  "${TARGET_BINARY_ROOT}/ocserv_*.deb"
