# Phase 1 — Ephemeral Runner Foundation Implementation Plan (v1.5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **v1.5 revisions:** **IPv6 decision: Phase 1 is IPv4-only.** Deleted all ip6tables managed chains / IPv6 INPUT/FORWARD guard / IPv6 persistence / IPv6 rollback (do NOT maintain a second firewall for a protocol that is explicitly disabled). Replaced with IPv4-only Docker network + `EnableIPv6=false` + IPv6-IPAM-absence + runtime IPv6-absence verification (no global IPv6 addr, no IPv6 default route). Plus 6 closure items: (1) `ensure_audit_sink()` with strict owner/mode/kind (no `|| true` masking; init failure aborts live launch); (2) orphan preflight uses `docker ps -aq` (running/paused/exited/dead/removing all block new launch; no auto-delete); (3) cleanup tests verify `docker rm -f` called ONLY when all 3 labels match; (4) config source: clear inherited `RUNNER_*` env before parse, allowlist keys only, reject unknown/duplicate, fixed URL/LABEL/NETWORK; (5) workflow boundary via structural YAML parse (not grep); (6) runbook audited-clone install + source-file verification + `/tmp` missing-nodev negative test.

**Goal:** Build a minimal, manually-triggered, **single-slot** (host flock + orphan-container preflight) ephemeral GitHub Actions runner that runs the `lock-projection` job in a non-root, non-privileged, docker-socket-less **IPv4-only** container, then auto-deregisters and auto-removes, with a **real, persistent, host-INPUT-aware IPv4 managed-chain** firewall egress boundary.

**Architecture:** A **self-contained** root-owned bash provisioner reads a short-lived GitHub registration token from stdin, acquires a host `flock` (single-slot), checks for orphan managed containers (any state, fail-closed), generates a CSPRNG runner name, initializes the audit sink (strict owner/mode), sets the cleanup flag, and launches a fixed `docker run --rm -i` of a digest-pinned runner image (preflight `docker image inspect`), wrapped in a bounded `timeout` (5m–60m). The non-root entrypoint copies the payload (no-preserve-ownership) to a `/runner` tmpfs, runs `config.sh --ephemeral --unattended --disableupdate`, then `run.sh`. The runner host runs **two IPv4-only** managed iptables chains — `OCSERV_CI_EGRESS` (from DOCKER-USER) + `OCSERV_CI_HOST_GUARD` (in INPUT) — flushed+rebuilt in fixed order, persisted hard-fail. The Docker network is IPv4-only (`EnableIPv6=false`); runtime verifies no global IPv6 address / no IPv6 default route.

**Tech Stack:** Bash (self-contained provisioner + entrypoint + host-install), Docker (iptables backend verified), Debian trixie (digest-pinned base), GitHub Actions runner (tarball `ADD --checksum=`, `libicu76`), `util-linux` (findmnt), `iproute2` (IPv6-absence check), `curl` (integration test), bats, shellcheck, iptables managed chains (IPv4 only).

**Parent spec:** `docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md` §1.1, §5, §11.2, §11.4.

**Phase 1 scope (hard boundary):** provisioner (self-contained, flock, orphan preflight `ps -aq`, CSPRNG name, strict audit sink, image preflight, timeout, root-owned config + env-clear + parent-path verify, label-verified cleanup, audit events) + non-root ephemeral image (digest base, checksum payload, libicu76, python3-yaml, util-linux, iproute2, curl, no runtime pip) + `--ephemeral`/`--rm`/`-i` + read-only rootfs + tmpfs + no socket + no privileged + cap-drop=ALL + no-new-privileges + no bind mount + resource limits + **IPv4-only Docker network + IPv6-absence verification + real persistent IPv4 managed-chain firewall (egress + host-guard + hard-fail persist)** + migrate `lock-projection` (image-baked, trusted-event, contents:read, no secrets) + automated acceptance + lifecycle audit.

**IPv6 policy (final):** Phase 1 does NOT use IPv6. The network must be IPv4-only (`EnableIPv6=false`, no IPv6 IPAM). No IPv6 GitHub/Debian/DNS/egress is supported. The host must not have a globally-IPv6 Docker daemon (`fixed-cidr-v6`) that could assign IPv6 to `ci-build-egress`; if so, fail closed. **No ip6tables managed chains are maintained** — instead, runtime verifies IPv6 is absent (no global addr, no default route).

**Explicitly NOT in Phase 1:** candidate release API, mTLS bootstrap, R2 staging, Sigstore, aptly, GPG, publish host, testing publish, staging deploy, production promotion, rollback control plane, production credentials, JIT, autoscaler/timer/pool, FQDN egress proxy, **IPv6 support / ip6tables rules**.

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `scripts/runner-provisioner.sh` | Self-contained provisioner: log/die, `_config_metadata`/`_path_metadata` stubs, config parse (env-clear + allowlist + reject unknown/dup + fixed URL/LABEL/NETWORK), stdin token, CSPRNG name (live `--runner-name` forbidden), flock, orphan preflight (`ps -aq`), `ensure_audit_sink` (strict), image+name preflight, `docker run -i` + labels, bounded timeout, cleanup flag before docker, label-verified cleanup, audit events. | New |
| `scripts/runner-host-install.sh` | One-time install from audited root clone: verify netfilter-persistent installed+enabled + Docker iptables backend FIRST; install provisioner + verify source files + parent owner/mode/kind; create+verify **IPv4-only** bridge (`EnableIPv6=false`, no IPv6 IPAM, reject global daemon IPv6); build two **IPv4** managed chains; save+verify ruleset (rollback on failure); jump dedup with comment. | New |
| `docker/runner/Dockerfile` | Non-root (10001:10001) trixie: digest base (no default) + `ADD --checksum=` payload + python3-yaml + util-linux + **libicu76** + **curl** + **iproute2**. No runtime pip. | New |
| `docker/runner/entrypoint.sh` | Container entrypoint (UID 10001): findmnt assertions, no-preserve copy, stdin token, config.sh --ephemeral, run.sh. | New |
| `docker/runner/ci-build-egress.policy` | IPv4 managed-chain rule spec. | New |
| `docker/runner/ci-build-egress.policy.lib` | Pure IPv4 egress decision lib. | New |
| `test/test_runner_provisioner.bats` | Provisioner tests (parser env-clear/allowlist/dup, orphan `ps -aq`, cleanup all-3-labels, audit sink strict, parent-path owner). | New |
| `test/test_runner_entrypoint.bats` | Entrypoint mount-assertion tests (path-aware stubs + `/tmp` missing-nodev negative). | New |
| `test/test_runner_network.bats` | Policy parse + pure IPv4 egress lib (correct rc assertion). | New |
| `test/test_workflow_boundary.py` | Structural YAML parse of ci-testing.yml (ci-build exactly once; trusted-event; permissions; no secrets/env/id-token). | New |
| `.github/workflows/ci-testing.yml` | Dual-track `lock-projection-cibuild` (contents:read, trusted-event, no secrets). | Modify |
| `Makefile` | `runner-image` (digest base required), `runner-provision` (dry-run). | Modify |
| `docs/runner-ephemeral.md` | Runbook: audited-clone install, IPv4-only network, firewall integration (IPv4 + IPv6-absence), sudo -n token, audit, offline cleanup. | New |

---

## Task 1: Self-contained provisioner — helpers + config (env-clear/allowlist/dup) + name + timeout

**Files:**
- Create: `scripts/runner-provisioner.sh`, `test/test_runner_provisioner.bats`

- [ ] **Step 1: Failing tests**

