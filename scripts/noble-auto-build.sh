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
  printf '%s\n' "${DOCKER_COMMAND[@]}"
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

  if ! install_output="$("${SUDO[@]}" apt-get install -y "${DOCKER_CE_PACKAGES[@]}" 2>&1)"; then
    printf '%s\n' "${install_output}" >&2
    if [[ "${install_output}" == *"containerd.io : Conflicts: containerd"* ]]; then
      log "Do not mix Ubuntu docker.io/containerd with Docker CE/containerd.io"
    fi
    return 1
  fi

  if [[ -n "${install_output}" ]]; then
    printf '%s\n' "${install_output}" >&2
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

  "${SUDO[@]}" apt-get remove -y "${DOCKER_CONFLICT_PACKAGES[@]}"
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y --no-install-recommends ca-certificates curl
  "${SUDO[@]}" install -m 0755 -d "${keyring_dir}"
  "${SUDO[@]}" curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "${keyring_path}"
  "${SUDO[@]}" chmod a+r "${keyring_path}"
  "${SUDO[@]}" install -m 0755 -d "${source_dir}"
  write_docker_apt_source "${arch}" "${keyring_path}" "${source_path}"
  "${SUDO[@]}" apt-get update
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

# Default mode must avoid sudo side effects; provision mode verifies via sudo.
if [[ "${PROVISION}" -eq 1 ]]; then
  DOCKER_COMMAND=("${SUDO[@]}" docker)
else
  DOCKER_COMMAND=(docker)
fi

if [[ "${PROVISION}" -eq 1 ]]; then
  provision_core_dependencies
  provision_docker_ce
fi

check_core_dependencies || die "missing core build dependencies"
check_debian_dscverify_keyrings || die "missing readable Debian dscverify keyring"
if [[ "${PROVISION}" -eq 1 ]]; then
  check_docker_provisioned || die "Docker daemon is unavailable after Docker CE provisioning"
else
  check_docker_default || die "Docker CE is unavailable"
fi

cd -- "${REPO_ROOT}"

log "noble-auto-build foundation ready: TARGET_ARCH=${TARGET_ARCH} mirror=${NOBLE_AUTO_BUILD_MIRROR} provision=${PROVISION} sudo=${sudo_mode}"
