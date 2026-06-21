#!/usr/bin/env bash
# runner-provisioner.sh — Phase 1 ephemeral ci-build runner launcher. SELF-CONTAINED.
# shellcheck disable=SC2034  # DEFAULT_CONFIG/SINGLE_SLOT_LOCK/AUDIT_* used in Task 3
set -euo pipefail

log() { printf '[%s] runner-provisioner: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

DEFAULT_CONFIG="/etc/ocserv-ci-runner/provisioner.conf"
SINGLE_SLOT_LOCK="/run/lock/ocserv-ci-runner.lock"
AUDIT_DIR="/var/log/ocserv-ci-runner"
AUDIT_LOG="${AUDIT_DIR}/lifecycle.log"
readonly TIMEOUT_MIN_S=300 TIMEOUT_MAX_S=3600

# Fixed Phase 1 values (config cannot override these three).
readonly FIXED_RUNNER_URL="https://github.com/GentleKingson/ocserv-backport"
readonly FIXED_RUNNER_LABEL="ci-build"
readonly FIXED_RUNNER_NETWORK="ci-build-egress"

# Allowlist of config keys (unknown RUNNER_* keys rejected).
__CONFIG_ALLOWLIST="RUNNER_URL RUNNER_LABEL RUNNER_IMAGE RUNNER_NETWORK RUNNER_CPUS RUNNER_MEMORY RUNNER_PIDS_LIMIT RUNNER_TMPFS_WORK_SIZE RUNNER_TMPFS_RUNNER_SIZE RUNNER_TMPFS_TMP_SIZE RUNNER_WAIT_TIMEOUT"

__allowlist_has() { local k="$1" a; for a in ${__CONFIG_ALLOWLIST}; do [[ "${a}" == "${k}" ]] && return 0; done; return 1; }

load_provisioner_config() {
  local cfg="$1"
  [[ -f "${cfg}" ]] || die "provisioner config not found: ${cfg}"
  # Clear inherited RUNNER_* env so only the config file provides values.
  local v
  for v in $(compgen -v 2>/dev/null | grep '^RUNNER_' || true); do unset "${v}"; done
  local __seen="" line key val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    [[ "${key}" =~ ^RUNNER_[A-Z0-9_]+$ ]] || die "invalid config key syntax: '${key}'"
    __allowlist_has "${key}" || die "unknown config key (not in allowlist): '${key}'"
    # duplicate-key check (bash 3.2 compatible — no associative array).
    case " ${__seen} " in *" ${key} "*) die "duplicate config key: '${key}'";; esac
    __seen="${__seen} ${key}"
    [[ "${val}" =~ [[:space:]] ]] && die "config value for ${key} contains whitespace (one key=value per line)"
    export "${key}=${val}"
  done < "${cfg}"
  # Fixed values enforced regardless of config.
  [[ "${RUNNER_URL:-}" == "${FIXED_RUNNER_URL}" ]] || die "RUNNER_URL must be ${FIXED_RUNNER_URL} (got '${RUNNER_URL:-}')"
  [[ "${RUNNER_LABEL:-}" == "${FIXED_RUNNER_LABEL}" ]] || die "RUNNER_LABEL must be ${FIXED_RUNNER_LABEL}"
  [[ "${RUNNER_NETWORK:-}" == "${FIXED_RUNNER_NETWORK}" ]] || die "RUNNER_NETWORK must be ${FIXED_RUNNER_NETWORK}"
  local k
  for k in ${__CONFIG_ALLOWLIST}; do [[ -n "${!k:-}" ]] || die "missing required config key: ${k}"; done
}

__CROCKFORD32="0123456789ABCDEFGHJKMNPQRSTVWXYZ"
generate_runner_name() {
  local name="ci-build-" i rand
  for ((i=0; i<26; i++)); do
    rand="$(od -An -tu1 -N1 /dev/urandom | tr -d ' ')"
    name+="${__CROCKFORD32:$((rand % 32)):1}"
  done
  printf '%s' "${name}"
}
valid_runner_name() { [[ "$1" =~ ^ci-build-[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$ ]]; }

parse_timeout_to_seconds() {
  local d="$1" s
  if   [[ "${d}" =~ ^([0-9]+)s$ ]]; then s=$((BASH_REMATCH[1]))
  elif [[ "${d}" =~ ^([0-9]+)m$ ]]; then s=$((BASH_REMATCH[1]*60))
  elif [[ "${d}" =~ ^([0-9]+)h$ ]]; then s=$((BASH_REMATCH[1]*3600))
  else die "invalid RUNNER_WAIT_TIMEOUT: '${d}'"; fi
  [[ ${s} -ge ${TIMEOUT_MIN_S} ]] || die "RUNNER_WAIT_TIMEOUT ${d} below min 5m"
  [[ ${s} -le ${TIMEOUT_MAX_S} ]] || die "RUNNER_WAIT_TIMEOUT ${d} above max 60m"
  printf '%s' "${s}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then echo "ERROR: main() not impl (Task 3)" >&2; exit 2; fi
