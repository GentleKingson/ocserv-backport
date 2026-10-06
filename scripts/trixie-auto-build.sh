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

AUTO_BUILD_NAME="trixie-auto-build"
AUTO_BUILD_LABEL="Trixie"
AUTO_BUILD_DESCRIPTION="Debian 13 trixie"
AUTO_BUILD_ENV_PREFIX="TRIXIE"

CORE_PACKAGES=(
  git curl gnupg build-essential fakeroot devscripts dpkg-dev debhelper
  debian-keyring sbuild schroot debootstrap lintian libdistro-info-perl
  python3 python3-yaml bats shellcheck make
)

CORE_COMMANDS=(
  git curl gpg dpkg-buildpackage dscverify dpkg-source dh sbuild schroot
  debootstrap lintian python3 bats shellcheck make
)

SBUILD_CHROOT_SUITE="trixie"
SBUILD_CHROOT_SUFFIX="-sbuild"
SBUILD_CHROOT_EXTRA_ARGS=()
TRIXIE_AUTO_BUILD_MIRROR="${TRIXIE_AUTO_BUILD_MIRROR:-http://deb.debian.org/debian}"
AUTO_BUILD_MIRROR="${TRIXIE_AUTO_BUILD_MIRROR}"

reject_legacy_trixie_env() {
  local legacy_var

  for legacy_var in DEBIAN_DOCKER_CMD DEBIAN_NATIVE_ARCH OCSERV_SKIP_FETCH_VERIFY_LOCK; do
    if [[ "${!legacy_var+x}" == x ]]; then
      printf 'error: legacy environment variable %s is no longer supported; use the TRIXIE_* name instead\n' "${legacy_var}" >&2
      exit 2
    fi
  done

  while IFS= read -r legacy_var; do
    [[ -n "${legacy_var}" ]] || continue
    printf 'error: legacy environment variable %s is no longer supported; use TRIXIE_AUTO_BUILD_* instead\n' "${legacy_var}" >&2
    exit 2
  done < <(compgen -A variable DEBIAN_AUTO_BUILD_)
}

validate_host() {
  read_host_os "Debian 13 trixie or Ubuntu 24.04 Noble"

  case "${HOST_ID}:${HOST_CODENAME}" in
    debian:trixie|ubuntu:noble)
      ;;
    *)
      die "requires Debian 13 trixie or Ubuntu 24.04 Noble (found ID=${HOST_ID:-unknown} VERSION_CODENAME=${HOST_CODENAME:-unknown})"
      ;;
  esac
}

run_debian_build() {
  local docker_cmd
  local lintian_profile="${LINTIAN_PROFILE:-}"

  docker_cmd="$(docker_command_for_make)"
  if [[ -z "${lintian_profile}" && "${HOST_ID}" == "ubuntu" ]]; then
    lintian_profile="debian"
  fi

  if [[ -n "${lintian_profile}" ]]; then
    log "running make trixie-build with TRIXIE_DOCKER_CMD=${docker_cmd} LINTIAN_PROFILE=${lintian_profile}"
    TRIXIE_DOCKER_CMD="${docker_cmd}" LINTIAN_PROFILE="${lintian_profile}" make trixie-build
  else
    log "running make trixie-build with TRIXIE_DOCKER_CMD=${docker_cmd}"
    TRIXIE_DOCKER_CMD="${docker_cmd}" make trixie-build
  fi
}

auto_build_parse_args "$@"
reject_legacy_trixie_env
validate_host
# shellcheck source=scripts/trixie-env.sh
. "${SCRIPT_DIR}/trixie-env.sh"
log "Debian Trixie target architecture: ${TARGET_ARCH}"
log "Debian Trixie native architecture: ${HOST_ARCH}"

auto_build_init_privileges
auto_build_prepare_host

cd -- "${REPO_ROOT}"

log "trixie-auto-build foundation ready: TARGET_ARCH=${TARGET_ARCH} host=${HOST_ID}:${HOST_CODENAME} mirror=${TRIXIE_AUTO_BUILD_MIRROR} provision=${PROVISION} sudo=${SUDO_MODE}"
run_debian_build
print_build_artifacts trixie-auto-build \
  "${TARGET_SOURCE_ROOT}/ocserv_*.dsc" \
  "${TARGET_BINARY_ROOT}/ocserv_*_${TARGET_ARCH}.deb" \
  "${TARGET_BINARY_ROOT}/ocserv_*_${TARGET_ARCH}.changes" \
  "${TARGET_BINARY_ROOT}/ocserv_*_${TARGET_ARCH}.buildinfo"
