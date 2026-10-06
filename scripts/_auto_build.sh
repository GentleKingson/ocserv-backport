#!/usr/bin/env bash
# Shared host preparation for the *-auto-build.sh wrappers. Source after
# _common.sh and _dscverify.sh. The wrapper sets, before calling anything here:
#
#   AUTO_BUILD_NAME          wrapper basename, e.g. noble-auto-build
#   AUTO_BUILD_LABEL         short name used in messages, e.g. Noble
#   AUTO_BUILD_DESCRIPTION   host description for --help, e.g. Ubuntu 24.04 Noble
#   AUTO_BUILD_ENV_PREFIX    prefix of <PREFIX>_AUTO_BUILD_* overrides, e.g. NOBLE
#   CORE_PACKAGES            apt packages installed by --provision
#   CORE_COMMANDS            commands that must exist before building
#   SBUILD_CHROOT_SUITE      suite passed to sbuild-createchroot
#   SBUILD_CHROOT_SUFFIX     --chroot-suffix value ("" or "-sbuild")
#   SBUILD_CHROOT_EXTRA_ARGS extra sbuild-createchroot options (array)
#   AUTO_BUILD_MIRROR        archive mirror for sbuild-createchroot
#
# and, after TARGET_ARCH and target paths are resolved, calls
# auto_build_init_privileges and auto_build_prepare_host.
set -euo pipefail

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

# Primary key of the Docker APT repository signing key (docs.docker.com/engine/install).
DOCKER_APT_KEY_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

DEBIAN_DSCVERIFY_REQUIRED_KEY="C6AE83D21C677043DA3DAC97F8643574713C9BAE"
SBUILD_CHROOT_INCLUDE="eatmydata,ccache,gnupg,ca-certificates"

PROVISION=0
ASSUME_YES=0
SUDO=()
DOCKER_COMMAND=()
HOST_ID=""
HOST_CODENAME=""

# auto_build_env <NAME> [default] — value of <PREFIX>_AUTO_BUILD_<NAME>.
auto_build_env() {
  local var="${AUTO_BUILD_ENV_PREFIX}_AUTO_BUILD_$1"
  printf '%s\n' "${!var:-${2:-}}"
}

auto_build_script() {
  printf 'scripts/%s.sh\n' "${AUTO_BUILD_NAME}"
}

auto_build_usage() {
  cat <<EOF
Usage: $(auto_build_script) [--provision] [--yes]

Prepare the ${AUTO_BUILD_DESCRIPTION} auto-build wrapper.

Options:
  --provision  Prepare host build prerequisites before running.
  --yes        Auto-confirm creation of a missing sbuild chroot in --provision mode.
  -h, --help   Show this help.
EOF
}

auto_build_parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --provision)
        PROVISION=1
        ;;
      --yes)
        ASSUME_YES=1
        ;;
      -h|--help)
        auto_build_usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        auto_build_usage >&2
        die "unknown option: $1"
        ;;
      *)
        die "unexpected argument: $1"
        ;;
    esac
    shift
  done

  [[ "$#" -eq 0 ]] || die "unexpected argument: $1"

  if [[ "${ASSUME_YES}" -eq 1 && "${PROVISION}" -ne 1 ]]; then
    auto_build_usage >&2
    die "--yes requires --provision"
  fi
}

# read_host_os — set HOST_ID and HOST_CODENAME from os-release.
read_host_os() {
  local os_release_path required="$1"
  local ID="" VERSION_CODENAME="" UBUNTU_CODENAME=""

  os_release_path="$(auto_build_env OS_RELEASE_PATH /etc/os-release)"
  [[ -r "${os_release_path}" ]] || die "requires ${required}; cannot read ${os_release_path}"

  # shellcheck source=/etc/os-release disable=SC1091
  . "${os_release_path}"

  HOST_ID="${ID:-}"
  if [[ "${HOST_ID}" == "ubuntu" ]]; then
    HOST_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  else
    HOST_CODENAME="${VERSION_CODENAME:-}"
  fi
}

# auto_build_init_privileges — set SUDO, SUDO_MODE (for logs) and
# DOCKER_COMMAND. Default mode must avoid sudo side effects; provision mode
# verifies via sudo.
# shellcheck disable=SC2034 # SUDO_MODE is read by the wrapper scripts
auto_build_init_privileges() {
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=()
    SUDO_MODE="root"
  else
    SUDO=(sudo)
    SUDO_MODE="${SUDO[*]}"
  fi

  if [[ "${PROVISION}" -eq 1 ]]; then
    DOCKER_COMMAND=("${SUDO[@]}" docker)
  else
    DOCKER_COMMAND=(docker)
  fi
}

sudo_prefix() {
  if [[ "${#SUDO[@]}" -gt 0 ]]; then
    printf '%s ' "${SUDO[*]}"
  fi
}

