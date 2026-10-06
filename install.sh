#!/usr/bin/env bash
# Install the latest ocserv backport package from the GitHub releases of
# GentleKingson/ocserv-backport.
#
#   curl -fsSL https://raw.githubusercontent.com/GentleKingson/ocserv-backport/main/install.sh | sudo bash
#
# The script detects the distribution and architecture, downloads the matching
# .deb from the release together with SHA256SUMS, verifies the checksum,
# installs the package with apt and enables ocserv.service. It does not start
# ocserv: edit /etc/ocserv/ocserv.conf first, then run
# `systemctl start ocserv`.
#
# Supported systems: Debian 13 (trixie) and Ubuntu 24.04 (noble), amd64 and
# arm64.
#
# Pass options through the pipe with `sudo bash -s -- <options>`; see --help.
# OCSERV_RELEASE, OCSERV_REPO and OCSERV_DOWNLOAD_ONLY=1 set the same options
# from the environment.
#
# Everything lives in functions and main runs on the last line, so a partial
# download through a pipe never runs half a script. Tests set
# OCSERV_INSTALL_SOURCE_ONLY=1 and source the file to call single functions.
set -euo pipefail

OCSERV_REPO="${OCSERV_REPO:-GentleKingson/ocserv-backport}"
OCSERV_RELEASE="${OCSERV_RELEASE:-}"
OCSERV_DOWNLOAD_ONLY="${OCSERV_DOWNLOAD_ONLY:-0}"
# Test hooks: a mirror of https://github.com and another os-release file.
OCSERV_GITHUB_URL="${OCSERV_GITHUB_URL:-https://github.com}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

POLICY_RC_D=/usr/sbin/policy-rc.d
POLICY_RC_D_BACKUP=""
POLICY_RC_D_INSTALLED=0
WORK_DIR=""

log() {
  printf '[ocserv-install] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat << 'USAGE'
Usage: install.sh [--release <tag>] [--repo <owner/repo>] [--download-only]

Install the latest ocserv backport release for Debian 13 or Ubuntu 24.04
(amd64, arm64) and enable ocserv.service without starting it.

  --release <tag>   Install this release instead of the latest.
  --repo <o/r>      Download from another GitHub repository.
  --download-only   Download and verify the package into the current
                    directory, do not install it.
  -h, --help        Show this help.
USAGE
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --release)
        [[ $# -ge 2 && -n "$2" ]] || die "--release needs a tag"
        OCSERV_RELEASE="$2"
        shift 2
        ;;
      --release=*)
        OCSERV_RELEASE="${1#*=}"
        shift
        ;;
      --repo)
        [[ $# -ge 2 && -n "$2" ]] || die "--repo needs owner/repo"
        OCSERV_REPO="$2"
        shift 2
        ;;
      --repo=*)
        OCSERV_REPO="${1#*=}"
        shift
        ;;
      --download-only)
        OCSERV_DOWNLOAD_ONLY=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1 (see --help)"
        ;;
    esac
  done
  [[ "${OCSERV_REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "invalid repository: ${OCSERV_REPO}"
  [[ -z "${OCSERV_RELEASE}" || "${OCSERV_RELEASE}" =~ ^[A-Za-z0-9_.+-]+$ ]] \
    || die "invalid release tag: ${OCSERV_RELEASE}"
}

# Print the asset suffix for this system: debian13 or ubuntu24.04.
detect_distro() {
  [[ -r "${OS_RELEASE_FILE}" ]] || die "cannot read ${OS_RELEASE_FILE}"
  local id version_id pretty
  {
    read -r id
    read -r version_id
    IFS= read -r pretty
  } < <(
    # shellcheck source=/dev/null
    . "${OS_RELEASE_FILE}"
    printf '%s\n%s\n%s\n' "${ID:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-${ID:-unknown}${VERSION_ID:+ ${VERSION_ID}}}"
  )

  case "${id}:${version_id}" in
    debian:13) printf 'debian13\n' ;;
    ubuntu:24.04) printf 'ubuntu24.04\n' ;;
    *) die "unsupported system: ${pretty}; supported: Debian 13 (trixie), Ubuntu 24.04 (noble)" ;;
  esac
}

detect_arch() {
  command -v dpkg > /dev/null 2>&1 || die "dpkg not found; only Debian and Ubuntu are supported"
  local arch
  arch="$(dpkg --print-architecture)"
  case "${arch}" in
    amd64 | arm64) printf '%s\n' "${arch}" ;;
    *) die "unsupported architecture: ${arch}; supported: amd64, arm64" ;;
  esac
}

ensure_downloader() {
  command -v curl > /dev/null 2>&1 && return 0
  [[ "${EUID}" -eq 0 ]] || die "curl not found"
  log "curl not found, installing curl and ca-certificates"
  apt-get update -qq < /dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    curl ca-certificates < /dev/null
}

download() {
  local url="$1" out="$2"
  curl -fsSL --retry 3 --retry-delay 2 --proto '=https,http' -o "${out}" "${url}" \
    || die "download failed: ${url}"
}

# The latest release redirects to .../releases/tag/<tag>; resolving the tag
# first keeps SHA256SUMS and the .deb from the same release.
resolve_release() {
  if [[ -n "${OCSERV_RELEASE}" ]]; then
    printf '%s\n' "${OCSERV_RELEASE}"
    return 0
  fi
  local url effective tag
  url="${OCSERV_GITHUB_URL}/${OCSERV_REPO}/releases/latest"
  effective="$(curl -fsSL --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' "${url}")" \
    || die "cannot find the latest release of ${OCSERV_REPO}"
  tag="${effective##*/releases/tag/}"
  [[ "${tag}" != "${effective}" && "${tag}" =~ ^[A-Za-z0-9_.+-]+$ ]] \
    || die "cannot find the latest release of ${OCSERV_REPO} (got ${effective})"
  printf '%s\n' "${tag}"
}

