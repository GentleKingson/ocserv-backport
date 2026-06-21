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

parse_args() {
  TOKEN_STDIN="${TOKEN_STDIN:-0}"; BOOTSTRAP_DRY_RUN="${BOOTSTRAP_DRY_RUN:-0}"
  RUNNER_NAME="${RUNNER_NAME:-}"; RUNNER_NAME_OVERRIDE="${RUNNER_NAME_OVERRIDE:-0}"
  RUNNER_WAIT_TIMEOUT_OVERRIDE="${RUNNER_WAIT_TIMEOUT_OVERRIDE:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registration-token-stdin) TOKEN_STDIN=1; shift ;;
      --dry-run) BOOTSTRAP_DRY_RUN=1; shift ;;
      --runner-name)
        # Live mode: ALWAYS CSPRNG-generated; --runner-name forbidden (prevents
        # cleanup trap removing a pre-existing same-name container). Dry-run only.
        [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]] || die "live mode forbids --runner-name (CSPRNG-only); dry-run only"
        [[ $# -ge 2 ]] || die "--runner-name requires a value"
        RUNNER_NAME="$2"; RUNNER_NAME_OVERRIDE=1; shift 2 ;;
      --wait-timeout) [[ $# -ge 2 ]] || die "--wait-timeout requires a value"; RUNNER_WAIT_TIMEOUT_OVERRIDE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --docker-arg|--mount|--cap-add|--privileged|--pid|--ipc|--uts|--userns|--network|--image|--label|--env|--device|-v|--volume)
        die "forbidden argument: $1" ;;
      *) die "unknown argument: $1 (see -h)" ;;
    esac
  done
}
usage() {
  cat >&2 <<EOF
Usage: runner-provisioner.sh --registration-token-stdin [options]
  --registration-token-stdin   token from stdin
  --dry-run                    print docker run without executing
  --runner-name <name>         DRY-RUN ONLY (live uses CSPRNG name)
  --wait-timeout <dur>         5m..60m
  -h, --help
EOF
}

assert_image_is_digest() {
  [[ "$1" =~ @sha256:[0-9a-f]{64}$ ]] || die "RUNNER_IMAGE must be 64-hex digest (got '$1')"
}

# build_docker_run_args <name> — fixed argv + ownership labels (for safe cleanup).
build_docker_run_args() {
  local name="$1"
  assert_image_is_digest "${RUNNER_IMAGE}"
  printf '%s\0' \
    run --rm --init -i --interactive \
    --name="${name}" --stop-timeout=10 \
    --label "com.ocserv-ci.managed-by=runner-provisioner" \
    --label "com.ocserv-ci.phase=1" \
    --label "com.ocserv-ci.runner-name=${name}" \
    --read-only --user=10001:10001 --cap-drop=ALL --security-opt=no-new-privileges:true \
    --pids-limit="${RUNNER_PIDS_LIMIT}" --memory="${RUNNER_MEMORY}" --cpus="${RUNNER_CPUS}" \
    --network="${RUNNER_NETWORK}" --pull=never \
    --env "RUNNER_URL=${RUNNER_URL}" --env "RUNNER_LABEL=${RUNNER_LABEL}" --env "RUNNER_NAME=${name}" \
    --tmpfs "/runner:rw,nosuid,nodev,size=${RUNNER_TMPFS_RUNNER_SIZE},uid=10001,gid=10001,mode=0700" \
    --tmpfs "/work:rw,nosuid,nodev,size=${RUNNER_TMPFS_WORK_SIZE},uid=10001,gid=10001,mode=0700" \
    --tmpfs "/tmp:rw,nosuid,nodev,noexec,size=${RUNNER_TMPFS_TMP_SIZE},uid=10001,gid=10001,mode=1777" \
    "${RUNNER_IMAGE}"
}

# _config_metadata <file> — "owner:group mode kind" (stubbable; real = stat).
_config_metadata() {
  local f="$1" mode kind
  mode="$(stat -c '%a' "${f}")"
  if [[ -L "${f}" ]]; then kind="symlink"
  elif [[ -f "${f}" ]]; then kind="regular"; else kind="other"; fi
  printf '%s %s %s' "$(stat -c '%U:%G' "${f}")" "${mode}" "${kind}"
}
# _path_metadata <path> — "owner:group mode kind" or "missing" (stubbable).
_path_metadata() {
  local p="$1"
  [[ -e "${p}" ]] || { printf 'missing'; return; }
  local mode kind
  mode="$(stat -c '%a' "${p}")"
  if [[ -L "${p}" ]]; then kind="symlink"
  elif [[ -d "${p}" ]]; then kind="directory"; else kind="other"; fi
  printf '%s %s %s' "$(stat -c '%U:%G' "${p}")" "${mode}" "${kind}"
}

assert_config_root_owned() {
  local f="$1" meta owner mode kind
  meta="$(_config_metadata "${f}")"; owner="${meta%% *}"
  local rest="${meta#* }"; mode="${rest%% *}"; kind="${rest##* }"
  [[ "${kind}" == "regular" ]] || die "config ${f} must be regular (got ${kind})"
  [[ "${owner}" == "root:root" ]] || die "config ${f} must be root:root (got ${owner})"
  [[ "${mode}" == "600" ]] || die "config ${f} must be 0600 (got ${mode})"
}

# assert_parent_paths_trusted <file> — every existing ancestor: root:root, directory,
# non-symlink, no group/world write. Missing ancestor = fail closed.
assert_parent_paths_trusted() {
  local p; p="$(dirname "$1")"
  while [[ "${p}" != "/" ]]; do
    local meta owner mode kind
    meta="$(_path_metadata "${p}")"
    [[ "${meta}" != missing ]] || die "parent path ${p} missing (fail closed)"
    owner="${meta%% *}"; local rest="${meta#* }"; mode="${rest%% *}"; kind="${rest##* }"
    [[ "${kind}" == "directory" ]] || die "parent ${p} must be directory (got ${kind})"
    [[ "${owner}" == "root:root" ]] || die "parent ${p} must be root:root (got ${owner})"
    case "${mode}" in ?[2367]?|??[2367]) die "parent ${p} group/world-writable (mode ${mode})";; esac
    p="$(dirname "${p}")"
  done
}