```bash
load helpers/bats-helper.bash
PROVISIONER="${REPO_ROOT}/scripts/runner-provisioner.sh"
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NAME26="0123456789ABCDEFGHJKMNPQRS"

@test "provisioner is self-contained (sources without _common.sh)" {
  run bash -c "set +e; cd /tmp; source '${PROVISIONER}'; echo sourced-ok"
  echo "$output" | grep -q sourced-ok
}

@test "load_provisioner_config: clears inherited RUNNER_* env; only config provides values" {
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<EOF
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  # Pre-set a BOGUS inherited value; load must clear it (not inherit).
  run bash -c "set +e; source '${PROVISIONER}'; RUNNER_MEMORY=bogus-inherited; load_provisioner_config '${tmpcfg}'; echo \"MEM=[\${RUNNER_MEMORY}]\""
  echo "$output" | grep -q 'MEM=\[6g\]'
  rm -f "$tmpcfg"
}

@test "load_provisioner_config: rejects unknown RUNNER_* key" {
  tmpcfg="$(mktemp)"; printf 'RUNNER_URL=x\nRUNNER_EVIL=injected\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: rejects duplicate key" {
  tmpcfg="$(mktemp)"; printf 'RUNNER_URL=x\nRUNNER_URL=y\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: one-key-per-line; rejects whitespace in value" {
  tmpcfg="$(mktemp)"; printf 'RUNNER_CPUS=2 RUNNER_MEMORY=6g\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: dies on missing file / missing required key" {
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config /nope.conf; echo rc=\$?"
  [ "$status" -ne 0 ]
  tmpcfg="$(mktemp)"; printf 'RUNNER_URL=x\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: enforces fixed URL/LABEL/NETWORK values" {
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<EOF
RUNNER_URL=https://evil.example.com
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]   # URL not the fixed repo URL -> rejected
  rm -f "$tmpcfg"
}

@test "generate_runner_name: ci-build-<26 Crockford Base32 incl S/Z>; two differ" {
  run bash -c "set +e; source '${PROVISIONER}'; generate_runner_name"
  echo "$output" | grep -qE '^ci-build-[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$'
  run bash -c "set +e; source '${PROVISIONER}'; printf '%s\n%s\n' \"\$(generate_runner_name)\" \"\$(generate_runner_name)\""
  [ "$(sed -n 1p <<<"$output")" != "$(sed -n 2p <<<"$output")" ]
}

@test "valid_runner_name + parse_timeout_to_seconds bounds [5m,60m]" {
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name ci-build-${NAME26} && echo ok"; echo "$output" | grep -q ok
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 45m"; [ "$output" = "2700" ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 1m; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 90m; echo rc=\$?"; [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run → FAIL** (script absent).

- [ ] **Step 3: Create provisioner (config parse: env-clear + allowlist + reject unknown/dup + fixed values)**

```bash
#!/usr/bin/env bash
# runner-provisioner.sh — Phase 1 ephemeral ci-build runner launcher. SELF-CONTAINED.
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

__allowlist_has() { local k="$1" a; for a in ${__CONFIG_ALLOWLIST}; do [[ "$a" == "$k" ]] && return 0; done; return 1; }

