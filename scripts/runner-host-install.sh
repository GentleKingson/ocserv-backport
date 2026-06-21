#!/usr/bin/env bash
set -euo pipefail
# runner-host-install.sh — one-time runner host setup from an AUDITED root-owned clone.
# Verifies persistence + iptables backend FIRST; installs root-owned provisioner;
# creates+verifies IPv4-only Docker bridge; builds two IPv4 managed iptables chains;
# saves+verifies persisted ruleset (rollback on failure); jump dedup with comment.
log() { printf '[%s] host-install: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

LIBEXEC_DIR="/usr/local/libexec/ocserv-ci"
CONFIG_DIR="/etc/ocserv-ci-runner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER_SRC="${SCRIPT_DIR}/runner-provisioner.sh"
POLICY_SRC="${SCRIPT_DIR}/../docker/runner/ci-build-egress.policy"
BRIDGE="br-ci-build-egress"; SUBNET="172.30.0.0/24"; GW="172.30.0.1"
EGRESS_CHAIN="OCSERV_CI_EGRESS"; HOST_GUARD="OCSERV_CI_HOST_GUARD"
JUMP_COMMENT="ocserv-ci egress"; GUARD_COMMENT="ocserv-ci host-guard"

verify_path_trusted() {
  local p="$1" m o
  [[ -e "${p}" ]] || die "path ${p} missing (fail closed)"
  [[ ! -L "${p}" ]] || die "${p} is a symlink (forbidden)"
  [[ -d "${p}" ]] || die "${p} not a directory"
  o="$(stat -c '%U:%G' "${p}")"; [[ "${o}" == "root:root" ]] || die "${p} owner=${o} (need root:root)"
  m="$(stat -c '%a' "${p}")"
  case "${m}" in ?[2367]?|??[2367]) die "${p} group/world-writable (mode ${m})";; esac
}

# verify_ci_build_network — IPv4-only; same checks for new AND existing.
# Uses real IPAM fields (.Subnet/.Gateway) — Docker has no reliable .IPv6Subnet field.
verify_ci_build_network() {
  local drv br ipv6
  drv="$(docker network inspect ci-build-egress -f '{{.Driver}}')"
  br="$(docker network inspect ci-build-egress -f '{{index .Options "com.docker.network.bridge.name"}}')"
  ipv6="$(docker network inspect ci-build-egress -f '{{.EnableIPv6}}')"
  [[ "${drv}" == bridge ]] || die "driver=${drv} (need bridge)"
  [[ "${br}" == "${BRIDGE}" ]] || die "bridge=${br} (need ${BRIDGE})"
  [[ "${ipv6}" == false ]] || die "EnableIPv6=${ipv6} (need false; Phase 1 is IPv4-only)"
  # IPAM: exactly one entry, IPv4 subnet+gateway, no IPv6 data (no ':' in either field).
  local ipam_line
  ipam_line="$(docker network inspect ci-build-egress -f '{{range .IPAM.Config}}{{printf "%s\t%s\n" .Subnet .Gateway}}{{end}}')"
  [[ "${ipam_line}" == "${SUBNET}"$'\t'"${GW}" ]] \
    || die "ci-build-egress IPAM must be ${SUBNET} / ${GW} (got '${ipam_line}')"
  [[ "${ipam_line}" != *:* ]] || die "ci-build-egress IPAM contains IPv6 data (':' present)"
}

main() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root"
  [[ -f "${PROVISIONER_SRC}" ]] || die "provisioner source not found"

  # 1. Verify persistence + backend FIRST.
  command -v netfilter-persistent >/dev/null 2>&1 || die "netfilter-persistent missing (install iptables-persistent)"
  systemctl is-enabled netfilter-persistent >/dev/null 2>&1 || die "netfilter-persistent not enabled (rules won't survive reboot)"
  iptables -n -L DOCKER-USER >/dev/null 2>&1 || die "DOCKER-USER missing — Docker must use iptables backend"
  log "prerequisites OK (netfilter-persistent enabled + Docker iptables backend)"

  # 1b. Installer flock + refuse rebuild while managed containers exist.
  install -d -m 0755 /run/lock 2>/dev/null || true
  exec 8>/run/lock/ocserv-ci-firewall-install.lock
  flock -n 8 || die "another installer holds the firewall-install lock; aborting"
  local inst_orphan
  if ! inst_orphan="$(docker ps -aq --filter 'label=com.ocserv-ci.managed-by=runner-provisioner' --filter 'label=com.ocserv-ci.phase=1' 2>/dev/null)"; then
    die "cannot enumerate managed containers (docker ps failed); refusing firewall rebuild (fail closed)"
  fi
  if [[ -n "${inst_orphan}" ]]; then
    die "Phase 1 managed container(s) running (${inst_orphan}); refusing firewall rebuild (stop/remove runners first)"
  fi
  log "installer lock acquired; no managed containers running"

  # 2. Install provisioner + verify source files + parent paths.
  install -d -o root -g root -m 0755 /usr/local/libexec
  install -d -o root -g root -m 0755 "${LIBEXEC_DIR}"
  for d in /usr /usr/local /usr/local/libexec "${LIBEXEC_DIR}"; do verify_path_trusted "${d}"; done
  for sf in "${PROVISIONER_SRC}" "${POLICY_SRC}"; do
    [[ -f "${sf}" && ! -L "${sf}" ]] || die "source ${sf} not a regular file"
  done
  install -o root -g root -m 0755 "${PROVISIONER_SRC}" "${LIBEXEC_DIR}/runner-provisioner"
  [[ ! -L "${LIBEXEC_DIR}/runner-provisioner" ]] || die "installed provisioner is symlink"
  [[ "$(stat -c '%U:%G' "${LIBEXEC_DIR}/runner-provisioner")" == "root:root" ]] || die "installed provisioner not root:root"
  log "provisioner (self-contained) -> ${LIBEXEC_DIR}/runner-provisioner"

  # 3. Config dir + policy.
  install -d -o root -g root -m 0750 "${CONFIG_DIR}"; verify_path_trusted "${CONFIG_DIR}"
  if [[ ! -f "${CONFIG_DIR}/provisioner.conf" ]]; then
    cat >"${CONFIG_DIR}/provisioner.conf" <<'EOF'
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/OWNER/ocserv-ci-runner@sha256:REPLACE_64_HEX
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
    chmod 0600 "${CONFIG_DIR}/provisioner.conf"
  fi
  install -o root -g root -m 0644 "${POLICY_SRC}" "${CONFIG_DIR}/ci-build-egress.policy"

  # 4. IPv4-only Docker bridge (no --ipv6). Verify new AND existing.
  if ! docker network inspect ci-build-egress >/dev/null 2>&1; then
    docker network create --driver bridge --subnet "${SUBNET}" --gateway "${GW}" \
      --opt com.docker.network.bridge.name="${BRIDGE}" ci-build-egress
  fi
  verify_ci_build_network
  log "ci-build-egress verified (IPv4-only)"

  # 5. IPv4 managed chains; rollback on save/verify failure.
  if ! build_and_persist_firewall; then
    log "firewall build/persist failed; rolling back IPv4 managed chains"
    iptables -D DOCKER-USER -i "${BRIDGE}" -j "${EGRESS_CHAIN}" -m comment --comment "${JUMP_COMMENT}" 2>/dev/null || true
    iptables -D INPUT -i "${BRIDGE}" -j "${HOST_GUARD}" -m comment --comment "${GUARD_COMMENT}" 2>/dev/null || true
    iptables -F "${EGRESS_CHAIN}" 2>/dev/null || true; iptables -X "${EGRESS_CHAIN}" 2>/dev/null || true
    iptables -F "${HOST_GUARD}" 2>/dev/null || true; iptables -X "${HOST_GUARD}" 2>/dev/null || true
    die "firewall setup failed (rolled back)"
  fi
  log "install complete. Launch: sudo -v; printf '%s\\n' \"\$TOKEN\" | sudo -n ${LIBEXEC_DIR}/runner-provisioner --registration-token-stdin; unset TOKEN"
}