preflight_image_cached() {
  docker image inspect "$1" >/dev/null 2>&1 \
    || die "image $1 not in local cache; pre-pull by exact digest (--pull=never)"
}
preflight_name_free() {
  if docker inspect "$1" >/dev/null 2>&1; then
    die "container $1 exists; remove it first (cleanup safety)"
  fi
}

# preflight_no_orphan_managed — ANY state (running/paused/exited/dead/removing).
# docker ps FAILURE (daemon down) -> fail closed (NOT masked as "empty").
preflight_no_orphan_managed() {
  local orphan
  if ! orphan="$(docker ps -aq --filter 'label=com.ocserv-ci.managed-by=runner-provisioner' --filter 'label=com.ocserv-ci.phase=1' 2>/dev/null)"; then
    die "cannot enumerate managed containers (docker ps failed); refusing live launch (fail closed)"
  fi
  if [[ -n "${orphan}" ]]; then
    log "orphan managed container(s) present (inspect before cleanup):"
    docker inspect --format '{{.Name}} state={{.State.Status}}' "${orphan}" >&2 2>/dev/null || true
    die "orphan Phase 1 managed container(s) found; inspect + clean per runbook before launching (single-slot)"
  fi
}

acquire_single_slot() {
  [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]] && return 0
  install -d -m 0755 "$(dirname "${SINGLE_SLOT_LOCK}")" 2>/dev/null || true
  exec 9>"${SINGLE_SLOT_LOCK}"
  flock -n 9 || die "another provisioner holds ${SINGLE_SLOT_LOCK} (single-slot); aborting"
  log "acquired single-slot lock"
}