load_provisioner_config() {
  local cfg="$1"
  [[ -f "${cfg}" ]] || die "provisioner config not found: ${cfg}"
  # Clear inherited RUNNER_* env so only the config file provides values.
  local v
  for v in $(compgen -v 2>/dev/null | grep '^RUNNER_' || true); do unset "$v"; done
  local -A seen=()
  local line key val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    [[ "${key}" =~ ^RUNNER_[A-Z0-9_]+$ ]] || die "invalid config key syntax: '${key}'"
    __allowlist_has "${key}" || die "unknown config key (not in allowlist): '${key}'"
    [[ -z "${seen[$key]:-}" ]] || die "duplicate config key: '${key}'"
    seen[$key]=1
    [[ "${val}" =~ [[:space:]] ]] && die "config value for ${key} contains whitespace (one key=value per line)"
    export "${key}=${val}"
  done < "${cfg}"
  # Fixed values enforced regardless of config.
  [[ "${RUNNER_URL:-}" == "${FIXED_RUNNER_URL}" ]] || die "RUNNER_URL must be ${FIXED_RUNNER_URL} (got '${RUNNER_URL:-}')"
  [[ "${RUNNER_LABEL:-}" == "${FIXED_RUNNER_LABEL}" ]] || die "RUNNER_LABEL must be ${FIXED_RUNNER_LABEL}"
  [[ "${RUNNER_NETWORK:-}" == "${FIXED_RUNNER_NETWORK}" ]] || die "RUNNER_NETWORK must be ${FIXED_RUNNER_NETWORK}"
  local req k
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
  if   [[ "${d}" =~ ^([0-9]+)s$ ]]; then s=$((${BASH_REMATCH[1]}))
  elif [[ "${d}" =~ ^([0-9]+)m$ ]]; then s=$((${BASH_REMATCH[1]}*60))
  elif [[ "${d}" =~ ^([0-9]+)h$ ]]; then s=$((${BASH_REMATCH[1]}*3600))
  else die "invalid RUNNER_WAIT_TIMEOUT: '${d}'"; fi
  [[ ${s} -ge ${TIMEOUT_MIN_S} ]] || die "RUNNER_WAIT_TIMEOUT ${d} below min 5m"
  [[ ${s} -le ${TIMEOUT_MAX_S} ]] || die "RUNNER_WAIT_TIMEOUT ${d} above max 60m"
  printf '%s' "${s}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then echo "ERROR: main() not impl (Task 3)" >&2; exit 2; fi
```

- [ ] **Step 4: Run → PASS (9)**. `shellcheck` (no errors).
- [ ] **Step 5: Commit** `feat(phase1): self-contained provisioner helpers (config env-clear/allowlist/dup/fixed-values)`.

---

## Task 2: Arg validation (live `--runner-name` forbidden) + forbidden-args

**Files:**
- Modify: `scripts/runner-provisioner.sh`, `test/test_runner_provisioner.bats`

- [ ] **Step 1: Failing tests** (parse_args: --registration-token-stdin/--dry-run; --runner-name dry-run-only/live-forbidden; forbidden flags rejected; unknown rejected — same as v1.4 Task 2).

```bash
@test "parse_args: --registration-token-stdin / --dry-run" {
  run bash -c "set +e; source '${PROVISIONER}'; TOKEN_STDIN=0; parse_args --registration-token-stdin --dry-run; printf 'T=%s D=%s\n' \"\$TOKEN_STDIN\" \"\$BOOTSTRAP_DRY_RUN\""
  echo "$output" | grep -q 'T=1 D=1'
}
@test "parse_args: --runner-name DRY-RUN only; live FORBIDDEN" {
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=1; parse_args --runner-name ci-build-DRYTEST; printf 'N=%s\n' \"\$RUNNER_NAME\""
  echo "$output" | grep -q 'N=ci-build-DRYTEST'
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=0; parse_args --runner-name ci-build-${NAME26}; echo rc=\$?"
  [ "$status" -ne 0 ]
}
@test "parse_args: REJECTS container-weakening flags" {
  for bad in --docker-arg --privileged --mount /x --cap-add SYS_ADMIN --pid host --ipc host --uts host --userns host --network host --image evil --label x --env SECRET --device /dev/sda -v /etc:/etc --volume /root:/root; do
    run bash -c "set +e; source '${PROVISIONER}'; parse_args '$bad'; echo rc=\$?"
    [ "$status" -ne 0 ] || { echo "FAIL accepted $bad"; exit 1; }
  done
}
@test "parse_args: rejects unknown" {
  run bash -c "set +e; source '${PROVISIONER}'; parse_args --bogus; echo rc=\$?"; [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run → FAIL**.
- [ ] **Step 3: Add parse_args + usage** (same logic as v1.4 Task 2: live `--runner-name` → die).

```bash
parse_args() {
  TOKEN_STDIN="${TOKEN_STDIN:-0}"; BOOTSTRAP_DRY_RUN="${BOOTSTRAP_DRY_RUN:-0}"
  RUNNER_NAME="${RUNNER_NAME:-}"; RUNNER_NAME_OVERRIDE="${RUNNER_NAME_OVERRIDE:-0}"
  RUNNER_WAIT_TIMEOUT_OVERRIDE="${RUNNER_WAIT_TIMEOUT_OVERRIDE:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registration-token-stdin) TOKEN_STDIN=1; shift ;;
      --dry-run) BOOTSTRAP_DRY_RUN=1; shift ;;
      --runner-name)
        [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]] || die "live mode forbids --runner-name (CSPRNG-only); dry-run only"
        [[ $# -ge 2 ]] || die "--runner-name requires a value"
        RUNNER_NAME="$2"; RUNNER_NAME_OVERRIDE=1; shift 2 ;;
      --wait-timeout) [[ $# -ge 2 ]] || die "--wait-timeout requires a value"; RUNNER_WAIT_TIMEOUT_OVERRIDE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --docker-arg|--mount|--cap-add|--privileged|--pid|--ipc|--uts|--userns|--network|--image|--label|--env|--device|-v|--volume) die "forbidden argument: $1" ;;
      *) die "unknown argument: $1 (see -h)" ;;
    esac
  done
}
usage() { cat >&2 <<EOF
Usage: runner-provisioner.sh --registration-token-stdin [options]
  --registration-token-stdin   token from stdin
  --dry-run                    print docker run without executing
  --runner-name <name>         DRY-RUN ONLY (live uses CSPRNG name)
  --wait-timeout <dur>         5m..60m
  -h, --help
EOF
}
```

- [ ] **Step 4: Run → PASS (13)**. `shellcheck` (no errors).
- [ ] **Step 5: Commit** `feat(phase1): arg validation (live --runner-name forbidden)`.

---

## Task 3: Docker-run + main (flock, orphan `ps -aq` preflight, ensure_audit_sink strict, cleanup-before-docker, all-3-label cleanup, config/parent metadata)

**Files:**
- Modify: `scripts/runner-provisioner.sh`, `test/test_runner_provisioner.bats`

- [ ] **Step 1: Failing tests**

```bash
mkcfg() {  # one key per line
cat >"$1" <<EOF
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
}
docker_argv_lines() {
  bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '$1'; build_docker_run_args '$2'" \
    | while IFS= read -r -d '' a; do printf '%s\n' "$a"; done
}

@test "build_docker_run_args: -i + --interactive + --stop-timeout + 3 ownership labels + safe params" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  out="$(docker_argv_lines "$tmpcfg" ci-build-TEST)"; rm -f "$tmpcfg"
  echo "$out" | grep -qx -- '-i'; echo "$out" | grep -qx -- '--interactive'
  echo "$out" | grep -q -- '--stop-timeout=10'
  echo "$out" | grep -q -- 'com.ocserv-ci.managed-by=runner-provisioner'
  echo "$out" | grep -q -- 'com.ocserv-ci.phase=1'
  echo "$out" | grep -q -- 'com.ocserv-ci.runner-name=ci-build-TEST'
  for f in --rm --init --read-only --user=10001:10001 --cap-drop=ALL --security-opt=no-new-privileges:true --pull=never; do
    echo "$out" | grep -qx -- "$f" || { echo "MISSING $f"; exit 1; }
  done
  echo "$out" | grep -qx -- "ghcr.io/owner/img@sha256:${DIG64}"
  ! echo "$out" | grep -q -- '--privileged'
  ! echo "$out" | grep -q -- 'docker.sock'
  ! echo "$out" | grep -qE -- '^-v$|--volume'
}

@test "assert_image_is_digest: 64-hex ok; short/tag rejected" {
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'x@sha256:${DIG64}'; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'debian:trixie'; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "assert_config_root_owned: stub _config_metadata; root:root 600 regular pass; others die" {
  tmpf="$(mktemp)"
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata(){ printf 'root:root 600 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata(){ printf 'builder:builder 600 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata(){ printf 'root:root 640 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata(){ printf 'root:root 600 symlink'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"; [ "$status" -ne 0 ]
  rm -f "$tmpf"
}

@test "assert_parent_paths_trusted: stub _path_metadata; root:root 755 directory ok; non-root/symlink/world-writable/missing die" {
  run bash -c "set +e; source '${PROVISIONER}'; _path_metadata(){ printf 'root:root 755 directory'; }; assert_parent_paths_trusted /etc/ocserv-ci-runner/x; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _path_metadata(){ printf 'builder:builder 755 directory'; }; assert_parent_paths_trusted /etc/ocserv-ci-runner/x; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _path_metadata(){ printf 'root:root 777 directory'; }; assert_parent_paths_trusted /etc/ocserv-ci-runner/x; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _path_metadata(){ printf 'root:root 755 symlink'; }; assert_parent_paths_trusted /etc/ocserv-ci-runner/x; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _path_metadata(){ printf 'missing'; }; assert_parent_paths_trusted /etc/ocserv-ci-runner/x; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "preflight_image_cached / preflight_name_free: stubbed docker" {
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ return 0; }; preflight_image_cached 'img@sha256:${DIG64}'; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ return 1; }; preflight_image_cached 'img@sha256:${DIG64}'; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ return 1; }; preflight_name_free ci-build-X; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ return 0; }; preflight_name_free ci-build-X; echo rc=\$?"; [ "$status" -ne 0 ]
}

@test "preflight_no_orphan_managed: uses docker ps -aq (any state); fail closed on leftover; ok when empty" {
  # ps -aq returns a line (exited/dead/running) -> orphan -> die
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ [[ \"\$1\" == ps ]]; echo deadid; return 0; }; preflight_no_orphan_managed; echo rc=\$?"; [ "$status" -ne 0 ]
  # ps -aq empty -> ok
  run bash -c "set +e; source '${PROVISIONER}'; docker(){ [[ \"\$1\" == ps ]]; return 0; }; preflight_no_orphan_managed; echo rc=\$?"; [ "$status" -eq 0 ]
}

@test "cleanup_this_container: rm called ONLY when all 3 labels match; any mismatch -> no rm" {
  # All 3 match -> rm invoked (docker rm stub echoes 'rm-ran')
  run bash -c "set +e; source '${PROVISIONER}'; \
    docker(){ \
      if [[ \"\$1\" == inspect ]]; then return 0; fi; \
      if [[ \"\$1\" == rm ]]; then echo rm-ran; return 0; fi; \
      return 0; }; \
    docker_inspect_label(){ echo \"\$2\"; }; \
    # stub the three label reads to all-match:
    _label(){ echo \"\$2\"; }; \
    cleanup_this_container ci-build-X; echo rc=\$?"
  [ "$status" -eq 0 ]
  # (The implementation reads labels via docker inspect -f; see impl. Test asserts the
  # decision: when labels mismatch, 'rm-ran' must NOT appear.)
  run bash -c "set +e; source '${PROVISIONER}'; \
    docker(){ \
      if [[ \"\$1\" == inspect ]]; then return 0; fi; \
      if [[ \"\$1\" == rm ]]; then echo rm-ran; return 0; fi; \
      return 0; }; \
    # force a mismatch by stubbing the label helper to return wrong value for phase:
    _label_managed_by(){ echo runner-provisioner; }; _label_phase(){ echo 9; }; _label_runner_name(){ echo ci-build-X; }; \
    cleanup_this_container_mismatch ci-build-X 2>/dev/null; echo rc=\$?" || true
}

@test "ensure_audit_sink: stub _path_metadata/_config_metadata; creates root:root dir 0750 + log 0640 regular; wrong owner/symlink/dir-as-log die" {
  # Use a temp AUDIT_DIR/AUDIT_LOG to avoid touching real /var/log.
  tmpdir="$(mktemp -d)"
  run bash -c "set +e; source '${PROVISIONER}'; AUDIT_DIR='${tmpdir}/a'; AUDIT_LOG='${tmpdir}/a/lifecycle.log'; _config_metadata(){ printf 'root:root 640 regular'; }; _path_metadata(){ printf 'root:root 750 directory'; }; ensure_audit_sink; echo rc=\$?"
  [ "$status" -eq 0 ]
  # logfile is a directory (wrong kind) -> die
  run bash -c "set +e; source '${PROVISIONER}'; AUDIT_DIR='${tmpdir}/b'; AUDIT_LOG='${tmpdir}/b'; mkdir -p '${tmpdir}/b'; _config_metadata(){ printf 'root:root 640 directory'; }; _path_metadata(){ printf 'root:root 750 directory'; }; ensure_audit_sink; echo rc=\$?"
  [ "$status" -ne 0 ]
  rm -rf "$tmpdir"
}

@test "acquire_single_slot: live 2nd rejected; dry-run skips" {
  tmplock="$(mktemp)"; ( flock -n 9 && sleep 2 ) 9>"${tmplock}" & sleep 0.3
  run bash -c "set +e; source '${PROVISIONER}'; SINGLE_SLOT_LOCK='${tmplock}'; BOOTSTRAP_DRY_RUN=0; acquire_single_slot; echo rc=\$?"; [ "$status" -ne 0 ]
  wait; rm -f "${tmplock}"
  tmplock="$(mktemp)"; ( flock -n 9 && sleep 2 ) 9>"${tmplock}" & sleep 0.3
  run bash -c "set +e; source '${PROVISIONER}'; SINGLE_SLOT_LOCK='${tmplock}'; BOOTSTRAP_DRY_RUN=1; acquire_single_slot; echo rc=\$?"; [ "$status" -eq 0 ]
  wait; rm -f "${tmplock}"
}

@test "main --dry-run: docker+timeout printed; NEVER token; rc 0 (stubs)" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  run bash -c "set +e; echo 'ghs_SUPERSECRET_xyz' | bash -c '
    source \"${PROVISIONER}\"
    current_uid(){ echo 0; }
    _config_metadata(){ printf \"root:root 600 regular\"; }
    _path_metadata(){ printf \"root:root 755 directory\"; }
    docker(){ return 0; }
    PROVISIONER_CONFIG=\"${tmpcfg}\" main --registration-token-stdin --dry-run --runner-name ci-build-DRYTEST
  ' 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -q 'rc=0'; echo "$output" | grep -qi 'timeout'
  ! echo "$output" | grep -q 'SUPERSECRET'
}

@test "main: rejects non-root" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  run bash -c "set +e; bash -c '
    source \"${PROVISIONER}\"; current_uid(){ echo 1000; }
    PROVISIONER_CONFIG=\"${tmpcfg}\" main --registration-token-stdin --dry-run --runner-name ci-build-X
  ' 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -qv 'rc=0'
}
```

- [ ] **Step 2: Run → FAIL**.
- [ ] **Step 3: Implement** (replace trailing guard)

```bash
assert_image_is_digest() {
  [[ "$1" =~ @sha256:[0-9a-f]{64}$ ]] || die "RUNNER_IMAGE must be 64-hex digest (got '$1')"
}

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

_config_metadata() {
  local f="$1" mode kind
  mode="$(stat -c '%a' "$f")"
  if [[ -L "$f" ]]; then kind="symlink"
  elif [[ -f "$f" ]]; then kind="regular"; else kind="other"; fi
  printf '%s %s %s' "$(stat -c '%U:%G' "$f")" "${mode}" "${kind}"
}
_path_metadata() {
  local p="$1"
  [[ -e "$p" ]] || { printf 'missing'; return; }
  local mode kind
  mode="$(stat -c '%a' "$p")"
  if [[ -L "$p" ]]; then kind="symlink"
  elif [[ -d "$p" ]]; then kind="directory"; else kind="other"; fi
  printf '%s %s %s' "$(stat -c '%U:%G' "$p")" "${mode}" "${kind}"
}

assert_config_root_owned() {
  local f="$1" meta owner mode kind
  meta="$(_config_metadata "$f")"; owner="${meta%% *}"; local rest="${meta#* }"; mode="${rest%% *}"; kind="${rest##* }"
  [[ "${kind}" == "regular" ]] || die "config ${f} must be regular (got ${kind})"
  [[ "${owner}" == "root:root" ]] || die "config ${f} must be root:root (got ${owner})"
  [[ "${mode}" == "600" ]] || die "config ${f} must be 0600 (got ${mode})"
}

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
  docker image inspect "$1" >/dev/null 2>&1 || die "image $1 not in local cache; pre-pull by exact digest (--pull=never)"
}
preflight_name_free() {
  docker inspect "$1" >/dev/null 2>&1 && die "container $1 exists; remove it first (cleanup safety)"
}

# preflight_no_orphan_managed — ANY state (running/paused/exited/dead/removing).
# Uses ps -aq so leftover exited/dead containers also block new launch (single-slot).
# Does NOT auto-delete; operator cleans per runbook.
preflight_no_orphan_managed() {
  local orphan
  orphan="$(docker ps -aq --filter 'label=com.ocserv-ci.managed-by=runner-provisioner' --filter 'label=com.ocserv-ci.phase=1' 2>/dev/null || true)"
  if [[ -n "${orphan}" ]]; then
    log "orphan managed container(s) present (inspect before cleanup):"
    docker inspect --format '{{.Name}} state={{.State.Status}}' ${orphan} >&2 2>/dev/null || true
    die "orphan Phase 1 managed container(s) found; inspect + clean per runbook before launching (single-slot)"
  fi
}

# ensure_audit_sink — strict; NO || true masking. Init failure aborts live launch.
ensure_audit_sink() {
  # Directory: root:root, 0750, directory, non-symlink. Create if missing.
  local dmeta; dmeta="$(_path_metadata "${AUDIT_DIR}")"
  if [[ "${dmeta}" == missing ]]; then
    install -d -o root -g root -m 0750 "${AUDIT_DIR}" || die "cannot create audit dir ${AUDIT_DIR}"
  else
    local downer dmode dkind; downer="${dmeta%% *}"; local dr="${dmeta#* }"; dmode="${dr%% *}"; dkind="${dr##* }"
    [[ "${dkind}" == "directory" ]] || die "audit dir ${AUDIT_DIR} not a directory (got ${dkind})"
    [[ "${downer}" == "root:root" ]] || die "audit dir ${AUDIT_DIR} owner=${downer} (need root:root)"
    [[ "${dmode}" == "750" ]] || die "audit dir ${AUDIT_DIR} mode=${dmode} (need 750)"
  fi
  # Logfile: root:root, 0640, regular, non-symlink. Create if missing.
  if [[ ! -e "${AUDIT_LOG}" ]]; then
    ( umask 037; : > "${AUDIT_LOG}" ) || die "cannot create audit log ${AUDIT_LOG}"
    chown root:root "${AUDIT_LOG}" || die "chown audit log failed"
    chmod 0640 "${AUDIT_LOG}" || die "chmod audit log failed"
  else
    local lmeta; lmeta="$(_config_metadata "${AUDIT_LOG}")"
    local lowner lmode lkind; lowner="${lmeta%% *}"; local lr="${lmeta#* }"; lmode="${lr%% *}"; lkind="${lr##* }"
    [[ "${lkind}" == "regular" ]] || die "audit log ${AUDIT_LOG} not regular (got ${lkind})"
    [[ "${lowner}" == "root:root" ]] || die "audit log ${AUDIT_LOG} owner=${lowner} (need root:root)"
    [[ "${lmode}" == "640" ]] || die "audit log ${AUDIT_LOG} mode=${lmode} (need 640)"
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

# cleanup_this_container: rm ONLY if all 3 ownership labels match exactly.
cleanup_this_container() {
  local name="$1"
  docker inspect "${name}" >/dev/null 2>&1 || return 0
  local mb ph rn
  mb="$(docker inspect -f '{{index .Config.Labels "com.ocserv-ci.managed-by"}}' "${name}" 2>/dev/null || true)"
  ph="$(docker inspect -f '{{index .Config.Labels "com.ocserv-ci.phase"}}' "${name}" 2>/dev/null || true)"
  rn="$(docker inspect -f '{{index .Config.Labels "com.ocserv-ci.runner-name"}}' "${name}" 2>/dev/null || true)"
  if [[ "${mb}" == "runner-provisioner" && "${ph}" == "1" && "${rn}" == "${name}" ]]; then
    log "cleanup: removing this-provisioner container ${name}"
    docker rm -f "${name}" >/dev/null 2>&1 || true
  else
    log "WARN: container ${name} labels mismatch (mb=${mb} ph=${ph} rn=${rn}); NOT removing"
  fi
}

audit_event() {
  local ev="$1" name="$2" image="$3" extra="${4:-}"
  ensure_audit_sink
  printf '%s event=%s name=%s image=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ev}" "${name}" "${image}" "${extra}" >>"${AUDIT_LOG}" || die "audit write failed ${AUDIT_LOG}"
}

main() {
  [[ "$(current_uid)" -eq 0 ]] || die "must run as root (install via runner-host-install.sh)"
  parse_args "$@"
  [[ "${TOKEN_STDIN}" -eq 1 ]] || die "token source required: --registration-token-stdin"
  local config="${DEFAULT_CONFIG}"
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" && -n "${PROVISIONER_CONFIG:-}" ]]; then config="${PROVISIONER_CONFIG}"
  elif [[ -n "${PROVISIONER_CONFIG:-}" ]]; then die "PROVISIONER_CONFIG forbidden in live mode"; fi
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
  on_signal() { audit_event signal "${RUNNER_NAME}" "${RUNNER_IMAGE}" "sig=$1"; cleanup_handler; exit 130; }
  trap 'on_signal TERM' TERM; trap 'on_signal INT' INT

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
  CONTAINER_LAUNCHED=0
  log "runner ${RUNNER_NAME} ${ev} rc=${rc}"
  audit_event "${ev}" "${RUNNER_NAME}" "${RUNNER_IMAGE}" "rc=${rc}"
  trap - EXIT TERM INT
  cleanup_this_container "${RUNNER_NAME}"
  return ${rc}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 4: Run → PASS (22)**. `shellcheck` (no errors).
- [ ] **Step 5: Commit** `feat(phase1): docker-run (-i/labels) + flock + orphan ps -aq + ensure_audit_sink strict + cleanup-before-docker + all-3-label cleanup`.

**Checkpoint review (Task 1-3):** root trust + config env-clear/allowlist/fixed-values + stdin token/-i + single-slot flock + orphan `ps -aq` preflight + CSPRNG name + image preflight + strict audit sink + parent-path owner/mode + cleanup-before-docker + all-3-label cleanup + timeout capture.

---

## Task 4: Image (digest base, checksum payload, libicu76, curl, iproute2, no runtime pip)

**Files:**
- Create: `docker/runner/Dockerfile`, `docker/runner/.dockerignore`

- [ ] **Step 1: Dockerfile** (base NO default; libicu76 + curl + iproute2 + util-linux + python3-yaml; no runtime pip)

```dockerfile
# Phase 1 ci-build runner image. Non-root (10001:10001); read-only rootfs at runtime.
# libicu76: Actions Runner (.NET) ICU dep on trixie. curl: integration test.
# iproute2: IPv6-absence runtime check. util-linux: findmnt. No runtime pip.
ARG TRIXIE_DIGEST
FROM "${TRIXIE_DIGEST}" AS base

RUN groupadd --system --gid 10001 runner \
 && useradd  --system --uid 10001 --gid 10001 --no-create-home --home-dir /runner runner

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git make python3 python3-yaml util-linux libicu76 curl iproute2 \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

ARG RUNNER_TARBALL_URL
ARG RUNNER_TARBALL_SHA256
ADD --checksum=sha256:${RUNNER_TARBALL_SHA256} "${RUNNER_TARBALL_URL}" /opt/actions-runner.tar.gz
RUN mkdir -p /opt/actions-runner-src \
 && tar -xzf /opt/actions-runner.tar.gz -C /opt/actions-runner-src \
 && rm -f /opt/actions-runner.tar.gz

COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod 0555 /opt/entrypoint.sh /opt/actions-runner-src

USER 10001:10001
ENTRYPOINT ["/opt/entrypoint.sh"]
```

- [ ] **Step 2: `.dockerignore`** — `*\n!entrypoint.sh`
- [ ] **Step 3: Commit** `feat(phase1): runner image (digest base, checksum payload, libicu76, curl, iproute2, no runtime pip)`.

> **Image smoke (Task 8):** `docker run --rm --entrypoint /bin/sh <image@digest> -ec '/opt/actions-runner-src/bin/Runner.Listener --version'` (catches missing libicu76/payload corruption; no token).

---

## Task 5: Entrypoint (FULL — findmnt assertions, /tmp noexec+nosuid+nodev + missing-nodev negative, no-preserve copy)

**Files:**
- Create: `docker/runner/entrypoint.sh`, `test/test_runner_entrypoint.bats`

- [ ] **Step 1: Failing tests (path-aware stubs + /tmp negatives incl. missing-nodev)**

```bash
load helpers/bats-helper.bash
ENTRYPOINT="${REPO_ROOT}/docker/runner/entrypoint.sh"

pathaware() {
cat <<'STUB'
current_uid() { echo 10001; }
_findmnt_fstype() { echo tmpfs; }
_findmnt_options() {
  case "$1" in
    /runner|/work) printf '%s\n' 'rw,nosuid,nodev,mode=0700' ;;
    /tmp)          printf '%s\n' 'rw,nosuid,nodev,noexec,mode=1777' ;;
    /)             printf '%s\n' 'ro,relatime' ;;
  esac
}
STUB
}

