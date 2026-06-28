#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"
noble_package_vars ocserv

read -r -a DOCKER_COMMAND <<< "${NOBLE_DOCKER_CMD:-docker}"
[[ "${#DOCKER_COMMAND[@]}" -gt 0 ]] || die "NOBLE_DOCKER_CMD must not be empty"

if [[ "${1:-}" == "basic" ]]; then
  shift
fi
[[ "$#" -eq 0 ]] || die "usage: noble-smoke-test.sh"

shopt -s nullglob
ocserv_debs=("${PKG_BINARY_DIR}"/ocserv_*_"${TARGET_ARCH}".deb)
runtime_debs=("${NOBLE_REPO_DIR}"/libllhttp9.2_*.deb)
shopt -u nullglob

[[ "${#ocserv_debs[@]}" -eq 1 ]] || die "expected exactly one ocserv ${TARGET_ARCH} .deb in ${PKG_BINARY_DIR} (found ${#ocserv_debs[@]})"
[[ "${#runtime_debs[@]}" -eq 1 ]] || die "expected exactly one libllhttp9.2 .deb in ${NOBLE_REPO_DIR} (found ${#runtime_debs[@]})"

DEB="${ocserv_debs[0]}"
pkg="$(dpkg-deb -f "${DEB}" Package)"
version="$(dpkg-deb -f "${DEB}" Version)"
arch="$(dpkg-deb -f "${DEB}" Architecture)"
depends="$(dpkg-deb -f "${DEB}" Depends)"
[[ "${pkg}" == "ocserv" ]] || die "deb Package ${pkg} != ocserv"
[[ "${version}" == "${OCSERV_NOBLE_VERSION}" ]] || die "deb Version ${version} != ${OCSERV_NOBLE_VERSION}"
[[ "${arch}" == "${TARGET_ARCH}" ]] || die "deb Architecture ${arch} != ${TARGET_ARCH}"
[[ "${depends}" == *"libllhttp9.2"* ]] || die "ocserv Depends does not include libllhttp9.2: ${depends}"

host_arch="unavailable"
if command -v dpkg >/dev/null 2>&1; then
  host_arch="$(dpkg --print-architecture 2>/dev/null || printf 'unavailable')"
fi
log "noble-smoke-basic: host dpkg architecture: ${host_arch}"

binary_dir="$(cd -- "${PKG_BINARY_DIR}" && pwd)"
repo_dir="$(cd -- "${NOBLE_REPO_DIR}" && pwd)"
deb_name="$(basename "${DEB}")"

log "noble-smoke-basic: container install and package assertions"
# shellcheck disable=SC2016
"${DOCKER_COMMAND[@]}" run --rm -v "${binary_dir}:/deb:ro" -v "${repo_dir}:/repo:ro" ubuntu:24.04 bash -euxc '
  deb="/deb/$1"
  expected_version="$2"
  expected_arch="$3"

  echo "deb [trusted=yes] file:/repo ./" > /etc/apt/sources.list.d/local-libllhttp.list
  apt-get update -qq
  apt-get install -s -y "${deb}" | tee /tmp/ocserv-install-plan
  grep -q "libllhttp9.2" /tmp/ocserv-install-plan
  apt-get install -y -qq "${deb}"

  installed_version="$(dpkg-query -W -f="\${Version}" ocserv)"
  installed_arch="$(dpkg-query -W -f="\${Architecture}" ocserv)"
  test "${installed_version}" = "${expected_version}"
  test "${installed_arch}" = "${expected_arch}"

  test -x /usr/sbin/ocserv
  version_output="$(ocserv --version 2>&1 || true)"
  printf "%s\n" "${version_output}"
  printf "%s\n" "${version_output}" | grep -F "1.5.0"

  set +e
  ocserv -c /etc/ocserv/ocserv.conf -t >/tmp/ocserv-config-test 2>&1
  config_status="$?"
  set -e
  if grep -qi "invalid option" /tmp/ocserv-config-test; then
    cat /tmp/ocserv-config-test >&2
    exit 1
  fi
  if [ "${config_status}" -ne 0 ]; then
    cat /tmp/ocserv-config-test >&2
    echo "ocserv config test command exists, but the default smoke config did not pass" >&2
  fi
  if ldd /usr/sbin/ocserv | grep -i "not found"; then
    exit 1
  fi
' bash "${deb_name}" "${OCSERV_NOBLE_VERSION}" "${TARGET_ARCH}"

log "noble-smoke-basic: OK"