print_core_install_guidance() {
  local apt_prefix
  apt_prefix="$(sudo_prefix)"

  printf 'Install core build dependencies with:\n' >&2
  printf '  %sapt-get -q=1 -o=Dpkg::Use-Pty=0 update\n' "${apt_prefix}" >&2
  printf '  %sapt-get -q=1 -o=Dpkg::Use-Pty=0 install -y --no-install-recommends' "${apt_prefix}" >&2
  printf ' %s' "${CORE_PACKAGES[@]}" >&2
  printf '\n\n' >&2
  printf 'Or let the wrapper install them with:\n' >&2
  printf '  %s --provision\n' "$(auto_build_script)" >&2
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

provision_core_dependencies() {
  log "installing core build dependencies"
  apt_quiet update
  apt_quiet install -y --no-install-recommends "${CORE_PACKAGES[@]}"
}

print_docker_ce_install_guidance() {
  printf 'Docker CE is required for the %s auto-build wrapper.\n' "${AUTO_BUILD_LABEL}" >&2
  printf 'Install Docker CE from the official Docker APT repository at download.docker.com, then install:\n' >&2
  printf '  %s\n' "${DOCKER_CE_PACKAGES[*]}" >&2
}

print_docker_daemon_guidance() {
  printf 'Docker is installed, but the Docker daemon is not reachable.\n' >&2
  printf 'Start it and verify access with:\n' >&2
  printf '  sudo systemctl enable --now docker\n' >&2
  printf '  sudo docker info\n' >&2
}

docker_info() {
  "${DOCKER_COMMAND[@]}" info
}

docker_command_for_make() {
  local IFS=" "
  printf '%s\n' "${DOCKER_COMMAND[*]}"
}

print_docker_mix_guidance() {
  log "Do not mix distro Docker packages with Docker CE/containerd.io"
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

installed_docker_conflicts() {
  local package

  for package in "${DOCKER_CONFLICT_PACKAGES[@]}"; do
    if package_is_installed "${package}"; then
      printf '%s\n' "${package}"
    fi
  done
}

check_docker_ce_packages() {
  local package missing_count=0 conflict_count=0

  while IFS= read -r package; do
    [[ -n "${package}" ]] || continue
    log "conflicting distro Docker package installed: ${package}"
    conflict_count=$((conflict_count + 1))
  done < <(installed_docker_conflicts)

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
}

docker_keyring_path() {
  auto_build_env DOCKER_KEYRING_PATH /etc/apt/keyrings/docker.asc
}

docker_source_path() {
  auto_build_env DOCKER_SOURCE_PATH /etc/apt/sources.list.d/docker.sources
}

docker_repo_os() {
  case "${HOST_ID}:${HOST_CODENAME}" in
    debian:trixie)
      printf '%s\n' "debian"
      ;;
    ubuntu:noble)
      printf '%s\n' "ubuntu"
      ;;
    *)
      die "unsupported Docker CE host: ${HOST_ID:-unknown}:${HOST_CODENAME:-unknown}"
      ;;
  esac
}

write_docker_apt_source() {
  local arch="$1"
  local keyring_path="$2"
  local source_path="$3"

  {
    printf 'Types: deb\n'
    printf 'URIs: https://download.docker.com/linux/%s\n' "$(docker_repo_os)"
    printf 'Suites: %s\n' "${HOST_CODENAME}"
    printf 'Components: stable\n'
    printf 'Signed-By: %s\n' "${keyring_path}"
    printf 'Architectures: %s\n' "${arch}"
  } | "${SUDO[@]}" tee "${source_path}" >/dev/null
}

remove_installed_docker_conflicts() {
  local package
  local -a installed_conflicts=()

  while IFS= read -r package; do
    [[ -n "${package}" ]] || continue
    installed_conflicts+=("${package}")
  done < <(installed_docker_conflicts)

  if [[ "${#installed_conflicts[@]}" -gt 0 ]]; then
    apt_quiet remove -y "${installed_conflicts[@]}"
  fi
}

install_docker_ce_packages() {
  local install_output

  if ! install_output="$(apt_quiet_capture install -y "${DOCKER_CE_PACKAGES[@]}")"; then
    printf '%s\n' "${install_output}" >&2
    if [[ "${install_output}" == *"containerd.io : Conflicts: containerd"* ]]; then
      log "Do not mix distro Docker packages with Docker CE/containerd.io"
    fi
    return 1
  fi
}