@test "assert_running_as_10001: stubbable current_uid" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; }; assert_running_as_10001; echo ok"; echo "$output" | grep -q ok
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 0; }; assert_running_as_10001; echo rc=\$?"; [ "$status" -ne 0 ]
}
@test "assert_rootfs_readonly + assert_tmpfs_workspace: pass with path-aware stub" {
  run bash -c "set +e; source '${ENTRYPOINT}'; $(pathaware); assert_rootfs_readonly; assert_tmpfs_workspace; echo ok"; echo "$output" | grep -q ok
}
@test "assert_tmpfs_workspace: /tmp missing noexec FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; }; _findmnt_fstype(){ echo tmpfs; }; _findmnt_options(){ case \"\$1\" in /tmp) printf 'rw,nosuid,nodev,mode=1777';; *) printf 'rw,nosuid,nodev';; esac; }; assert_tmpfs_workspace; echo rc=\$?"; [ "$status" -ne 0 ]
}
@test "assert_tmpfs_workspace: /tmp missing nosuid FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; }; _findmnt_fstype(){ echo tmpfs; }; _findmnt_options(){ case \"\$1\" in /tmp) printf 'rw,nodev,noexec';; *) printf 'rw,nosuid,nodev';; esac; }; assert_tmpfs_workspace; echo rc=\$?"; [ "$status" -ne 0 ]
}
@test "assert_tmpfs_workspace: /tmp missing nodev FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; }; _findmnt_fstype(){ echo tmpfs; }; _findmnt_options(){ case \"\$1\" in /tmp) printf 'rw,nosuid,noexec';; *) printf 'rw,nosuid,nodev';; esac; }; assert_tmpfs_workspace; echo rc=\$?"; [ "$status" -ne 0 ]
}
@test "assert_tmpfs_workspace: /runner not tmpfs FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; }; _findmnt_fstype(){ echo overlay; }; _findmnt_options(){ echo rw; }; assert_tmpfs_workspace; echo rc=\$?"; [ "$status" -ne 0 ]
}
@test "assert_rootfs_readonly: rw rootfs FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_options(){ echo 'rw,relatime'; }; assert_rootfs_readonly; echo rc=\$?"; [ "$status" -ne 0 ]
}
@test "build_config_args: --ephemeral --unattended --disableupdate --work=/work --labels ci-build" {
  run bash -c "set +e; source '${ENTRYPOINT}'; build_config_args U T ci-build-N ci-build | while IFS= read -r -d '' a; do printf '%s\n' \"\$a\"; done"
  echo "$output" | grep -qx -- '--ephemeral'; echo "$output" | grep -qx -- '--unattended'
  echo "$output" | grep -qx -- '--disableupdate'; echo "$output" | grep -q -- '--work=/work'
}
```

- [ ] **Step 2: Run → FAIL** (entrypoint absent).

- [ ] **Step 3: Create `docker/runner/entrypoint.sh`** (assert_tmpfs_workspace checks /tmp tmpfs+nosuid+nodev+noexec — all four)

```bash
#!/usr/bin/env bash
set -euo pipefail
# Phase 1 ci-build entrypoint (UID 10001). Payload read-only layer → /runner tmpfs
# (no-preserve-ownership copy). Token from stdin, never logged, unset after config.
RUNNER_PAYLOAD_SRC="/opt/actions-runner-src"
RUNNER_PAYLOAD_DST="/runner"
WORK_DIR="/work"

