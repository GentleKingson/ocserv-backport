#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/ubuntu-env.sh
. "${SCRIPT_DIR}/ubuntu-env.sh"
ubuntu_package_vars ocserv

suite_docker_var="${UBUNTU_ENV_PREFIX}_DOCKER_CMD"
docker_cmd_spec="${!suite_docker_var:-${UBUNTU_DOCKER_CMD:-docker}}"
read -r -a DOCKER_COMMAND <<< "${docker_cmd_spec}"
[[ "${#DOCKER_COMMAND[@]}" -gt 0 ]] || die "${suite_docker_var} must not be empty"

if [[ "${1:-}" == "basic" ]]; then
  shift
fi
[[ "$#" -eq 0 ]] || die "usage: ubuntu-smoke-test.sh"

shopt -s nullglob
ocserv_debs=("${PKG_BINARY_DIR}"/ocserv_*_"${TARGET_ARCH}".deb)
shopt -u nullglob

[[ "${#ocserv_debs[@]}" -eq 1 ]] || die "expected exactly one ocserv ${TARGET_ARCH} .deb in ${PKG_BINARY_DIR} (found ${#ocserv_debs[@]})"

DEB="${ocserv_debs[0]}"
pkg="$(dpkg-deb -f "${DEB}" Package)"
version="$(dpkg-deb -f "${DEB}" Version)"
arch="$(dpkg-deb -f "${DEB}" Architecture)"
depends="$(dpkg-deb -f "${DEB}" Depends)"
[[ "${pkg}" == "ocserv" ]] || die "deb Package ${pkg} != ocserv"
[[ "${version}" == "${PKG_UBUNTU_VERSION}" ]] || die "deb Version ${version} != ${PKG_UBUNTU_VERSION}"
[[ "${arch}" == "${TARGET_ARCH}" ]] || die "deb Architecture ${arch} != ${TARGET_ARCH}"
if [[ "${UBUNTU_BUNDLED_LLHTTP}" == "1" ]]; then
  # ocserv is built with its bundled llhttp; this suite has no libllhttp package.
  [[ "${depends}" != *"libllhttp"* ]] || die "ocserv Depends unexpectedly includes libllhttp: ${depends}"
fi

host_arch="unavailable"
if command -v dpkg >/dev/null 2>&1; then
  host_arch="$(dpkg --print-architecture 2>/dev/null || printf 'unavailable')"
fi
log "${TARGET_SUITE}-smoke-basic: host dpkg architecture: ${host_arch}"

binary_dir="$(cd -- "${PKG_BINARY_DIR}" && pwd)"
deb_name="$(basename "${DEB}")"

log "${TARGET_SUITE}-smoke-basic: container install and package assertions"
# shellcheck disable=SC2016
"${DOCKER_COMMAND[@]}" run --rm -v "${binary_dir}:/deb:ro" "${UBUNTU_DOCKER_IMAGE}" bash -euxc '
  deb="/deb/$1"
  expected_version="$2"
  expected_arch="$3"
  expected_upstream="$4"
  bundled_llhttp="$5"

  apt-get update -qq
  apt-get install -s -y "${deb}" | tee /tmp/ocserv-install-plan
  if [ "${bundled_llhttp}" = "1" ] && grep -q "libllhttp" /tmp/ocserv-install-plan; then
    exit 1
  fi
  apt-get install -y -qq "${deb}"

  installed_version="$(dpkg-query -W -f="\${Version}" ocserv)"
  installed_arch="$(dpkg-query -W -f="\${Architecture}" ocserv)"
  test "${installed_version}" = "${expected_version}"
  test "${installed_arch}" = "${expected_arch}"

  test -x /usr/sbin/ocserv
  version_output="$(ocserv --version 2>&1 || true)"
  printf "%s\n" "${version_output}"
  printf "%s\n" "${version_output}" | grep -F "${expected_upstream}"

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
  if ldd /usr/sbin/ocserv /usr/sbin/ocserv-worker | grep -i "not found"; then
    exit 1
  fi
  if [ "${bundled_llhttp}" = "1" ]; then
    if ldd /usr/sbin/ocserv /usr/sbin/ocserv-worker | grep -i "libllhttp"; then
      exit 1
    fi
  else
    ldd /usr/sbin/ocserv-worker | grep -F "libllhttp"
  fi

  # Build options Debian enables: PAM, RADIUS and OIDC in ocserv, seccomp in
  # the worker. A missing library means the feature was silently built out.
  for lib in libpam.so libradcli.so libcjose.so libcurl-gnutls.so; do
    ldd /usr/sbin/ocserv | grep -F "${lib}"
  done
  ldd /usr/sbin/ocserv-worker | grep -F libseccomp.so
' bash "${deb_name}" "${PKG_UBUNTU_VERSION}" "${TARGET_ARCH}" "${PKG_UPSTREAM_VERSION}" "${UBUNTU_BUNDLED_LLHTTP}"

log "${TARGET_SUITE}-smoke-basic: OK"