# Print the single package name in SHA256SUMS for the distro and arch.
# Release asset names use "." where the package version has "~":
#   ocserv_1.5.0-1.debian13.2_amd64.deb
select_asset() {
  local sums="$1" distro="$2" arch="$3"
  local -a matches=()
  local name
  while read -r _ name; do
    name="${name#\*}"
    if [[ "${name}" == ocserv_*".${distro}."*"_${arch}.deb" ]]; then
      matches+=("${name}")
    fi
  done < "${sums}"
  ((${#matches[@]} == 1)) \
    || die "expected one ocserv package for ${distro} ${arch} in SHA256SUMS, found ${#matches[@]}"
  printf '%s\n' "${matches[0]}"
}

# Keep maintainer scripts from starting ocserv while the package installs
# (invoke-rc.d and deb-systemd-invoke both honor policy-rc.d). Other services,
# such as newly installed dependencies, go to the original policy if any.
block_service_start() {
  local delegate="exit 0"
  if [[ -e "${POLICY_RC_D}" || -L "${POLICY_RC_D}" ]]; then
    POLICY_RC_D_BACKUP="${WORK_DIR}/policy-rc.d.orig"
    mv -- "${POLICY_RC_D}" "${POLICY_RC_D_BACKUP}"
    delegate="exec '${POLICY_RC_D_BACKUP}' \"\$@\""
  fi
  cat > "${POLICY_RC_D}" << POLICY
#!/bin/sh
# Written by ocserv install.sh; removed when the install finishes.
case "\$1" in
  ocserv | ocserv.service) exit 101 ;;
esac
${delegate}
POLICY
  chmod 0755 "${POLICY_RC_D}"
  POLICY_RC_D_INSTALLED=1
}

restore_service_start() {
  ((POLICY_RC_D_INSTALLED == 1)) || return 0
  rm -f -- "${POLICY_RC_D}"
  if [[ -n "${POLICY_RC_D_BACKUP}" ]]; then
    mv -- "${POLICY_RC_D_BACKUP}" "${POLICY_RC_D}"
    POLICY_RC_D_BACKUP=""
  fi
  POLICY_RC_D_INSTALLED=0
}

cleanup() {
  restore_service_start
  if [[ -n "${WORK_DIR}" ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
}

systemd_running() {
  [[ -d /run/systemd/system ]]
}

install_package() {
  local deb="$1"
  log "installing $(basename -- "${deb}")"
  block_service_start
  apt-get update -qq < /dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    "${deb}" < /dev/null
  restore_service_start
}

enable_service() {
  command -v systemctl > /dev/null 2>&1 || die "systemctl not found; ocserv needs systemd"
  systemctl enable ocserv.service
}

main() {
  parse_args "$@"
  [[ "${EUID}" -eq 0 || "${OCSERV_DOWNLOAD_ONLY}" == 1 ]] \
    || die "run as root, for example: curl -fsSL <url> | sudo bash"

  local distro arch tag base asset version was_active=0
  distro="$(detect_distro)"
  arch="$(detect_arch)"
  log "detected ${distro} ${arch}"

  ensure_downloader
  tag="$(resolve_release)"
  log "using release ${tag} from ${OCSERV_REPO}"
  base="${OCSERV_GITHUB_URL}/${OCSERV_REPO}/releases/download/${tag}"

  WORK_DIR="$(mktemp -d)"
  chmod 0755 "${WORK_DIR}"
  trap cleanup EXIT

  download "${base}/SHA256SUMS" "${WORK_DIR}/SHA256SUMS"
  asset="$(select_asset "${WORK_DIR}/SHA256SUMS" "${distro}" "${arch}")"
  download "${base}/${asset}" "${WORK_DIR}/${asset}"
  (cd "${WORK_DIR}" && awk -v n="${asset}" '$2 == n || $2 == "*" n' SHA256SUMS \
    | sha256sum -c --strict -) > /dev/null \
    || die "checksum mismatch for ${asset}"
  log "verified ${asset}"

  if [[ "${OCSERV_DOWNLOAD_ONLY}" == 1 ]]; then
    cp -- "${WORK_DIR}/${asset}" "./${asset}"
    log "downloaded ./${asset}"
    return 0
  fi

  if systemd_running && systemctl is-active --quiet ocserv.service; then
    was_active=1
  fi

  install_package "${WORK_DIR}/${asset}"
  enable_service

  # Belt and braces: leave a fresh install stopped even if something started it.
  if systemd_running && ((was_active == 0)) && systemctl is-active --quiet ocserv.service; then
    systemctl stop ocserv.service
  fi

  # shellcheck disable=SC2016 # ${Version} is a dpkg-query field.
  version="$(dpkg-query -W -f='${Version}' ocserv)"
  if ((was_active == 1)); then
    log "installed ocserv ${version}; ocserv.service is enabled"
    log "ocserv is still running the old version; run 'systemctl restart ocserv' to use ${version}"
  else
    log "installed ocserv ${version}; ocserv.service is enabled but not started"
    log "next: edit /etc/ocserv/ocserv.conf, then run 'systemctl start ocserv'"
  fi
}

if [[ "${OCSERV_INSTALL_SOURCE_ONLY:-0}" != 1 ]]; then
  main "$@"
fi
