#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~debian13.1}"
TARGET_FAMILY="${TARGET_FAMILY:-debian}"
TARGET_SUITE="${TARGET_SUITE:-trixie}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
# shellcheck source=scripts/_target_paths.sh
. "${SCRIPT_DIR}/_target_paths.sh"
[[ "${TARGET_ARCH}" == "amd64" ]] || die "unsupported TARGET_ARCH=${TARGET_ARCH}; supported architectures: amd64"

read -r -a DOCKER_COMMAND <<< "${DEBIAN_DOCKER_CMD:-docker}"
[[ "${#DOCKER_COMMAND[@]}" -gt 0 ]] || die "DEBIAN_DOCKER_CMD must not be empty"

if [[ "${1:-}" == "basic" ]]; then
  shift
fi
[[ "$#" -eq 0 ]] || die "usage: smoke-test.sh"

debs=()
while IFS= read -r -d '' deb; do
  debs+=("${deb}")
done < <(find "${TARGET_BINARY_ROOT}" -maxdepth 1 -type f -name "ocserv_*_${TARGET_ARCH}.deb" -print0)

[[ "${#debs[@]}" -eq 1 ]] || die "expected exactly one ocserv ${TARGET_ARCH} .deb in ${TARGET_BINARY_ROOT} (found ${#debs[@]})"
DEB="${debs[0]}"

pkg="$(dpkg-deb -f "${DEB}" Package)"
version="$(dpkg-deb -f "${DEB}" Version)"
arch="$(dpkg-deb -f "${DEB}" Architecture)"
[[ "${pkg}" == "ocserv" ]] || die "deb Package ${pkg} != ocserv"
[[ "${version}" == "${BACKPORT_VERSION}" ]] || die "deb Version ${version} != ${BACKPORT_VERSION}"
[[ "${arch}" == "${TARGET_ARCH}" ]] || die "deb Architecture ${arch} != ${TARGET_ARCH}"

binary_dir="$(cd -- "$(dirname -- "${DEB}")" && pwd)"
deb_name="$(basename "${DEB}")"

log "smoke-basic: container install and package assertions"
# shellcheck disable=SC2016
"${DOCKER_COMMAND[@]}" run --rm -v "${binary_dir}:/deb:ro" debian:trixie bash -euxc '
  deb="/deb/$1"
  expected_version="$2"
  expected_arch="$3"

  apt-get update -qq
  apt-get install -y -qq "${deb}"

  installed_version="$(dpkg-query -W -f="\${Version}" ocserv)"
  installed_arch="$(dpkg-query -W -f="\${Architecture}" ocserv)"
  test "${installed_version}" = "${expected_version}"
  test "${installed_arch}" = "${expected_arch}"

  test -x /usr/sbin/ocserv
  test -x /usr/bin/occtl
  ocserv --version >/dev/null
  if ! occtl --version >/dev/null 2>&1; then
    occtl --help >/dev/null
  fi

  if ldd /usr/sbin/ocserv | grep -i "not found"; then
    exit 1
  fi
  if ldd /usr/bin/occtl | grep -i "not found"; then
    exit 1
  fi

  test -f /lib/systemd/system/ocserv.service || test -f /usr/lib/systemd/system/ocserv.service
  test -f /etc/ocserv/ocserv.conf || test -f /usr/share/doc/ocserv/ocserv.conf
  test -d /usr/share/doc/ocserv
' bash "${deb_name}" "${BACKPORT_VERSION}" "${TARGET_ARCH}"

log "smoke-basic: OK"