current_uid() { id -u; }

# container_label <name> <label-key> — stubbable; real impl uses docker inspect.
container_label() { docker inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true; }

# cleanup_this_container: rm ONLY if all 3 ownership labels match exactly.
cleanup_this_container() {
  local name="$1"
  docker inspect "${name}" >/dev/null 2>&1 || return 0
  local mb ph rn
  mb="$(container_label "${name}" "com.ocserv-ci.managed-by")"
  ph="$(container_label "${name}" "com.ocserv-ci.phase")"
  rn="$(container_label "${name}" "com.ocserv-ci.runner-name")"
  if [[ "${mb}" == "runner-provisioner" && "${ph}" == "1" && "${rn}" == "${name}" ]]; then
    log "cleanup: removing this-provisioner container ${name}"
    docker rm -f "${name}" >/dev/null 2>&1 || true
  else
    log "WARN: container ${name} labels mismatch (mb=${mb} ph=${ph} rn=${rn}); NOT removing"
  fi
}

# ensure_audit_sink — STRICT, run ONCE before docker launch. Fails closed.
ensure_audit_sink() {
  assert_parent_paths_trusted "${AUDIT_DIR}"
  [[ ! -L "${AUDIT_DIR}" ]] || die "audit dir ${AUDIT_DIR} is a symlink (forbidden)"
  if [[ ! -e "${AUDIT_DIR}" ]]; then
    install -d -o root -g root -m 0750 "${AUDIT_DIR}" || die "cannot create audit dir ${AUDIT_DIR}"
  fi
  local dmeta downer dmode dkind
  dmeta="$(_path_metadata "${AUDIT_DIR}")"
  [[ "${dmeta}" != missing ]] || die "audit dir ${AUDIT_DIR} missing after create"
  downer="${dmeta%% *}"; local dr="${dmeta#* }"; dmode="${dr%% *}"; dkind="${dr##* }"
  [[ "${dkind}" == "directory" ]] || die "audit dir ${AUDIT_DIR} not a directory (got ${dkind})"
  [[ "${downer}" == "root:root" ]] || die "audit dir ${AUDIT_DIR} owner=${downer} (need root:root)"
  [[ "${dmode}" == "750" ]] || die "audit dir ${AUDIT_DIR} mode=${dmode} (need 750)"
  [[ ! -L "${AUDIT_LOG}" ]] || die "audit log ${AUDIT_LOG} is a symlink (forbidden)"
  if [[ ! -e "${AUDIT_LOG}" ]]; then
    ( umask 037; : > "${AUDIT_LOG}" ) || die "cannot create audit log ${AUDIT_LOG}"
    chown root:root "${AUDIT_LOG}" || die "chown audit log failed"
    chmod 0640 "${AUDIT_LOG}" || die "chmod audit log failed"
  fi
  local lmeta lowner lmode lkind
  lmeta="$(_config_metadata "${AUDIT_LOG}")"
  lowner="${lmeta%% *}"; local lr="${lmeta#* }"; lmode="${lr%% *}"; lkind="${lr##* }"
  [[ "${lkind}" == "regular" ]] || die "audit log ${AUDIT_LOG} not regular (got ${lkind})"
  [[ "${lowner}" == "root:root" ]] || die "audit log ${AUDIT_LOG} owner=${lowner} (need root:root)"
  [[ "${lmode}" == "640" ]] || die "audit log ${AUDIT_LOG} mode=${lmode} (need 640)"
}

# write_audit_event — BEST-EFFORT (post-launch). Never alters rc / breaks cleanup.
write_audit_event() {
  printf '%s event=%s name=%s image=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "${4:-}" \
    >>"${AUDIT_LOG}" 2>/dev/null || log "WARN: audit write failed (best-effort, not aborting)"
}

