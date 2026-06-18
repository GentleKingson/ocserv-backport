#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §6.4. Mode arg: basic (container, no systemd) | service (VM).
MODE="${1:-}"
[[ "${MODE}" == "basic" || "${MODE}" == "service" ]] \
  || die "usage: smoke-test.sh basic|service"

BACKPORT_VERSION="${OCSERV_VERSION:-1.5.0-1~bpo13+1}"
DEB="$(ls build/binary/ocserv_${BACKPORT_VERSION}_amd64.deb 2>/dev/null || true)"
[[ -n "${DEB}" ]] || die "no deb in build/binary (run 'make binary')"

smoke_basic() {
  local deb="$1"
  log "smoke-basic: container, no systemd assumed"
  # Run in a throwaway trixie container. Dpkg -i may need deps; fall back to apt install.
  docker run --rm -v "$(pwd)/build/binary:/deb:ro" debian:trixie bash -euxc '
    apt-get update -qq
    apt-get install -y -qq /deb/'"$(basename "${deb}")"' || \
      { apt-get install -y -qq -f; }              # resolve deps
    dpkg-query -W -f="${Version}\n" ocserv
    ocserv --version
    test -f /lib/systemd/system/ocserv.service || test -f /usr/lib/systemd/system/ocserv.service
    test -f /etc/ocserv/ocserv.conf || test -f /usr/share/doc/ocserv/ocserv.conf
    ldd /usr/sbin/ocserv  | grep -i "not found" && exit 1 || true
    ldd /usr/bin/occtl    | grep -i "not found" && exit 1 || true
  '
  log "smoke-basic: OK"
}

smoke_service() {
  log "smoke-service: expects to run ON the staging VM (not container)"
  command -v systemctl >/dev/null || die "systemctl missing; smoke-service needs a systemd host"
  local tcp="${OCSERV_TCP_PORT:-443}" udp="${OCSERV_UDP_PORT:-443}"
  systemctl is-active --quiet ocserv || die "ocserv not active"
  ss -H -ltn "sport = :${tcp}" | grep -q . || die "TCP ${tcp} not listening (set OCSERV_TCP_PORT if non-default)"
  ss -H -lun "sport = :${udp}" | grep -q . || die "UDP ${udp} not listening (set OCSERV_UDP_PORT if non-default)"
  journalctl -u ocserv --since "5 min ago" --no-pager | \
    grep -Ei "fatal|config error|permission denied" && die "fatal in journal" || true
  log "smoke-service: OK"
}

case "${MODE}" in
  basic)    smoke_basic "${DEB}" ;;
  service)  smoke_service ;;
esac
