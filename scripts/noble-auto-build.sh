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
  debhelper dh-nodejs
  debian-archive-keyring debian-keyring debian-maintainers sbuild schroot
  debootstrap lintian python3 python3-yaml bats shellcheck
)

CORE_COMMANDS=(
  git curl gpg dpkg-buildpackage dscverify dpkg-source dh pkgjs-pjson sbuild schroot
  debootstrap lintian python3 bats shellcheck
)

DOCKER_CONFLICT_PACKAGES=(
  docker.io docker-doc docker-compose docker-compose-v2 podman-docker
  containerd runc
)

DOCKER_REQUIRED_CE_PACKAGES=(
  docker-ce docker-ce-cli containerd.io
)

DOCKER_CE_PACKAGES=(
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
)

NOBLE_DSCVERIFY_REQUIRED_KEY="C6AE83D21C677043DA3DAC97F8643574713C9BAE"
SBUILD_CHROOT_COMPONENTS="${SBUILD_CHROOT_COMPONENTS:-main,universe}"
SBUILD_CHROOT_INCLUDE="eatmydata,ccache,gnupg,ca-certificates"
NOBLE_AUTO_BUILD_CHROOT_BASE="${NOBLE_AUTO_BUILD_CHROOT_BASE:-/srv/chroot}"
NOBLE_AUTO_BUILD_KEYRING_IMAGE="${NOBLE_AUTO_BUILD_KEYRING_IMAGE:-debian:sid}"

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
SUDO=()

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

# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"

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
  local apt_prefix=""

  if [[ "${#SUDO[@]}" -gt 0 ]]; then
    apt_prefix="${SUDO[*]} "
  fi

  printf 'Install core build dependencies with:\n' >&2
  printf '  %sapt-get -q=1 -o=Dpkg::Use-Pty=0 update\n' "${apt_prefix}" >&2
  printf '  %sapt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends' "${apt_prefix}" >&2
  printf ' %s' "${CORE_PACKAGES[@]}" >&2
  printf '\n\n' >&2
  printf 'Or let the wrapper install them with:\n' >&2
  printf '  scripts/noble-auto-build.sh --provision\n' >&2
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
  local keyring readable_count=0 required_key_found=0

  while IFS= read -r keyring; do
    [[ -n "${keyring}" ]] || continue
    if [[ -r "${keyring}" ]]; then
      log "using Debian dscverify keyring: ${keyring}"
      readable_count=$((readable_count + 1))
      if dscverify_keyring_contains_key "${keyring}" "${NOBLE_DSCVERIFY_REQUIRED_KEY}"; then
        required_key_found=1
      fi
    fi
  done < <(dscverify_candidate_keyrings)

  if [[ "${readable_count}" -eq 0 ]]; then
    log "no readable Debian dscverify keyrings found."
    log "Install them with: sudo apt-get install -y --no-install-recommends debian-keyring debian-maintainers"
    return 1
  fi

  if [[ "${required_key_found}" -ne 1 ]]; then
    log "required Debian source signing key not found in dscverify keyrings: ${NOBLE_DSCVERIFY_REQUIRED_KEY}"
    log "Run scripts/noble-auto-build.sh --provision without DSCVERIFY_KEYRING_PATHS to refresh keyrings automatically."
    return 1
  fi
}

debian_dscverify_keyring_root() {
  printf '%s\n' "${NOBLE_AUTO_BUILD_DSCVERIFY_KEYRING_ROOT:-${TARGET_DEBIAN_KEYRING_DIR}}"
}