# audit_event — STRICT (pre-launch): ensure sink then write (die on failure).
audit_event() {
  ensure_audit_sink
  printf '%s event=%s name=%s image=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "${4:-}" \
    >>"${AUDIT_LOG}" || die "audit write failed ${AUDIT_LOG}"
}

main() {
  [[ "$(current_uid)" -eq 0 ]] || die "must run as root (install via runner-host-install.sh)"
  parse_args "$@"
  [[ "${TOKEN_STDIN}" -eq 1 ]] || die "token source required: --registration-token-stdin"
  local config="${DEFAULT_CONFIG}"
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" && -n "${PROVISIONER_CONFIG:-}" ]]; then config="${PROVISIONER_CONFIG}"
  elif [[ -n "${PROVISIONER_CONFIG:-}" ]]; then die "PROVISIONER_CONFIG forbidden in live mode (use ${DEFAULT_CONFIG})"; fi
  assert_config_root_owned "${config}"
  assert_parent_paths_trusted "${config}"
  load_provisioner_config "${config}"
  [[ -n "${RUNNER_WAIT_TIMEOUT_OVERRIDE:-}" ]] && RUNNER_WAIT_TIMEOUT="${RUNNER_WAIT_TIMEOUT_OVERRIDE}"
  local wait_s; wait_s="$(parse_timeout_to_seconds "${RUNNER_WAIT_TIMEOUT}")"
  if [[ "${RUNNER_NAME_OVERRIDE:-0}" != "1" ]]; then RUNNER_NAME="$(generate_runner_name)"; fi
  log "runner=${RUNNER_NAME} image=${RUNNER_IMAGE} network=${RUNNER_NETWORK} timeout=${RUNNER_WAIT_TIMEOUT}(${wait_s}s)"

  local docker_argv=()
  while IFS= read -r -d '' a; do docker_argv+=("${a}"); done < <(build_docker_run_args "${RUNNER_NAME}")

  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN (token suppressed):"
    printf '  timeout --foreground --signal=TERM --kill-after=10s %ss docker %q\n' "${wait_s}" "${docker_argv[@]}" >&2
    return
  fi

  acquire_single_slot
  preflight_no_orphan_managed
  preflight_image_cached "${RUNNER_IMAGE}"
  preflight_name_free "${RUNNER_NAME}"

  CONTAINER_LAUNCHED=0
  cleanup_handler() { [[ "${CONTAINER_LAUNCHED:-0}" == "1" ]] && cleanup_this_container "${RUNNER_NAME}"; }
  trap cleanup_handler EXIT
  on_signal() { write_audit_event signal "${RUNNER_NAME}" "${RUNNER_IMAGE}" "sig=$1"; cleanup_handler; exit 130; }
  trap 'on_signal TERM' TERM
  trap 'on_signal INT' INT

  CONTAINER_LAUNCHED=1   # set BEFORE docker run so TERM/INT/crash mid-run still cleans up
  audit_event start "${RUNNER_NAME}" "${RUNNER_IMAGE}" "timeout=${RUNNER_WAIT_TIMEOUT}"

  local rc=0 ev=exit
  if timeout --foreground --signal=TERM --kill-after=10s "${wait_s}s" docker "${docker_argv[@]}" < /dev/stdin; then
    rc=0
  else
    rc=$?
    if [[ ${rc} -eq 124 ]]; then ev=timeout
    elif [[ ${rc} -gt 128 ]]; then ev=signal; fi
  fi
  # Keep CONTAINER_LAUNCHED=1 through audit+cleanup so EXIT trap still cleans up
  # if anything below throws. Use best-effort write (must not alter rc/break cleanup).
  log "runner ${RUNNER_NAME} ${ev} rc=${rc}"
  write_audit_event "${ev}" "${RUNNER_NAME}" "${RUNNER_IMAGE}" "rc=${rc}"
  trap - EXIT TERM INT
  cleanup_this_container "${RUNNER_NAME}"
  CONTAINER_LAUNCHED=0   # only clear after cleanup succeeded
  return ${rc}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