# Print the primary-key fingerprints in a key file, one per line.
docker_key_primary_fingerprints() {
  local key_path="$1" line want_fpr=0
  local -a fields

  while IFS= read -r line; do
    IFS=':' read -r -a fields <<< "${line}"
    case "${fields[0]:-}" in
      pub)
        want_fpr=1
        ;;
      fpr)
        if [[ "${want_fpr}" -eq 1 ]]; then
          printf '%s\n' "${fields[9]:-}"
        fi
        want_fpr=0
        ;;
      *)
        want_fpr=0
        ;;
    esac
  done < <(dscverify_with_temp_gnupghome gpg --batch --with-colons --show-keys "${key_path}" 2>/dev/null)
}

# Accept the downloaded key only if it holds exactly the pinned primary key.
verify_docker_apt_key() {
  local key_path="$1" fingerprints

  fingerprints="$(docker_key_primary_fingerprints "${key_path}")"
  if [[ "${fingerprints}" != "${DOCKER_APT_KEY_FINGERPRINT}" ]]; then
    log "Docker APT key ${key_path} does not match pinned fingerprint ${DOCKER_APT_KEY_FINGERPRINT}"
    log "found primary key fingerprints: ${fingerprints:-none}"
    "${SUDO[@]}" rm -f -- "${key_path}"
    return 1
  fi
}