build_and_persist_firewall() {
  iptables -N "${EGRESS_CHAIN}" 2>/dev/null || iptables -F "${EGRESS_CHAIN}"
  iptables -N "${HOST_GUARD}" 2>/dev/null || iptables -F "${HOST_GUARD}"
  for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 0.0.0.0/8 "${GW}"; do
    iptables -A "${EGRESS_CHAIN}" -i "${BRIDGE}" -d "${cidr}" -j DROP -m comment --comment "ocserv-ci deny ${cidr}"
  done
  iptables -A "${EGRESS_CHAIN}" -i "${BRIDGE}" -p tcp --dport 443 -j RETURN -m comment --comment "ocserv-ci allow 443"
  iptables -A "${EGRESS_CHAIN}" -i "${BRIDGE}" -p tcp --dport 80 -j RETURN -m comment --comment "ocserv-ci allow 80"
  iptables -A "${EGRESS_CHAIN}" -i "${BRIDGE}" -j DROP -m comment --comment "ocserv-ci default deny"
  iptables -A "${HOST_GUARD}" -i "${BRIDGE}" -j DROP -m comment --comment "${GUARD_COMMENT}"
  # Dedup jumps (carry comment). Then exactly one of each.
  while iptables -D DOCKER-USER -i "${BRIDGE}" -j "${EGRESS_CHAIN}" -m comment --comment "${JUMP_COMMENT}" 2>/dev/null; do :; done
  iptables -I DOCKER-USER -i "${BRIDGE}" -j "${EGRESS_CHAIN}" -m comment --comment "${JUMP_COMMENT}"
  while iptables -D INPUT -i "${BRIDGE}" -j "${HOST_GUARD}" -m comment --comment "${GUARD_COMMENT}" 2>/dev/null; do :; done
  iptables -I INPUT -i "${BRIDGE}" -j "${HOST_GUARD}" -m comment --comment "${GUARD_COMMENT}"

  # Active-ruleset verification: exactly one jump each + full managed-chain content.
  iptables -C DOCKER-USER -i "${BRIDGE}" -j "${EGRESS_CHAIN}" -m comment --comment "${JUMP_COMMENT}" >/dev/null 2>&1 || return 1
  iptables -C INPUT -i "${BRIDGE}" -j "${HOST_GUARD}" -m comment --comment "${GUARD_COMMENT}" >/dev/null 2>&1 || return 1
  local n_egress n_guard
  n_egress="$(iptables -S DOCKER-USER | grep -cF -- "-j ${EGRESS_CHAIN} -m comment --comment \"${JUMP_COMMENT}\"" || true)"
  n_guard="$(iptables -S INPUT | grep -cF -- "-j ${HOST_GUARD} -m comment --comment \"${GUARD_COMMENT}\"" || true)"
  [[ "${n_egress}" -eq 1 && "${n_guard}" -eq 1 ]] || { log "jump count egress=${n_egress} guard=${n_guard}"; return 1; }
  local egress_rules guard_rules
  egress_rules="$(iptables -S "${EGRESS_CHAIN}")"
  guard_rules="$(iptables -S "${HOST_GUARD}")"
  echo "${egress_rules}" | grep -q -- "-d 100.64.0.0/10 .*ocserv-ci deny 100.64.0.0/10" || return 1
  echo "${egress_rules}" | grep -q -- "--dport 443 .*ocserv-ci allow 443" || return 1
  echo "${egress_rules}" | grep -q -- "ocserv-ci default deny" || return 1
  [[ "$(echo "${guard_rules}" | grep -c -- "${GUARD_COMMENT}")" -eq 1 ]] || return 1

  # Persist + verify the PERSISTED ruleset.
  netfilter-persistent save >/dev/null 2>&1 || return 1
  local persisted; persisted="$(iptables-save 2>/dev/null)"
  echo "${persisted}" | grep -qF -- ":${EGRESS_CHAIN} " || { log "persisted ruleset missing chain ${EGRESS_CHAIN}"; return 1; }
  echo "${persisted}" | grep -qF -- "-j ${EGRESS_CHAIN} -m comment --comment \"${JUMP_COMMENT}\"" || { log "persisted ruleset missing egress jump"; return 1; }
  echo "${persisted}" | grep -qF -- "-j ${HOST_GUARD} -m comment --comment \"${GUARD_COMMENT}\"" || { log "persisted ruleset missing host-guard jump"; return 1; }
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