refresh_debian_dscverify_keyrings() {
  local keyring_root keyring_path host_uid host_gid
  local -a keyrings

  keyring_root="$(debian_dscverify_keyring_root)"
  host_uid="$(id -u)"
  host_gid="$(id -g)"
  log "refreshing Debian dscverify keyrings from ${NOBLE_AUTO_BUILD_KEYRING_IMAGE}"
  rm -rf -- "${keyring_root}" || return 1
  mkdir -p "${keyring_root}" || return 1

  # The script passed to bash -c must expand HOST_UID/HOST_GID inside the
  # Debian container, not in the host shell.
  # shellcheck disable=SC2016
  "${DOCKER_COMMAND[@]}" run --rm \
    -v "${keyring_root}:/out" \
    -e "HOST_UID=${host_uid}" \
    -e "HOST_GID=${host_gid}" \
    "${NOBLE_AUTO_BUILD_KEYRING_IMAGE}" \
    bash -euxc '
      workdir="$(mktemp -d)"
      cd "${workdir}"
      apt-get update
      apt-get download \
        debian-archive-keyring \
        debian-keyring
      mkdir -p /out/root
      for deb in ./*.deb; do
        dpkg-deb -x "${deb}" /out/root
      done
      chown -R "${HOST_UID}:${HOST_GID}" /out/root
    ' || return 1

  while IFS= read -r keyring_path; do
    [[ -r "${keyring_path}" ]] || continue
    keyrings+=("${keyring_path}")
  done < <(
    find "${keyring_root}/root/usr/share/keyrings" \
      -maxdepth 1 \
      -type f \
      \( -name 'debian-*.gpg' -o -name 'debian-*.pgp' \) \
      -print \
      | sort
  )

  if [[ "${#keyrings[@]}" -eq 0 ]]; then
    log "no Debian keyrings extracted from ${NOBLE_AUTO_BUILD_KEYRING_IMAGE}"
    return 1
  fi

  DSCVERIFY_KEYRING_PATHS=""
  for keyring_path in "${keyrings[@]}"; do
    if [[ -z "${DSCVERIFY_KEYRING_PATHS}" ]]; then
      DSCVERIFY_KEYRING_PATHS="${keyring_path}"
    else
      DSCVERIFY_KEYRING_PATHS="${DSCVERIFY_KEYRING_PATHS}:${keyring_path}"
    fi
  done
  export DSCVERIFY_KEYRING_PATHS
}

ensure_debian_dscverify_keyrings() {
  if [[ -z "${DSCVERIFY_KEYRING_PATHS:-}" ]]; then
    refresh_debian_dscverify_keyrings || return 1
  fi

  check_debian_dscverify_keyrings
}

current_user_in_sbuild_group() {
  local groups

  groups="$(id -nG)"
  [[ " ${groups} " == *" sbuild "* ]]
}

print_sbuild_group_guidance() {
  printf 'Current user is not in the sbuild group.\n' >&2
  printf 'Run these commands, then rerun provisioning from the new shell:\n' >&2
  printf "  sudo sbuild-adduser \"\$USER\"\n" >&2
  printf '  newgrp sbuild\n' >&2
  printf '  scripts/noble-auto-build.sh --provision\n' >&2
}

print_sbuild_group_rerun_guidance() {
  printf 'The current shell does not have the sbuild group yet.\n' >&2
  printf 'Run:\n' >&2
  printf '  newgrp sbuild\n' >&2
  printf '  scripts/noble-auto-build.sh --provision\n' >&2
  printf 'Then rerun scripts/noble-auto-build.sh --provision from that shell.\n' >&2
}

ensure_sbuild_group() {
  local build_user

  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi

  if current_user_in_sbuild_group; then
    return 0
  fi

  if [[ "${PROVISION}" -ne 1 ]]; then
    print_sbuild_group_guidance
    return 1
  fi

  build_user="${USER:-$(id -un)}"
  log "adding ${build_user} to the sbuild group"
  "${SUDO[@]}" sbuild-adduser "${build_user}"
  print_sbuild_group_rerun_guidance

  if [[ "${NOBLE_AUTO_BUILD_SKIP_NEWGRP:-0}" == 1 ]]; then
    return 1
  fi

  if [[ -t 0 && -t 1 ]]; then
    log "starting a new shell with the sbuild group active"
    exec newgrp sbuild
  fi

  return 1
}

sbuild_chroot_name() {
  printf 'noble-%s\n' "${TARGET_ARCH}"
}

sbuild_chroot_path() {
  printf '%s/%s\n' "${NOBLE_AUTO_BUILD_CHROOT_BASE}" "$(sbuild_chroot_name)"
}

print_sbuild_createchroot_command() {
  printf '  sudo sbuild-createchroot --arch=%s --chroot-suffix= --components=%s --include=%s noble %s %s\n' \
    "${TARGET_ARCH}" \
    "${SBUILD_CHROOT_COMPONENTS}" \
    "${SBUILD_CHROOT_INCLUDE}" \
    "$(sbuild_chroot_path)" \
    "${NOBLE_AUTO_BUILD_MIRROR}" >&2
}

print_existing_sbuild_chroot_path_guidance() {
  local chroot_path="$1"
  local sudo_prefix=""

  if [[ "${#SUDO[@]}" -gt 0 ]]; then
    sudo_prefix="${SUDO[*]} "
  fi

  log "sbuild chroot path exists but is not registered: ${chroot_path}"
  printf 'The directory already exists, but schroot/sbuild does not list %s.\n' "$(sbuild_chroot_name)" >&2
  printf 'If this is a failed chroot creation attempt, review the path and remove it manually before retrying:\n' >&2
  printf '  %srm -rf %s\n' "${sudo_prefix}" "${chroot_path}" >&2
  printf '  scripts/noble-auto-build.sh --provision\n' >&2
}

print_unusable_sbuild_chroot_guidance() {
  local target="$1"
  local session_output="$2"
  local chroot_path
  local sudo_prefix=""

  chroot_path="$(sbuild_chroot_path)"
  if [[ "${#SUDO[@]}" -gt 0 ]]; then
    sudo_prefix="${SUDO[*]} "
  fi

  log "sbuild chroot is registered but unusable: ${target}"
  if [[ -n "${session_output}" ]]; then
    printf '%s\n' "${session_output}" >&2
  fi
  printf 'Check the registered chroot and backing directory:\n' >&2
  printf '  %sls -ld %s\n' "${sudo_prefix}" "${chroot_path}" >&2
  printf '  schroot -i -c %s\n' "${target}" >&2
  printf 'If the target directory is missing, remove the stale schroot config and recreate the chroot.\n' >&2
  printf 'Do not remove /etc/schroot/schroot.conf wholesale; edit only the [%s] stanza if it is defined there.\n' "${target}" >&2
}

chroot_listing_contains_target() {
  local target="$1"
  local listing="$2"
  local line

  while IFS= read -r line; do
    case "${line}" in
      "${target}"|"chroot:${target}")
        return 0
        ;;
    esac
  done <<<"${listing}"

  return 1
}

sbuild_chroot_is_registered() {
  local target="$1"
  local listing
  local found=1

  if command -v schroot >/dev/null 2>&1; then
    if listing="$(schroot -l 2>/dev/null)" && chroot_listing_contains_target "${target}" "${listing}"; then
      found=0
    fi
  fi

  if command -v sbuild >/dev/null 2>&1; then
    if listing="$(sbuild --list-chroots 2>/dev/null)" && chroot_listing_contains_target "${target}" "${listing}"; then
      found=0
    fi
  fi

  return "${found}"
}

sbuild_chroot_session_works() {
  local target="$1"

  SBUILD_CHROOT_SESSION_OUTPUT=""
  if SBUILD_CHROOT_SESSION_OUTPUT="$(
    cd /
    schroot -c "${target}" -u root -- true 2>&1
  )"; then
    return 0
  fi

  return 1
}

print_missing_sbuild_chroot_guidance() {
  printf 'Missing sbuild chroot: %s\n' "$(sbuild_chroot_name)" >&2
  printf 'Create it with:\n' >&2
  print_sbuild_createchroot_command
}

provision_sbuild_chroot() {
  local answer target
  local -a sbuild_createchroot_args

  target="$(sbuild_chroot_name)"
  print_missing_sbuild_chroot_guidance
  printf 'Type yes to create this chroot now: ' >&2
  IFS= read -r answer || answer=""

  if [[ "${answer}" != "yes" ]]; then
    log "sbuild chroot creation cancelled; rerun after creating ${target}"
    return 1
  fi

  sbuild_createchroot_args=(
    "--arch=${TARGET_ARCH}"
    "--chroot-suffix="
    "--components=${SBUILD_CHROOT_COMPONENTS}"
    "--include=${SBUILD_CHROOT_INCLUDE}"
    noble
    "$(sbuild_chroot_path)"
    "${NOBLE_AUTO_BUILD_MIRROR}"
  )

  "${SUDO[@]}" sbuild-createchroot "${sbuild_createchroot_args[@]}"

  if ! sbuild_chroot_is_registered "${target}"; then
    log "sbuild chroot ${target} is still not visible after creation"
    return 1
  fi

  if ! sbuild_chroot_session_works "${target}"; then
    print_unusable_sbuild_chroot_guidance "${target}" "${SBUILD_CHROOT_SESSION_OUTPUT}"
    return 1
  fi
}

ensure_sbuild_chroot() {
  local chroot_path target

  target="$(sbuild_chroot_name)"
  if sbuild_chroot_is_registered "${target}"; then
    if sbuild_chroot_session_works "${target}"; then
      return 0
    fi

    print_unusable_sbuild_chroot_guidance "${target}" "${SBUILD_CHROOT_SESSION_OUTPUT}"
    return 1
  fi

  chroot_path="$(sbuild_chroot_path)"
  if [[ -d "${chroot_path}" ]]; then
    print_existing_sbuild_chroot_path_guidance "${chroot_path}"
    return 1
  fi

  if [[ "${PROVISION}" -eq 1 ]]; then
    provision_sbuild_chroot
    return
  fi

  print_missing_sbuild_chroot_guidance
  return 1
}

provision_core_dependencies() {
  log "installing core build dependencies"
  apt_quiet update
  apt_quiet install -y --no-install-recommends "${CORE_PACKAGES[@]}"
}

apt_quiet_capture() {
  "${SUDO[@]}" apt-get -q=1 -o=Dpkg::Use-Pty=0 "$@" 2>&1
}

apt_quiet() {
  local output

  if ! output="$(apt_quiet_capture "$@")"; then
    printf '%s\n' "${output}" >&2
    return 1
  fi
}

print_docker_ce_install_guidance() {
  printf 'Docker CE is required for the Noble auto-build wrapper.\n' >&2
  printf 'Install Docker CE from the official Docker APT repository at download.docker.com, then install:\n' >&2
  printf '  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin\n' >&2
}

print_docker_daemon_guidance() {
  printf 'Docker is installed, but the Docker daemon is not reachable.\n' >&2
  printf 'Start it and verify access with:\n' >&2
  printf '  sudo systemctl enable --now docker\n' >&2
  printf '  sudo docker info\n' >&2
}

print_docker_mix_guidance() {
  log "Do not mix Ubuntu docker.io/containerd with Docker CE/containerd.io"
  print_docker_ce_install_guidance
}

package_is_installed() {
  local package="$1"
  local package_status

  if package_status="$(dpkg-query -W -f='${Status}' "${package}" 2>/dev/null)" \
    && [[ "${package_status}" == "install ok installed" ]]; then
    return 0
  fi

  return 1
}

check_docker_ce_packages() {
  local package missing_count=0 conflict_count=0

  for package in "${DOCKER_CONFLICT_PACKAGES[@]}"; do
    if package_is_installed "${package}"; then
      log "conflicting Ubuntu Docker package installed: ${package}"
      conflict_count=$((conflict_count + 1))
    fi
  done

  if [[ "${conflict_count}" -gt 0 ]]; then
    print_docker_mix_guidance
    return 1
  fi

  for package in "${DOCKER_REQUIRED_CE_PACKAGES[@]}"; do
    if ! package_is_installed "${package}"; then
      log "missing required Docker CE package: ${package}"
      missing_count=$((missing_count + 1))
    fi
  done

  if [[ "${missing_count}" -gt 0 ]]; then
    print_docker_ce_install_guidance
    return 1
  fi

  return 0
}

docker_info() {
  "${DOCKER_COMMAND[@]}" info
}

docker_command_for_make() {
  local IFS=" "
  printf '%s\n' "${DOCKER_COMMAND[*]}"
}

run_noble_build() {
  local docker_cmd

  docker_cmd="$(docker_command_for_make)"
  log "running make noble-build with NOBLE_DOCKER_CMD=${docker_cmd}"
  NOBLE_DOCKER_CMD="${docker_cmd}" make noble-build
}

print_noble_artifacts() {
  local build_root="${TARGET_BUILD_ROOT}"
  local artifact pattern
  local artifacts=()
  local matches=()
  local patterns=(
    "${build_root}/binary/node-undici/libllhttp9.2_*.deb"
    "${build_root}/binary/node-undici/libllhttp-dev_*.deb"
    "${build_root}/binary/ocserv/ocserv_*.deb"
    "${build_root}/repo/Packages"
  )

  for pattern in "${patterns[@]}"; do
    matches=()
    while IFS= read -r artifact; do
      matches+=("${artifact}")
    done < <(compgen -G "${pattern}" || true)
    if [[ "${#matches[@]}" -eq 0 ]]; then
      die "expected artifact not found: ${pattern}"
    fi
    artifacts+=("${matches[@]}")
  done

  log "noble-auto-build artifacts:"
  printf '%s\n' "${artifacts[@]}"
}

docker_keyring_path() {
  printf '%s\n' "${NOBLE_AUTO_BUILD_DOCKER_KEYRING_PATH:-/etc/apt/keyrings/docker.asc}"
}

docker_source_path() {
  printf '%s\n' "${NOBLE_AUTO_BUILD_DOCKER_SOURCE_PATH:-/etc/apt/sources.list.d/docker.sources}"
}

write_docker_apt_source() {
  local arch="$1"
  local keyring_path="$2"
  local source_path="$3"

  {
    printf 'Types: deb\n'
    printf 'URIs: https://download.docker.com/linux/ubuntu\n'
    printf 'Suites: noble\n'
    printf 'Components: stable\n'
    printf 'Signed-By: %s\n' "${keyring_path}"
    printf 'Architectures: %s\n' "${arch}"
  } | "${SUDO[@]}" tee "${source_path}" >/dev/null
}

install_docker_ce_packages() {
  local install_output

  if ! install_output="$(apt_quiet_capture install -y "${DOCKER_CE_PACKAGES[@]}")"; then
    printf '%s\n' "${install_output}" >&2
    if [[ "${install_output}" == *"containerd.io : Conflicts: containerd"* ]]; then
      log "Do not mix Ubuntu docker.io/containerd with Docker CE/containerd.io"
    fi
    return 1
  fi
}

provision_docker_ce() {
  local arch keyring_path source_path keyring_dir source_dir

  log "installing Docker CE from the official Docker repository"
  arch="$(dpkg --print-architecture)"
  keyring_path="$(docker_keyring_path)"
  source_path="$(docker_source_path)"
  keyring_dir="$(dirname -- "${keyring_path}")"
  source_dir="$(dirname -- "${source_path}")"

  apt_quiet remove -y "${DOCKER_CONFLICT_PACKAGES[@]}"
  apt_quiet update
  apt_quiet install -y --no-install-recommends ca-certificates curl
  "${SUDO[@]}" install -m 0755 -d "${keyring_dir}"
  "${SUDO[@]}" curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "${keyring_path}"
  "${SUDO[@]}" chmod a+r "${keyring_path}"
  "${SUDO[@]}" install -m 0755 -d "${source_dir}"
  write_docker_apt_source "${arch}" "${keyring_path}" "${source_path}"
  apt_quiet update
  install_docker_ce_packages
}

check_docker_provisioned() {
  if ! command -v docker >/dev/null 2>&1; then
    die "docker command is not available after Docker CE installation"
  fi

  check_docker_ce_packages || return 1

  if docker_info >/dev/null 2>&1; then
    return 0
  fi

  log "Docker daemon is not reachable; attempting limited systemd repair."
  "${SUDO[@]}" systemctl enable --now docker
  "${SUDO[@]}" systemctl enable --now containerd || true
  sleep 2

  if docker_info >/dev/null 2>&1; then
    return 0
  fi

  log "Docker daemon is still not reachable. Run diagnostics:"
  log "  sudo systemctl status docker"
  log "  sudo journalctl -u docker --no-pager -n 100"
  log "  sudo docker info"
  return 1
}

check_docker_default() {
  if ! command -v docker >/dev/null 2>&1; then
    print_docker_ce_install_guidance
    return 1
  fi

  check_docker_ce_packages || return 1

  if ! docker_info >/dev/null 2>&1; then
    print_docker_daemon_guidance
    return 1
  fi
}

validate_noble_host

log "Ubuntu Noble target architecture: ${TARGET_ARCH}"
if [[ -n "${NOBLE_NATIVE_ARCH:-}" ]]; then
  log "Ubuntu Noble native architecture: ${NOBLE_NATIVE_ARCH}"
fi
warn_if_non_native_target

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

# Default mode must avoid sudo side effects; provision mode verifies via sudo.
if [[ "${PROVISION}" -eq 1 ]]; then
  DOCKER_COMMAND=("${SUDO[@]}" docker)
else
  DOCKER_COMMAND=(docker)
fi

if [[ "${PROVISION}" -eq 1 ]]; then
  provision_core_dependencies
fi

check_core_dependencies || die "missing core build dependencies"

if [[ "${PROVISION}" -eq 1 ]]; then
  provision_docker_ce
  check_docker_provisioned || die "Docker daemon is unavailable after Docker CE provisioning"
else
  check_docker_default || die "Docker CE is unavailable"
fi

ensure_debian_dscverify_keyrings || die "Debian dscverify keyrings are unavailable"
ensure_sbuild_group || die "sbuild group membership is not active"
ensure_sbuild_chroot || die "sbuild chroot is unavailable"

cd -- "${REPO_ROOT}"

log "noble-auto-build foundation ready: TARGET_ARCH=${TARGET_ARCH} mirror=${NOBLE_AUTO_BUILD_MIRROR} provision=${PROVISION} sudo=${sudo_mode}"
run_noble_build
print_noble_artifacts