provision_docker_ce() {
  local keyring_path source_path repo_os

  repo_os="$(docker_repo_os)"
  log "installing Docker CE from the official Docker ${repo_os} repository"
  keyring_path="$(docker_keyring_path)"
  source_path="$(docker_source_path)"

  remove_installed_docker_conflicts
  apt_quiet update
  apt_quiet install -y --no-install-recommends ca-certificates curl
  "${SUDO[@]}" install -m 0755 -d "$(dirname -- "${keyring_path}")"
  "${SUDO[@]}" curl -fsSL "https://download.docker.com/linux/${repo_os}/gpg" -o "${keyring_path}"
  "${SUDO[@]}" chmod a+r "${keyring_path}"
  verify_docker_apt_key "${keyring_path}" || return 1
  "${SUDO[@]}" install -m 0755 -d "$(dirname -- "${source_path}")"
  write_docker_apt_source "${HOST_ARCH}" "${keyring_path}" "${source_path}"
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

check_debian_dscverify_keyrings() {
  local keyring readable_count=0 required_key_found=0

  while IFS= read -r keyring; do
    [[ -n "${keyring}" ]] || continue
    if [[ -r "${keyring}" ]]; then
      log "using Debian dscverify keyring: ${keyring}"
      readable_count=$((readable_count + 1))
      if dscverify_keyring_contains_key "${keyring}" "${DEBIAN_DSCVERIFY_REQUIRED_KEY}"; then
        required_key_found=1
      fi
    fi
  done < <(dscverify_candidate_keyrings)

  if [[ "${readable_count}" -eq 0 ]]; then
    log "no readable Debian dscverify keyrings found."
    log "Install them with: sudo apt-get install -y --no-install-recommends debian-keyring"
    return 1
  fi

  if [[ "${required_key_found}" -ne 1 ]]; then
    log "required Debian source signing key not found in dscverify keyrings: ${DEBIAN_DSCVERIFY_REQUIRED_KEY}"
    log "Run $(auto_build_script) --provision without DSCVERIFY_KEYRING_PATHS to refresh keyrings automatically."
    return 1
  fi
}

refresh_debian_dscverify_keyrings() {
  local keyring_root keyring_image keyring_path host_uid host_gid
  local -a keyrings=()

  keyring_root="$(auto_build_env DSCVERIFY_KEYRING_ROOT "${TARGET_DEBIAN_KEYRING_DIR}")"
  keyring_image="$(auto_build_env KEYRING_IMAGE debian:sid)"
  host_uid="$(id -u)"
  host_gid="$(id -g)"
  log "refreshing Debian dscverify keyrings from ${keyring_image}"
  rm -rf -- "${keyring_root}" || return 1
  mkdir -p "${keyring_root}" || return 1

  # The script passed to bash -c must expand HOST_UID/HOST_GID inside the
  # Debian container, not in the host shell.
  # shellcheck disable=SC2016
  "${DOCKER_COMMAND[@]}" run --rm \
    -v "${keyring_root}:/out" \
    -e "HOST_UID=${host_uid}" \
    -e "HOST_GID=${host_gid}" \
    "${keyring_image}" \
    bash -euxc '
      workdir="$(mktemp -d)"
      cd "${workdir}"
      apt-get update
      apt-get download debian-archive-keyring debian-keyring
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
    log "no Debian keyrings extracted from ${keyring_image}"
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
  printf '  %s --provision\n' "$(auto_build_script)" >&2
}

print_sbuild_group_rerun_guidance() {
  printf 'The current shell does not have the sbuild group yet.\n' >&2
  printf 'Run:\n' >&2
  printf '  newgrp sbuild\n' >&2
  printf '  %s --provision\n' "$(auto_build_script)" >&2
  printf 'Then rerun %s --provision from that shell.\n' "$(auto_build_script)" >&2
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

  if [[ "$(auto_build_env SKIP_NEWGRP 0)" == 1 ]]; then
    return 1
  fi

  if [[ -t 0 && -t 1 ]]; then
    log "starting a new shell with the sbuild group active"
    exec newgrp sbuild
  fi

  return 1
}

sbuild_chroot_name() {
  printf '%s-%s%s\n' "${SBUILD_CHROOT_SUITE}" "${TARGET_ARCH}" "${SBUILD_CHROOT_SUFFIX}"
}

sbuild_chroot_path() {
  printf '%s/%s\n' "$(auto_build_env CHROOT_BASE /srv/chroot)" "$(sbuild_chroot_name)"
}

sbuild_createchroot_args() {
  printf '%s\n' \
    "--arch=${TARGET_ARCH}" \
    "--chroot-suffix=${SBUILD_CHROOT_SUFFIX}" \
    "${SBUILD_CHROOT_EXTRA_ARGS[@]}" \
    "--include=${SBUILD_CHROOT_INCLUDE}" \
    "${SBUILD_CHROOT_SUITE}" \
    "$(sbuild_chroot_path)" \
    "${AUTO_BUILD_MIRROR}"
}

print_sbuild_createchroot_command() {
  local -a args=()
  local arg

  while IFS= read -r arg; do
    args+=("${arg}")
  done < <(sbuild_createchroot_args)
  printf '  sudo sbuild-createchroot %s\n' "${args[*]}" >&2
}

print_existing_sbuild_chroot_path_guidance() {
  local chroot_path="$1"

  log "sbuild chroot path exists but is not registered: ${chroot_path}"
  printf 'The directory already exists, but schroot/sbuild does not list %s.\n' "$(sbuild_chroot_name)" >&2
  printf 'If this is a failed chroot creation attempt, review the path and remove it manually before retrying:\n' >&2
  printf '  %srm -rf %s\n' "$(sudo_prefix)" "${chroot_path}" >&2
  printf '  %s --provision\n' "$(auto_build_script)" >&2
}

print_unusable_sbuild_chroot_guidance() {
  local target="$1"
  local session_output="$2"

  log "sbuild chroot is registered but unusable: ${target}"
  if [[ -n "${session_output}" ]]; then
    printf '%s\n' "${session_output}" >&2
  fi
  printf 'Check the registered chroot and backing directory:\n' >&2
  printf '  %sls -ld %s\n' "$(sudo_prefix)" "$(sbuild_chroot_path)" >&2
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
  local answer target arg
  local -a args=()

  target="$(sbuild_chroot_name)"
  print_missing_sbuild_chroot_guidance

  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    log "creating missing sbuild chroot because --yes was provided: ${target}"
  else
    printf 'Type yes to create this chroot now: ' >&2
    IFS= read -r answer || answer=""

    if [[ "${answer}" != "yes" ]]; then
      log "sbuild chroot creation cancelled; rerun after creating ${target}"
      return 1
    fi
  fi

  while IFS= read -r arg; do
    args+=("${arg}")
  done < <(sbuild_createchroot_args)

  "${SUDO[@]}" sbuild-createchroot "${args[@]}"

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

# auto_build_prepare_host — install (with --provision) or check everything
# the build needs: core tools, Docker CE, dscverify keyrings, sbuild group
# membership and the target sbuild chroot.
auto_build_prepare_host() {
  if [[ "${PROVISION}" -eq 1 ]]; then
    provision_core_dependencies
  fi

  check_core_dependencies || die "missing core build dependencies"

  if [[ "${PROVISION}" -eq 1 ]]; then
    provision_docker_ce || die "Docker CE provisioning failed"
    check_docker_provisioned || die "Docker daemon is unavailable after Docker CE provisioning"
  else
    check_docker_default || die "Docker CE is unavailable"
  fi

  ensure_debian_dscverify_keyrings || die "Debian dscverify keyrings are unavailable"
  ensure_sbuild_group || die "sbuild group membership is not active"
  ensure_sbuild_chroot || die "sbuild chroot is unavailable"
}

# print_build_artifacts <label> <glob>... — list every match; fail on a
# pattern with no match.
print_build_artifacts() {
  local label="$1" artifact pattern
  local -a artifacts=() matches=()
  shift

  for pattern in "$@"; do
    matches=()
    while IFS= read -r artifact; do
      matches+=("${artifact}")
    done < <(compgen -G "${pattern}" || true)
    if [[ "${#matches[@]}" -eq 0 ]]; then
      die "expected artifact not found: ${pattern}"
    fi
    artifacts+=("${matches[@]}")
  done

  log "${label} artifacts:"
  printf '%s\n' "${artifacts[@]}"
}
