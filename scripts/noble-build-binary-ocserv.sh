#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
. "${SCRIPT_DIR}/_common.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/noble-env.sh
. "${SCRIPT_DIR}/noble-env.sh"
noble_package_vars ocserv

DSC="${PKG_SOURCE_ROOT}/${PKG_SOURCE}_${PKG_NOBLE_VERSION}.dsc"
[[ -f "${DSC}" ]] || die "missing dsc: ${DSC} (run noble-src-pkg-ocserv first)"
[[ -f "${NOBLE_REPO_DIR}/Packages" ]] || die "missing local repo Packages: ${NOBLE_REPO_DIR}/Packages (run noble-repo first)"

HTTP_PID=""
HTTP_PORT=""

cleanup_http_repo() {
  if [[ -n "${HTTP_PID}" ]] && kill -0 "${HTTP_PID}" 2>/dev/null; then
    kill "${HTTP_PID}" 2>/dev/null || true
    wait "${HTTP_PID}" 2>/dev/null || true
  fi
}

trap cleanup_http_repo EXIT
trap 'cleanup_http_repo; exit 130' INT
trap 'cleanup_http_repo; exit 143' TERM

choose_free_port() {
  python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

start_http_repo() {
  HTTP_PORT="$(choose_free_port)"
  python3 -m http.server "${HTTP_PORT}" --bind 127.0.0.1 --directory "${NOBLE_REPO_DIR}" >/tmp/noble-libllhttp-repo."${HTTP_PORT}".log 2>&1 &
  HTTP_PID="$!"
  sleep "${NOBLE_HTTP_STARTUP_SLEEP:-1}"
  kill -0 "${HTTP_PID}" 2>/dev/null || die "failed to start local HTTP repo on 127.0.0.1:${HTTP_PORT}"
}

mkdir -p "${PKG_BINARY_DIR}"
rm -f -- "${PKG_BINARY_DIR}"/*

start_http_repo
repo_line="deb [trusted=yes] http://127.0.0.1:${HTTP_PORT}/ ./"

sbuild \
  --chroot-mode=schroot \
  -d "${TARGET_DISTRIBUTION}" \
  --arch="${TARGET_ARCH}" \
  --build-dir "${PKG_BINARY_DIR}" \
  --no-run-lintian \
  --extra-repository="${repo_line}" \
  "${DSC}"

DEB="${PKG_BINARY_DIR}/ocserv_${PKG_NOBLE_VERSION}_${TARGET_ARCH}.deb"
CHANGES="${PKG_BINARY_DIR}/ocserv_${PKG_NOBLE_VERSION}_${TARGET_ARCH}.changes"
BUILDINFO="${PKG_BINARY_DIR}/ocserv_${PKG_NOBLE_VERSION}_${TARGET_ARCH}.buildinfo"
[[ -f "${DEB}" ]] || die "expected deb not found: ${DEB}"
[[ -f "${CHANGES}" ]] || die "expected changes not found: ${CHANGES}"
[[ -f "${BUILDINFO}" ]] || die "expected buildinfo not found: ${BUILDINFO}"

log "ocserv binary built: ${DEB}"