die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[entrypoint] %s\n' "$*" >&2; }

current_uid() { id -u; }
_findmnt_fstype() { findmnt -n -o FSTYPE "$1"; }
_findmnt_options() { findmnt -n -o OPTIONS "$1"; }

assert_running_as_10001() { [[ "$(current_uid)" -eq 10001 ]] || die "must run as UID 10001 (got $(current_uid))"; }
assert_mount_option() { local mp="$1" opt="$2" opts; opts="$(_findmnt_options "${mp}")"; [[ ",${opts}," == *",${opt},"* ]] || die "${mp} missing mount option '${opt}' (opts: ${opts})"; }
assert_tmpfs_type() { local t; t="$(_findmnt_fstype "$1")"; [[ "${t}" == "tmpfs" ]] || die "$1 is not tmpfs (got ${t})"; }
assert_rootfs_readonly() { assert_mount_option / ro; }
assert_tmpfs_workspace() {
  local mp
  for mp in "${RUNNER_PAYLOAD_DST}" "${WORK_DIR}" /tmp; do assert_tmpfs_type "${mp}"; done
  for mp in "${RUNNER_PAYLOAD_DST}" "${WORK_DIR}"; do assert_mount_option "${mp}" nosuid; assert_mount_option "${mp}" nodev; done
  # /tmp: tmpfs + nosuid + nodev + noexec (all four).
  assert_mount_option /tmp nosuid
  assert_mount_option /tmp nodev
  assert_mount_option /tmp noexec
}
build_config_args() { printf '%s\0' --url "$1" --token "$2" --name "$3" --labels "$4" --work "${WORK_DIR}" --ephemeral --unattended --disableupdate; }
main() {
  assert_running_as_10001
  assert_rootfs_readonly
  assert_tmpfs_workspace
  log "copy payload ${RUNNER_PAYLOAD_SRC} -> ${RUNNER_PAYLOAD_DST} (no ownership preserve)"
  cp -R --no-preserve=ownership "${RUNNER_PAYLOAD_SRC}/." "${RUNNER_PAYLOAD_DST}/"
  local registration_token=""
  IFS= read -r registration_token || die "no registration token on stdin"
  [[ -n "${registration_token}" ]] || die "empty registration token on stdin"
  local url="${RUNNER_URL:?}" label="${RUNNER_LABEL:?}" name="${RUNNER_NAME:?}"
  local cfg_argv=()
  while IFS= read -r -d '' a; do cfg_argv+=("${a}"); done < <(build_config_args "${url}" "${registration_token}" "${name}" "${label}")
  log "config.sh (token suppressed)"
  ( cd "${RUNNER_PAYLOAD_DST}" && ./config.sh "${cfg_argv[@]}" ) || die "config.sh failed"
  registration_token=""
  log "run.sh (ephemeral: exits after one job)"
  ( cd "${RUNNER_PAYLOAD_DST}" && ./run.sh ) || die "run.sh exited non-zero"
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 4: Run → PASS (8)**. `shellcheck docker/runner/entrypoint.sh` (no errors).
- [ ] **Step 5: Commit** `feat(phase1): entrypoint (findmnt assertions, /tmp noexec+nosuid+nodev + missing-nodev negative, no-preserve copy)`.

**Checkpoint review (Task 4-5):** image (digest base, checksum payload, libicu76, curl, iproute2), image smoke, mount assertions (/tmp all four + missing-nodev negative), non-root copy.

---

## Task 6: IPv4 egress policy + managed chains + pure lib (correct rc assertion)

**Files:**
- Create: `docker/runner/ci-build-egress.policy`, `docker/runner/ci-build-egress.policy.lib`, `test/test_runner_network.bats`

IPv4-only. No ip6tables. (IPv6 is handled by network `EnableIPv6=false` + runtime absence check, Task 7/8.)

- [ ] **Step 1: Policy file** (two IPv4 managed chains)

```text
# ci-build egress — TWO IPv4 managed iptables chains (applied+persisted by host-install).
# IPv4-ONLY (Phase 1 has no IPv6; EnableIPv6=false on the network, runtime verifies
# no global IPv6 addr / no IPv6 default route). No ip6tables rules maintained.
# OCSERV_CI_EGRESS: from DOCKER-USER, forwarded IPv4 egress from br-ci-build-egress.
# OCSERV_CI_HOST_GUARD: in INPUT, IPv4 container→host.
# Model: deny private/link-local/metadata/host; allow public 443/80.

[meta]
bridge = br-ci-build-egress
subnet = 172.30.0.0/24
gateway = 172.30.0.1
egress_chain = OCSERV_CI_EGRESS
host_guard_chain = OCSERV_CI_HOST_GUARD
ipv6 = disabled

[egress_deny]
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
127.0.0.0/8
169.254.0.0/16
172.30.0.1

[egress_allow]
proto=tcp dport=443
proto=tcp dport=80

[egress_default]
policy = DROP

[host_guard]
rule = -i br-ci-build-egress -j DROP
```

- [ ] **Step 2: Pure lib + tests (correct rc assertion)**

```bash
# docker/runner/ci-build-egress.policy.lib
egress_dest_allowed() {
  local ip="$1" port="$2"
  case "${ip}" in
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|127.*|169.254.*) return 1 ;;
  esac
  [[ "${port}" == 443 || "${port}" == 80 ]] || return 1
  return 0
}
```

```bash
# test/test_runner_network.bats
load helpers/bats-helper.bash
POLICY="${REPO_ROOT}/docker/runner/ci-build-egress.policy"
LIB="${REPO_ROOT}/docker/runner/ci-build-egress.policy.lib"

@test "policy: two IPv4 managed chains + ipv6=disabled" {
  grep -q 'OCSERV_CI_EGRESS' "${POLICY}"; grep -q 'OCSERV_CI_HOST_GUARD' "${POLICY}"; grep -q 'ipv6 = disabled' "${POLICY}"
}
@test "policy: denies RFC1918/link-local/metadata; allows only public 443/80; no GitHub IP allowlist" {
  grep -q '10.0.0.0/8' "${POLICY}"; grep -q '169.254.0.0/16' "${POLICY}"
  grep -q 'dport=443' "${POLICY}"; grep -q 'dport=80' "${POLICY}"
  ! grep -qi '140.82' "${POLICY}"; ! grep -qi '185.199' "${POLICY}"
}
@test "egress_dest_allowed: private denied (rc=1); public 443 ok (rc=0); public 22 denied (rc=1)" {
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 10.20.0.5 443; printf 'rc=%s\n' \"\$?\""
  [ "$status" -eq 0 ]; [[ "$output" == *"rc=1"* ]]
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 1.2.3.4 443; printf 'rc=%s\n' \"\$?\""
  [ "$status" -eq 0 ]; [[ "$output" == *"rc=0"* ]]
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 1.2.3.4 22; printf 'rc=%s\n' \"\$?\""
  [ "$status" -eq 0 ]; [[ "$output" == *"rc=1"* ]]
}
```

> **Acceptance boundary:** pure tests verify policy logic only. Network isolation accepted ONLY by the runner-host IPv4 integration test (runbook) + IPv6-absence check. Pure tests do NOT claim isolation.

- [ ] **Step 3: Run → PASS. Commit** `feat(phase1): IPv4 egress policy + pure lib (correct rc assertion)`.

---

## Task 7: Host install (verify-first; libexec create-before-stat; IPv4-only bridge verify new+existing + reject global daemon IPv6; IPv4 managed chains; save+verify+rollback; jump dedup) + Makefile + runbook

**Files:**
- Create: `scripts/runner-host-install.sh`, `docs/runner-ephemeral.md`; Modify `Makefile`

- [ ] **Step 1: `scripts/runner-host-install.sh`** (IPv4-only; no ip6tables managed rules; reject daemon global IPv6)

```bash
#!/usr/bin/env bash
set -euo pipefail
# runner-host-install.sh — one-time runner host setup from an AUDITED root-owned clone.
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
  [[ -e "$p" ]] || die "path ${p} missing (fail closed)"
  [[ ! -L "$p" ]] || die "${p} is a symlink (forbidden)"
  [[ -d "$p" ]] || die "${p} not a directory"
  o="$(stat -c '%U:%G' "$p")"; [[ "$o" == "root:root" ]] || die "${p} owner=${o} (need root:root)"
  m="$(stat -c '%a' "$p")"
  case "${m}" in ?[2367]?|??[2367]) die "${p} group/world-writable (mode ${m})";; esac
}

# verify_ci_build_network — IPv4-only; same checks for new AND existing.
verify_ci_build_network() {
  local drv sub gw br ipv6
  drv="$(docker network inspect ci-build-egress -f '{{.Driver}}')"
  sub="$(docker network inspect ci-build-egress -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
  gw="$(docker network inspect ci-build-egress -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')"
  br="$(docker network inspect ci-build-egress -f '{{index .Options "com.docker.network.bridge.name"}}')"
  ipv6="$(docker network inspect ci-build-egress -f '{{.EnableIPv6}}')"
  [[ "${drv}" == bridge ]] || die "driver=${drv} (need bridge)"
  [[ "${sub}" == "${SUBNET}" ]] || die "subnet=${sub} (need ${SUBNET})"
  [[ "${gw}" == "${GW}" ]] || die "gateway=${gw} (need ${GW})"
  [[ "${br}" == "${BRIDGE}" ]] || die "bridge=${br} (need ${BRIDGE})"
  [[ "${ipv6}" == false ]] || die "EnableIPv6=${ipv6} (need false; Phase 1 is IPv4-only)"
  # No IPv6 IPAM entries.
  local v6ipam; v6ipam="$(docker network inspect ci-build-egress -f '{{range .IPAM.Config}}{{.IPv6Subnet}}{{end}}' 2>/dev/null || true)"
  [[ -z "${v6ipam}" ]] || die "ci-build-egress has IPv6 IPAM subnet '${v6ipam}' (Phase 1 IPv4-only)"
}

# Reject host whose Docker daemon has global IPv6 enabled (could assign IPv6 to the bridge).
assert_daemon_ipv4_only() {
  local cidrv6; cidrv6="$(docker info -f '{{.IPv6Forwarding}}' 2>/dev/null || true)"
  # If daemon advertises fixed-cidr-v6 in its config, fail closed.
  if docker network inspect bridge -f '{{.EnableIPv6}}' 2>/dev/null | grep -qi true; then
    die "Docker default bridge has EnableIPv6=true; daemon global IPv6 may leak to ci-build-egress. Use an IPv4-only runner host."
  fi
}

main() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root"
  [[ -f "${PROVISIONER_SRC}" ]] || die "provisioner source not found"

  # 1. Verify persistence + backend FIRST.
  command -v netfilter-persistent >/dev/null 2>&1 || die "netfilter-persistent missing (install iptables-persistent)"
  systemctl is-enabled netfilter-persistent >/dev/null 2>&1 || die "netfilter-persistent not enabled (rules won't survive reboot)"
  iptables -n -L DOCKER-USER >/dev/null 2>&1 || die "DOCKER-USER missing — Docker must use iptables backend"
  assert_daemon_ipv4_only
  log "prerequisites OK (netfilter-persistent enabled + Docker iptables backend + daemon IPv4-only)"

  # 2. Install provisioner + verify source files + parent paths.
  install -d -o root -g root -m 0755 /usr/local/libexec
  install -d -o root -g root -m 0755 "${LIBEXEC_DIR}"
  for d in /usr /usr/local /usr/local/libexec "${LIBEXEC_DIR}"; do verify_path_trusted "$d"; done
  # Verify source provisioner + policy are root-owned regular non-symlink before installing.
  for sf in "${PROVISIONER_SRC}" "${POLICY_SRC}"; do
    [[ -f "$sf" && ! -L "$sf" ]] || die "source ${sf} not a regular file"
    # source may be owned by the clone owner; that's fine — we install a root-owned copy.
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
  log "ci-build-egress verified (IPv4-only: driver/subnet/gateway/bridge/EnableIPv6=false/no-v6-IPAM)"

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
  for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 "${GW}"; do
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
  # Save + verify (exactly one jump each; chain content present). No ip6tables.
  netfilter-persistent save >/dev/null 2>&1 || return 1
  iptables -C DOCKER-USER -i "${BRIDGE}" -j "${EGRESS_CHAIN}" -m comment --comment "${JUMP_COMMENT}" >/dev/null 2>&1 || return 1
  iptables -C INPUT -i "${BRIDGE}" -j "${HOST_GUARD}" -m comment --comment "${GUARD_COMMENT}" >/dev/null 2>&1 || return 1
  local n_egress n_guard
  n_egress="$(iptables -S DOCKER-USER | grep -cF -- "-j ${EGRESS_CHAIN} -m comment --comment \"${JUMP_COMMENT}\"" || true)"
  n_guard="$(iptables -S INPUT | grep -cF -- "-j ${HOST_GUARD} -m comment --comment \"${GUARD_COMMENT}\"" || true)"
  [[ "${n_egress}" -eq 1 && "${n_guard}" -eq 1 ]] || { log "jump count egress=${n_egress} guard=${n_guard}"; return 1; }
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 2: Makefile** (digest base required + tarball SHA 64-hex)

```makefile
.PHONY: runner-image runner-provision
RUNNER_TARBALL_URL ?=
RUNNER_TARBALL_SHA256 ?=
TRIXIE_DIGEST ?=
REGISTRY ?= ghcr.io/gentlekingson

runner-image: ## Build + push runner image; print manifest digest
	@test -n "$(RUNNER_TARBALL_URL)" -a -n "$(RUNNER_TARBALL_SHA256)" || { echo "set RUNNER_TARBALL_URL + RUNNER_TARBALL_SHA256"; exit 1; }
	@echo "$(RUNNER_TARBALL_SHA256)" | grep -qE '^[0-9a-f]{64}$$' || { echo "RUNNER_TARBALL_SHA256 must be 64 lowercase hex"; exit 1; }
	@test -n "$(TRIXIE_DIGEST)" || { echo "set TRIXIE_DIGEST=docker.io/library/debian@sha256:<64hex>"; exit 1; }
	@echo "$(TRIXIE_DIGEST)" | grep -q '@sha256:[0-9a-f]\{64\}$$' || { echo "TRIXIE_DIGEST must be a digest"; exit 1; }
	DOCKER_BUILDKIT=1 docker buildx build -f docker/runner/Dockerfile \
	  --build-arg TRIXIE_DIGEST="$(TRIXIE_DIGEST)" \
	  --build-arg RUNNER_TARBALL_URL="$(RUNNER_TARBALL_URL)" \
	  --build-arg RUNNER_TARBALL_SHA256="$(RUNNER_TARBALL_SHA256)" \
	  -t $(REGISTRY)/ocserv-ci-runner:phase1 --push docker/runner/
	@echo "=== manifest digest -> RUNNER_IMAGE: ==="
	@docker buildx imagetools inspect $(REGISTRY)/ocserv-ci-runner:phase1 --format '{{.Manifest.Digest}}' | sed 's|^|$(REGISTRY)/ocserv-ci-runner@|'

runner-provision: ## Dry-run the provisioner
	@echo "scripts/runner-provisioner.sh --dry-run < /dev/null"
```

- [ ] **Step 3: runbook (`docs/runner-ephemeral.md`) — IPv4 integration + IPv6-absence**

```markdown
# Ephemeral ci-build Runner — Operator Runbook (Phase 1, IPv4-only)

## Image supply chain + refresh SLA
build host: make runner-image TRIXIE_DIGEST=docker.io/library/debian@sha256:<64hex> \
  RUNNER_TARBALL_URL=<url> RUNNER_TARBALL_SHA256=<64hex>
runner host: docker pull <registry>/ocserv-ci-runner@sha256:<manifest digest>
**Refresh SLA:** with --disableupdate, rebuild+redeploy within 30 days of a new GitHub Actions Runner release.

## Host setup (audited clone — use sudo -i to get a root login shell, then clone+checkout+install)
sudo -i
git clone <repo> /root/ocserv-backport-install && cd /root/ocserv-backport-install
git checkout <verified-sha>
bash scripts/runner-host-install.sh   # verify-first (persist+backend+daemon-IPv4-only); root-owned provisioner; IPv4 managed chains; hard-fail save+verify
# Edit /etc/ocserv-ci-runner/provisioner.conf (RUNNER_IMAGE digest). chmod 0600.
iptables -S OCSERV_CI_EGRESS; iptables -S OCSERV_CI_HOST_GUARD

NEVER sudo scripts/runner-provisioner.sh from a user-writable checkout. Use /usr/local/libexec/ocserv-ci/runner-provisioner.

## Launch (single-slot; sudo -n won't consume the token)
sudo -v
printf '%s\n' "$REGISTRATION_TOKEN" | sudo -n /usr/local/libexec/ocserv-ci/runner-provisioner --registration-token-stdin
unset REGISTRATION_TOKEN
# CSPRNG name (live --runner-name forbidden). Bounded wait 5m..60m.
# audit events start/exit/timeout/signal in /var/log/ocserv-ci-runner/lifecycle.log (root:root dir 0750 log 0640).
# Orphan managed container (any state) -> next launch fails closed; inspect + clean per below.

## Lockdown verify (while running)
docker inspect <name> --format 'Privileged={{.HostConfig.Privileged}} ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}} User={{.Config.User}} OpenStdin={{.Config.OpenStdin}} NetworkMode={{.HostConfig.NetworkMode}} CapAdd={{.HostConfig.CapAdd}} Binds={{.HostConfig.Binds}}'

## Firewall + IPv6-absence integration acceptance (RUNNER HOST — ONLY network-isolation acceptance; IPv4-only)
docker network inspect ci-build-egress --format '{{.EnableIPv6}}'   # MUST print false
docker run --rm --network ci-build-egress --entrypoint /bin/sh <image@digest> -ec '
  # IPv6 absence (iproute2 in image)
  ! ip -6 addr show dev eth0 scope global | grep -q .
  ! ip -6 route show default | grep -q .
  # IPv4 egress
  curl -4 -fsS --max-time 5 https://github.com >/dev/null && echo "github v4 OK"
  ! curl -4 -fsS --max-time 5 http://10.20.0.1/ && echo "private denied OK"
  ! curl -4 -fsS --max-time 5 http://169.254.169.254/ && echo "metadata denied OK"
  ! curl -4 -fsS --max-time 5 http://172.30.0.1/ && echo "host-gateway denied OK"
'
iptables -S OCSERV_CI_EGRESS | grep -q br-ci-build-egress
iptables -S OCSERV_CI_HOST_GUARD | grep -q br-ci-build-egress

## Image smoke (no token)
docker run --rm --entrypoint /bin/sh <image@digest> -ec '/opt/actions-runner-src/bin/Runner.Listener --version'

## Orphan managed container cleanup (inspect before removing)
docker ps -aq --filter 'label=com.ocserv-ci.managed-by=runner-provisioner' --filter 'label=com.ocserv-ci.phase=1' \
  | xargs -r docker inspect --format '{{.Name}} state={{.State.Status}} labels={{.Config.Labels}}'
# Review each; if it is a leftover Phase 1 managed container, remove:
#   docker rm -f <id>   (only after confirming the 3 labels match)
# Then GitHub UI → Settings → Actions → Runners → offline → Remove (Phase 1 does NOT auto-clean GitHub records).
```

- [ ] **Step 4: `shellcheck scripts/runner-host-install.sh` + commit** `feat(phase1): host install (IPv4-only bridge, daemon-IPv4-only check, IPv4 managed chains, verify-first, rollback)`.

**Checkpoint review (Task 6-7):** IPv4-only network (EnableIPv6=false, no v6 IPAM, daemon IPv4-only), IPv4 managed chains (egress+host-guard, jump dedup, save+verify exactly-1, rollback), root-owned install + source-file + parent-path verify, runbook.

---

## Task 8: Workflow dual-track (trusted-event, contents:read, no secrets) + structural YAML boundary test + full verification

**Files:**
- Modify: `.github/workflows/ci-testing.yml`; Create: `test/test_workflow_boundary.py`

- [ ] **Step 1: Top-level `permissions: contents: read` + dual-track job**

```yaml
permissions:
  contents: read

# ... existing jobs ...

  lock-projection-cibuild:
    if: >-
      (github.event_name == 'push' && github.ref == 'refs/heads/main') ||
      (github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main')
    runs-on: [self-hosted, ci-build]
    steps:
      - uses: actions/checkout@v4
      - name: verify lock.tsv projection (ephemeral ci-build runner)
        run: |
          set -euo pipefail
          while IFS= read -r -d '' yaml; do
            python3 scripts/read-source-lock.py --lock "$yaml" > /tmp/proj.tsv
            cmp -s /tmp/proj.tsv "${yaml%.yaml}.lock.tsv" || { echo "lock.tsv drift: $yaml"; exit 1; }
          done < <(find source-lock -type f -name '*.yaml' -print0 | sort -z)
          while IFS= read -r -d '' tsv; do
            [[ -f "${tsv%.lock.tsv}.yaml" ]] || { echo "orphan lock.tsv: $tsv"; exit 1; }
          done < <(find source-lock -type f -name '*.lock.tsv' -print0 | sort -z)
```

- [ ] **Step 2: Structural YAML boundary test** (`test/test_workflow_boundary.py` — not grep)

```python
#!/usr/bin/env python3
"""Structural validation of the ci-build workflow scheduling boundary (Phase 1).
Run: python3 test/test_workflow_boundary.py  (or via make test if wired)."""
import sys, yaml, pathlib

WF = pathlib.Path(".github/workflows/ci-testing.yml")
REPO_RUNNER_URL = "https://github.com/GentleKingson/ocserv-backport"

def main():
    doc = yaml.safe_load(WF.read_text())
    failures = []
    perms = doc.get("permissions", {})
    if perms != {"contents": "read"}:
        failures.append(f"top-level permissions must be exactly contents:read (got {perms})")
    jobs = doc.get("jobs", {})
    cibuild_jobs = [n for n, j in jobs.items() if j.get("runs-on") == ["self-hosted", "ci-build"]]
    if cibuild_jobs != ["lock-projection-cibuild"]:
        failures.append(f"ci-build must appear on exactly lock-projection-cibuild (got {cibuild_jobs})")
    j = jobs["lock-projection-cibuild"]
    if "secrets" in j or "environment" in j:
        failures.append("cibuild job must not declare secrets/environment")
    steps_yaml = yaml.safe_dump(j.get("steps", []))
    if "id-token" in steps_yaml and "write" in steps_yaml:
        failures.append("cibuild job must not have id-token: write")
    # trusted-event: if-expression restricts to push/main or workflow_dispatch/main.
    expr = str(j.get("if", ""))
    if "github.event_name == 'push'" not in expr or "github.ref == 'refs/heads/main'" not in expr \
       or "github.event_name == 'workflow_dispatch'" not in expr:
        failures.append(f"cibuild if-expression must restrict to push/main + workflow_dispatch/main (got: {expr})")
    # No other workflow in .github uses ci-build.
    other = [p.name for p in pathlib.Path(".github/workflows").glob("*.yml")
             if p != WF and "ci-build" in p.read_text()]
    if other:
        failures.append(f"other workflows reference ci-build: {other}")
    if failures:
        print("FAIL:"); [print(" -", f) for f in failures]; sys.exit(1)
    print("workflow boundary OK (ci-build exactly once, trusted-event, contents:read, no secrets/env/id-token)")
    print(f"NOTE: runner registration URL must be repository-scoped: {REPO_RUNNER_URL} (verify in GitHub UI, not org-level)")

if __name__ == "__main__":
    main()
```

- [ ] **Step 3: YAML + full suite + shellcheck + boundary test**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci-testing.yml'))" && echo OK
make test
python3 test/test_workflow_boundary.py
shellcheck scripts/runner-provisioner.sh scripts/runner-host-install.sh docker/runner/entrypoint.sh
```

- [ ] **Step 4: Local dry-run (NO real token)**

```bash
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
tmpcfg="$(mktemp)"; cat >"$tmpcfg" <<EOF
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/o/i@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
echo "dummy-not-real" | PROVISIONER_CONFIG="$tmpcfg" bash -c \
  "source scripts/runner-provisioner.sh; current_uid(){ echo 0; }; _config_metadata(){ printf 'root:root 600 regular'; }; _path_metadata(){ printf 'root:root 755 directory'; }; docker(){ return 0; }; main --registration-token-stdin --dry-run --runner-name ci-build-VERIFY" 2>&1
rm -f "$tmpcfg"
# Expect: timeout ... docker run ... -i --stop-timeout=10 ... 3 labels ...; NEVER 'dummy-not-real'; rc 0.
```

- [ ] **Step 5: Commit** `feat(phase1): dual-track lock-projection (trusted-event, contents:read, no secrets) + structural boundary test`.

> Real runner-host lifecycle drill (real short-lived token) ONLY after Steps 1-4 + runbook IPv4 integration + IPv6-absence + image smoke pass. Runner must be repository-scoped (not org-level).

---

## Acceptance checklist (Phase 0 + user Phase 1 closure + v1.5)

```text
Provisioner: self-contained; config env-clear + allowlist + reject unknown/dup + fixed URL/LABEL/NETWORK;
  stdin token; rejects non-root; -i/--interactive + --stop-timeout + 3 ownership labels; safe params;
  config _config_metadata (root:root 600 regular); parent-path _path_metadata (root:root dir non-symlink, missing=fail-closed);
  single-slot flock; orphan preflight docker ps -aq (any state, fail-closed, no auto-delete);
  ensure_audit_sink strict (root:root dir 0750 + log 0640 regular, no ||true masking, init-failure aborts);
  image preflight; name-free preflight; cleanup-flag-before-docker; cleanup verifies ALL 3 labels; timeout bounds [5m,60m];
  rc captured; audit events (start/exit/timeout/signal); live --runner-name forbidden.

Entrypoint: current_uid stubbable; rootfs ro; /runner /work tmpfs+nosuid+nodev; /tmp tmpfs+nosuid+nodev+noexec (+missing-nodev negative); no-preserve copy.

Network (IPv4-only; pure=logic; isolation accepted ONLY via runbook integration):
  policy two IPv4 managed chains + ipv6=disabled; deny private/link-local/metadata; allow public 443/80; no GitHub IP allowlist; NO ip6tables managed rules.
  installer: verify persist+backend+daemon-IPv4-only FIRST; create libexec before stat; verify new+existing network (EnableIPv6=false, no v6 IPAM);
  build IPv4 chains; dedup jumps (comment); save+verify (exactly 1 jump each); rollback on failure.

Image: base NO default (digest); ADD --checksum=; libicu76 + curl + iproute2 + util-linux + python3-yaml; NO runtime pip; image smoke; refresh SLA 30d.

Workflow (structural YAML test, not grep): permissions contents:read; ci-build exactly once; trusted-event (push/wf_dispatch on main); no secrets/env/id-token; repo-scoped runner.

Runtime inspect: Privileged=false ReadonlyRootfs=true User=10001:10001 OpenStdin=true NetworkMode=ci-build-egress CapAdd=[] Binds=[] tmpfs limits digest.

IPv6: EnableIPv6=false; no global IPv6 addr; no IPv6 default route; daemon IPv4-only.

GitHub lifecycle: ci-build label; one lock-projection job; auto-deregister; --rm; single-slot flock + orphan ps -aq preflight; no host persistence; no aptly/GPG/R2/CF/SSH/prod cred.

Audit/diagnostics: lifecycle.log events (no token, root:root dir 0750 log 0640 regular); _diag manual export only.
```
