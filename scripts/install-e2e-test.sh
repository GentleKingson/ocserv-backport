#!/usr/bin/env bash
# Run install.sh inside a systemd container and check the result: the
# released ocserv package for the container's distro and architecture is
# installed, ocserv.service is enabled but not running, and policy-rc.d is
# left as it was. A second run checks that re-running the installer is safe.
#
# Usage: install-e2e-test.sh <image> [install.sh options...]
#   image: debian:trixie or ubuntu:24.04
#
# INSTALL_E2E_DOCKER_CMD overrides the docker command (default: docker).
# INSTALL_E2E_RUN_ARGS adds docker run arguments, for example a proxy or a
# CA bundle mount.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

image="${1:-}"
[[ -n "${image}" ]] || die "usage: install-e2e-test.sh <image> [install.sh options...]"
shift

read -r -a DOCKER <<< "${INSTALL_E2E_DOCKER_CMD:-docker}"
[[ "${#DOCKER[@]}" -gt 0 ]] || die "INSTALL_E2E_DOCKER_CMD must not be empty"
read -r -a RUN_ARGS <<< "${INSTALL_E2E_RUN_ARGS:-}"

tag="ocserv-install-e2e:${image//[:\/]/-}"
container="ocserv-install-e2e-$$"

cleanup() {
  "${DOCKER[@]}" rm -f "${container}" > /dev/null 2>&1 || true
}
trap cleanup EXIT

log "building systemd image ${tag} from ${image}"
"${DOCKER[@]}" build -t "${tag}" - << DOCKERFILE
FROM ${image}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \\
 && apt-get install -y --no-install-recommends \\
      ca-certificates curl systemd systemd-sysv \\
 && rm -rf /var/lib/apt/lists/*
# A marker policy-rc.d the installer must restore untouched.
RUN printf '#!/bin/sh\\n# e2e marker\\nexit 0\\n' > /usr/sbin/policy-rc.d \\
 && chmod 0755 /usr/sbin/policy-rc.d
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DOCKERFILE

log "booting ${container}"
"${DOCKER[@]}" run -d --name "${container}" \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  "${RUN_ARGS[@]}" \
  "${tag}" > /dev/null

state=""
for _ in $(seq 60); do
  state="$("${DOCKER[@]}" exec "${container}" systemctl is-system-running 2> /dev/null || true)"
  [[ "${state}" == running || "${state}" == degraded ]] && break
  sleep 2
done
[[ "${state}" == running || "${state}" == degraded ]] \
  || die "systemd in ${container} did not boot (state: ${state:-unknown})"
log "systemd state: ${state}"

run_installer() {
  # Pipe the script on stdin, as the README one-liner does.
  "${DOCKER[@]}" exec -i "${container}" bash -s -- "$@" < "${REPO_ROOT}/install.sh"
}

# shellcheck disable=SC2016 # Expanded inside the container.
check_installed() {
  "${DOCKER[@]}" exec "${container}" bash -euc '
    case "$(. /etc/os-release && echo "${ID}:${VERSION_ID}")" in
      debian:13) suffix="~debian13." ;;
      ubuntu:24.04) suffix="~ubuntu24.04." ;;
      *) echo "unexpected os" >&2; exit 1 ;;
    esac
    version="$(dpkg-query -W -f="\${Version}" ocserv)"
    arch="$(dpkg-query -W -f="\${Architecture}" ocserv)"
    echo "installed ocserv ${version} ${arch}"
    [[ "${version}" == *"${suffix}"* ]] || { echo "not a backport build: ${version}" >&2; exit 1; }
    [[ "${arch}" == "$(dpkg --print-architecture)" ]]

    test -x /usr/sbin/ocserv
    ocserv --version > /dev/null

    enabled="$(systemctl is-enabled ocserv.service)"
    echo "ocserv.service is-enabled: ${enabled}"
    [[ "${enabled}" == enabled ]]

    active="$(systemctl is-active ocserv.service || true)"
    echo "ocserv.service is-active: ${active}"
    [[ "${active}" == inactive ]]
    ! pgrep -x ocserv-main > /dev/null
    ! pgrep -x ocserv > /dev/null

    grep -Fqx "# e2e marker" /usr/sbin/policy-rc.d
  '
}

log "first install"
run_installer "$@"
check_installed

log "second install (re-run)"
run_installer "$@"
check_installed

log "install-e2e: OK (${image})"
