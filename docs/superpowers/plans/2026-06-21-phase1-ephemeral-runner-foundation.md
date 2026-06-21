# Phase 1 — Ephemeral Runner Foundation Implementation Plan (v1.3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **v1.3 revisions (8 blocking items):** (1) Docker bridge creation uses correct `--opt com.docker.network.bridge.name=` (not the nonexistent `--bridge-name`); existing network is verified (driver/subnet/gateway/bridge/IPv6=false, fail-closed on mismatch); (2) firewall uses two managed chains — `OCSERV_CI_EGRESS` (jumped from DOCKER-USER, forwarded egress) + `OCSERV_CI_HOST_GUARD` (in INPUT, blocks container→host), flush+rebuild in fixed order, IPv6 fail-closed, persistence is hard-fail (not WARN); (3) config metadata via single stubbable `_config_metadata()` helper; dry-run/main both verify config + parent paths non-writable; (4) live mode forbids `--runner-name` (CSPRNG-only); cleanup verifies `com.ocserv-ci.managed-by` label before `rm -f`; preflight fails on pre-existing same-name container; (5) `libicu76` added (Actions Runner ICU dep on trixie); `docker image inspect` preflight; tarball SHA-256 format validated; runner refresh SLA in runbook; (6) workflow `permissions: contents: read` + `if:` trusted-event guard (push/workflow_dispatch on main only) + no secrets/environment/id-token; repo-scope runner assertion; (7) sudo `-v`/`-n` stdin pattern (token not consumed by sudo); lifecycle audit event model (start/exit/timeout/signal) root-owned 0640; (8) firewall negative acceptance is explicitly a runner-host integration test (pure-function tests do NOT claim network-isolation acceptance).

**Goal:** Build a minimal, manually-triggered, **single-slot** (host flock) ephemeral GitHub Actions runner that runs the `lock-projection` job in a non-root, non-privileged, docker-socket-less container, then auto-deregisters and auto-removes, with a **real, persistent, host-INPUT-aware** firewall egress boundary.

**Architecture:** A **self-contained** root-owned bash provisioner (installed to `/usr/local/libexec/ocserv-ci/runner-provisioner`) reads a short-lived GitHub registration token from stdin, acquires a host-level `flock` (single-slot), generates a CSPRNG runner name (live `--runner-name` forbidden), and launches a fixed-parameter `docker run --rm -i` of a digest-pinned runner image (preflight `docker image inspect`), wrapped in a bounded `timeout` (5m–60m). The image's non-root entrypoint copies the actions-runner payload (no-preserve-ownership) to a `/runner` tmpfs, runs `config.sh --ephemeral --unattended --disableupdate`, then `run.sh`. The runner host runs two managed iptables chains — `OCSERV_CI_EGRESS` (from DOCKER-USER, forwarded egress: deny private/link-local/metadata/host/publish, allow public 443/80) + `OCSERV_CI_HOST_GUARD` (in INPUT: container cannot reach host) — flushed+rebuilt in fixed order, persisted hard-fail, IPv6 disabled fail-closed.

**Tech Stack:** Bash (self-contained provisioner + entrypoint + host-install), Docker (runner container, iptables backend verified), Debian trixie (digest-pinned base, no default tag), GitHub Actions self-hosted runner (tarball `ADD --checksum=sha256:`, `libicu76`), `util-linux` (findmnt), bats (tests), shellcheck (lint), iptables managed chains (egress + host-guard).

**Parent spec:** `docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md` §1.1, §5, §11.2, §11.4.

**Phase 1 scope (hard boundary):** provisioner (self-contained, flock, CSPRNG name, timeout, root-owned + parent-path verified) + non-root ephemeral image (digest base, checksum payload, libicu76, no runtime pip) + `--ephemeral`/`--rm`/`-i` + read-only rootfs + tmpfs + no socket + no privileged + cap-drop=ALL + no-new-privileges + no bind mount + resource limits + **real persistent managed-chain firewall (egress + host-guard + IPv6 fail-closed)** + migrate `lock-projection` (image-baked deps, trusted-event only, contents:read, no secrets) + automated acceptance + lifecycle audit event model.

**Explicitly NOT in Phase 1:** candidate release API, mTLS bootstrap, R2 staging, Sigstore, aptly, GPG, publish host, testing publish, staging deploy, production promotion, rollback control plane, production credentials, JIT runner config, autoscaler/timer/pool, FQDN egress proxy (Phase 1 uses deny-private/allow-public-443-80; strict FQDN proxy later).

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `scripts/runner-provisioner.sh` | **Self-contained** root-owned provisioner: own log/die, config parse (`_config_metadata` stubbable), stdin token, CSPRNG name (live `--runner-name` forbidden), host flock, fixed `docker run -i`, `docker image inspect` preflight, bounded timeout, label-verified cleanup, lifecycle audit events. | New |
| `scripts/runner-host-install.sh` | One-time host install: root-owned provisioner + parent-path verification; create/verify Docker bridge (correct `--opt` syntax); build two managed iptables chains (egress + host-guard) flushed+rebuilt in order; verify iptables backend + IPv6 disabled; persist hard-fail. | New |
| `docker/runner/Dockerfile` | Non-root (10001:10001) trixie: **digest base (no default)** + `ADD --checksum=` payload + `python3-yaml` + `util-linux` + **`libicu76`**. No runtime pip. | New |
| `docker/runner/entrypoint.sh` | Container entrypoint (UID 10001): findmnt assertions (`/tmp` nosuid+nodev+noexec), no-preserve copy, stdin token, config.sh --ephemeral, run.sh. | New |
| `docker/runner/ci-build-egress.policy` | Managed-chain rule spec (OCSERV_CI_EGRESS + OCSERV_CI_HOST_GUARD). | New |
| `test/test_runner_provisioner.bats` | Provisioner tests incl. config metadata stub, live `--runner-name` rejection, image-preflight, label-cleanup. | New |
| `test/test_runner_entrypoint.bats` | Entrypoint mount-assertion tests (path-aware stubs). | New |
| `test/test_runner_network.bats` | Policy parse + pure egress lib (integration acceptance is runbook, NOT pure-test). | New |
| `.github/workflows/ci-testing.yml` | Dual-track `lock-projection-cibuild`: `permissions: contents: read` + `if:` trusted-event + no secrets/env/id-token. | Modify |
| `Makefile` | `runner-image` (digest base required, push, manifest digest), `runner-provision` (dry-run). | Modify |
| `docs/runner-ephemeral.md` | Runbook: image supply chain + refresh SLA, host install (root-owned, managed-chain firewall), token via `sudo -n` stdin, lifecycle audit events, firewall integration negative tests, offline cleanup. | New |

---

## Task 1: Self-contained provisioner — helpers + config + name + timeout

**Files:**
- Create: `scripts/runner-provisioner.sh`, `test/test_runner_provisioner.bats`

- [ ] **Step 1: Failing tests**

```bash
load helpers/bats-helper.bash
PROVISIONER="${REPO_ROOT}/scripts/runner-provisioner.sh"
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NAME26="0123456789ABCDEFGHJKMNPQRS"   # 26 Crockford Base32 chars

@test "provisioner is self-contained (sources without _common.sh)" {
  run bash -c "set +e; cd /tmp; source '${PROVISIONER}'; echo sourced-ok"
  echo "$output" | grep -q sourced-ok
}

@test "load_provisioner_config: reads config; dies on missing" {
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
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo \"IMG=\${RUNNER_IMAGE}\""
  echo "$output" | grep -q "IMG=ghcr.io/owner/img@sha256:${DIG64}"
  rm -f "$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config /nope.conf; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "generate_runner_name: ci-build-<26 Crockford Base32 incl S/Z>" {
  run bash -c "set +e; source '${PROVISIONER}'; generate_runner_name"
  echo "$output" | grep -qE '^ci-build-[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$'
}

@test "generate_runner_name: two calls differ" {
  run bash -c "set +e; source '${PROVISIONER}'; printf '%s\n%s\n' \"\$(generate_runner_name)\" \"\$(generate_runner_name)\""
  [ "$(sed -n 1p <<<"$output")" != "$(sed -n 2p <<<"$output")" ]
}

@test "valid_runner_name: 26-char ok; arbitrary/empty rejected" {
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name ci-build-${NAME26} && echo ok"
  echo "$output" | grep -q ok
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name my-name; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "parse_timeout_to_seconds: bounds [5m,60m]" {
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 45m"
  [ "$output" = "2700" ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 1m; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 90m; echo rc=\$?"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run → FAIL** (script absent).

- [ ] **Step 3: Create provisioner (pure functions)**

```bash
#!/usr/bin/env bash
# runner-provisioner.sh — Phase 1 ephemeral ci-build runner launcher.
# SELF-CONTAINED (own log/die; NO _common.sh source). Root-owned, single-slot
# (flock), CSPRNG name (live --runner-name forbidden), fixed-param, bounded-timeout.
set -euo pipefail

log() { printf '[%s] runner-provisioner: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

DEFAULT_CONFIG="/etc/ocserv-ci-runner/provisioner.conf"
SINGLE_SLOT_LOCK="/run/lock/ocserv-ci-runner.lock"
AUDIT_DIR="/var/log/ocserv-ci-runner"
AUDIT_LOG="${AUDIT_DIR}/lifecycle.log"
readonly TIMEOUT_MIN_S=300 TIMEOUT_MAX_S=3600

load_provisioner_config() {
  local cfg="$1"
  [[ -f "${cfg}" ]] || die "provisioner config not found: ${cfg}"
  local line key val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    [[ "${key}" =~ ^RUNNER_[A-Z0-9_]+$ ]] || continue
    export "${key}=${val}"
  done < "${cfg}"
  local req k
  req=(RUNNER_URL RUNNER_LABEL RUNNER_IMAGE RUNNER_NETWORK RUNNER_CPUS RUNNER_MEMORY RUNNER_PIDS_LIMIT RUNNER_TMPFS_WORK_SIZE RUNNER_TMPFS_RUNNER_SIZE RUNNER_TMPFS_TMP_SIZE RUNNER_WAIT_TIMEOUT)
  for k in "${req[@]}"; do [[ -n "${!k:-}" ]] || die "missing required config key: ${k}"; done
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
  local d="$1" n s
  if   [[ "${d}" =~ ^([0-9]+)s$ ]]; then n=${BASH_REMATCH[1]}; s=$((n))
  elif [[ "${d}" =~ ^([0-9]+)m$ ]]; then n=${BASH_REMATCH[1]}; s=$((n*60))
  elif [[ "${d}" =~ ^([0-9]+)h$ ]]; then n=${BASH_REMATCH[1]}; s=$((n*3600))
  else die "invalid RUNNER_WAIT_TIMEOUT: '${d}'"; fi
  [[ ${s} -ge ${TIMEOUT_MIN_S} ]] || die "RUNNER_WAIT_TIMEOUT ${d} below min 5m"
  [[ ${s} -le ${TIMEOUT_MAX_S} ]] || die "RUNNER_WAIT_TIMEOUT ${d} above max 60m"
  printf '%s' "${s}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then echo "ERROR: main() not impl (Task 3)" >&2; exit 2; fi
```

- [ ] **Step 4: Run → PASS (6)**. `shellcheck` (no errors).
- [ ] **Step 5: Commit** `feat(phase1): self-contained provisioner helpers`.

---

## Task 2: Arg validation (live `--runner-name` forbidden) + forbidden-args guard

**Files:**
- Modify: `scripts/runner-provisioner.sh`, `test/test_runner_provisioner.bats`

- [ ] **Step 1: Failing tests**

```bash
@test "parse_args: --registration-token-stdin / --dry-run" {
  run bash -c "set +e; source '${PROVISIONER}'; TOKEN_STDIN=0; parse_args --registration-token-stdin --dry-run; echo \"T=\${TOKEN_STDIN} D=\${BOOTSTRAP_DRY_RUN}\""
  echo "$output" | grep -q 'T=1 D=1'
}

@test "parse_args: --runner-name ONLY in dry-run; live mode REJECTS (CSPRNG-only)" {
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=1; parse_args --runner-name ci-build-DRYTEST; echo N=\${RUNNER_NAME}"
  echo "$output" | grep -q 'N=ci-build-DRYTEST'
  # live mode rejects ANY --runner-name, even valid-shape (CSPRNG-only in live)
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
  run bash -c "set +e; source '${PROVISIONER}'; parse_args --bogus; echo rc=\$?"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run → FAIL**.
- [ ] **Step 3: Add parse_args** (live `--runner-name` → die)

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
        # Live mode: ALWAYS CSPRNG-generated; --runner-name forbidden (prevents
        # cleanup trap removing a pre-existing same-name container). Dry-run only.
        [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]] || die "live mode forbids --runner-name (CSPRNG-only); dry-run only"
        [[ $# -ge 2 ]] || die "--runner-name requires a value"
        RUNNER_NAME="$2"; RUNNER_NAME_OVERRIDE=1; shift 2 ;;
      --wait-timeout)
        [[ $# -ge 2 ]] || die "--wait-timeout requires a value"
        RUNNER_WAIT_TIMEOUT_OVERRIDE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --docker-arg|--mount|--cap-add|--privileged|--pid|--ipc|--uts|--userns|--network|--image|--label|--env|--device|-v|--volume)
        die "forbidden argument: $1" ;;
      *) die "unknown argument: $1 (see -h)" ;;
    esac
  done
}
usage() { cat >&2 <<EOF
Usage: runner-provisioner.sh --registration-token-stdin [options]
  --registration-token-stdin   token from stdin
  --dry-run                    print docker run without executing
  --runner-name <name>         DRY-RUN ONLY (live uses CSPRNG-generated name)
  --wait-timeout <dur>         5m..60m
  -h, --help
EOF
}
```

- [ ] **Step 4: Run → PASS (10)**. `shellcheck` (no errors).
- [ ] **Step 5: Commit** `feat(phase1): arg validation (live --runner-name forbidden)`.

---

## Task 3: Docker-run + main (flock, image preflight, config metadata stub, label cleanup, audit events)

**Files:**
- Modify: `scripts/runner-provisioner.sh`, `test/test_runner_provisioner.bats`

- [ ] **Step 1: Failing tests**

```bash
mkcfg() { cat >"$1" <<EOF
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2 RUNNER_MEMORY=6g RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g RUNNER_TMPFS_RUNNER_SIZE=1g RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
}
docker_argv_lines() {
  bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '$1'; build_docker_run_args '$2'" \
    | while IFS= read -r -d '' a; do printf '%s\n' "$a"; done
}

@test "build_docker_run_args: -i + --interactive + --stop-timeout + ownership labels" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  out="$(docker_argv_lines "$tmpcfg" ci-build-TEST)"; rm -f "$tmpcfg"
  echo "$out" | grep -qx -- '-i'
  echo "$out" | grep -qx -- '--interactive'
  echo "$out" | grep -q -- '--stop-timeout=10'
  echo "$out" | grep -q -- 'com.ocserv-ci.managed-by=runner-provisioner'
  echo "$out" | grep -q -- 'com.ocserv-ci.phase=1'
  echo "$out" | grep -q -- 'com.ocserv-ci.runner-name=ci-build-TEST'
}

@test "build_docker_run_args: safe params + digest + fixed non-secret env; no privileged/socket/volume" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  out="$(docker_argv_lines "$tmpcfg" ci-build-TEST)"; rm -f "$tmpcfg"
  for f in --rm --init -i --interactive --read-only --user=10001:10001 --cap-drop=ALL --security-opt=no-new-privileges:true --pull=never; do
    echo "$out" | grep -qx -- "$f" || { echo "MISSING $f"; exit 1; }
  done
  echo "$out" | grep -q -- '--env RUNNER_URL='
  echo "$out" | grep -qx -- "ghcr.io/owner/img@sha256:${DIG64}"
  ! echo "$out" | grep -q -- '--privileged'
  ! echo "$out" | grep -q -- 'docker.sock'
  ! echo "$out" | grep -qE -- '^-v$|--volume'
  ! echo "$out" | grep -qi -- '--env.*TOKEN'
}

@test "assert_image_is_digest: 64-hex ok; short/tag rejected" {
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'x@sha256:${DIG64}'; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'debian:trixie'; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_config_root_owned: stub _config_metadata; root:root 600 regular pass; others fail" {
  tmpf="$(mktemp)"
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata() { printf 'root:root 600 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata() { printf 'builder:builder 600 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata() { printf 'root:root 640 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _config_metadata() { printf 'root:root 600 symlink'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"
  [ "$status" -ne 0 ]
  rm -f "$tmpf"
}

@test "assert_parent_paths_nonwritable: stub _path_mode; 0755 ok, 0777 die" {
  run bash -c "set +e; source '${PROVISIONER}'; _path_mode() { printf '755'; }; assert_parent_paths_nonwritable /etc/ocserv-ci-runner; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _path_mode() { printf '777'; }; assert_parent_paths_nonwritable /etc/ocserv-ci-runner; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "preflight_image_cached: image present -> ok; absent -> die (stubbed docker)" {
  run bash -c "set +e; source '${PROVISIONER}'; docker() { return 0; }; preflight_image_cached 'img@sha256:${DIG64}'; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; docker() { return 1; }; preflight_image_cached 'img@sha256:${DIG64}'; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "preflight_name_free: name absent -> ok; present -> die (cleanup safety)" {
  run bash -c "set +e; source '${PROVISIONER}'; docker() { return 1; }; preflight_name_free ci-build-X; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; docker() { return 0; }; preflight_name_free ci-build-X; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "acquire_single_slot: live 2nd rejected; dry-run skips (flock -n)" {
  tmplock="$(mktemp)"
  ( flock -n 9 && sleep 2 ) 9>"${tmplock}" & sleep 0.3
  run bash -c "set +e; source '${PROVISIONER}'; SINGLE_SLOT_LOCK='${tmplock}'; BOOTSTRAP_DRY_RUN=0; acquire_single_slot; echo rc=\$?"
  [ "$status" -ne 0 ]
  wait; rm -f "${tmplock}"
  tmplock="$(mktemp)"
  ( flock -n 9 && sleep 2 ) 9>"${tmplock}" & sleep 0.3
  run bash -c "set +e; source '${PROVISIONER}'; SINGLE_SLOT_LOCK='${tmplock}'; BOOTSTRAP_DRY_RUN=1; acquire_single_slot; echo rc=\$?"
  [ "$status" -eq 0 ]
  wait; rm -f "${tmplock}"
}

@test "main --dry-run: docker+timeout printed; NEVER token; rc 0 (stubs for root/config)" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  run bash -c "set +e; echo 'ghs_SUPERSECRET_xyz' | bash -c '
    source \"${PROVISIONER}\"
    current_uid() { echo 0; }
    _config_metadata() { printf \"root:root 600 regular\"; }
    _path_mode() { printf \"755\"; }
    docker() { return 0; }
    PROVISIONER_CONFIG=\"${tmpcfg}\" main --registration-token-stdin --dry-run --runner-name ci-build-DRYTEST
  ' 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -q 'rc=0'
  echo "$output" | grep -qi 'timeout'
  ! echo "$output" | grep -q 'SUPERSECRET'
}

@test "main: rejects non-root" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  run bash -c "set +e; bash -c '
    source \"${PROVISIONER}\"; current_uid() { echo 1000; }
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

# build_docker_run_args <name> — fixed argv + ownership labels (for safe cleanup).
build_docker_run_args() {
  local name="$1"
  assert_image_is_digest "${RUNNER_IMAGE}"
  printf '%s\0' \
    run --rm --init -i --interactive \
    --name="${name}" \
    --stop-timeout=10 \
    --label "com.ocserv-ci.managed-by=runner-provisioner" \
    --label "com.ocserv-ci.phase=1" \
    --label "com.ocserv-ci.runner-name=${name}" \
    --read-only --user=10001:10001 --cap-drop=ALL \
    --security-opt=no-new-privileges:true \
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
  mode="$(stat -c '%a' "$f")"
  if [[ -L "$f" ]]; then kind="symlink"
  elif [[ -f "$f" ]]; then kind="regular"; else kind="other"; fi
  printf '%s %s %s' "$(stat -c '%U:%G' "$f")" "${mode}" "${kind}"
}

assert_config_root_owned() {
  local f="$1" meta owner mode kind
  meta="$(_config_metadata "$f")"; owner="${meta%% *}"
  local rest="${meta#* }"; mode="${rest%% *}"; kind="${rest##* }"
  [[ "${kind}" == "regular" ]] || die "config ${f} must be regular file (got ${kind})"
  [[ "${owner}" == "root:root" ]] || die "config ${f} must be root:root (got ${owner})"
  [[ "${mode}" == "600" ]] || die "config ${f} must be mode 0600 (got ${mode})"
}

# _path_mode <path> — octal mode (stubbable).
_path_mode() { stat -c '%a' "$1"; }

# assert_parent_paths_nonwritable <file> — every parent up to /etc must not be group/world-writable.
assert_parent_paths_nonwritable() {
  local f="$1" p="$1"
  while [[ "${p}" != "/" && "${p}" != "." ]]; do
    local m; m="$(_path_mode "${p}" 2>/dev/null || echo missing)"
    [[ "${m}" == missing ]] && { p="$(dirname "${p}")"; continue; }
    # reject if group or other write bit set (modes ending in 2/3/6/7 in the g or o position)
    case "${m}" in
      ?[2367]?|?[2367]) die "parent ${p} group-writable (mode ${m})" ;;
      ??[2367]) die "parent ${p} world-writable (mode ${m})" ;;
    esac
    p="$(dirname "${p}")"
    [[ "${p}" == "/" ]] && break
  done
}

preflight_image_cached() {
  local img="$1"
  docker image inspect "${img}" >/dev/null 2>&1 \
    || die "image ${img} not in local cache; pre-pull by exact digest (provisioner uses --pull=never)"
}

preflight_name_free() {
  local name="$1"
  if docker inspect "${name}" >/dev/null 2>&1; then
    die "container ${name} already exists; refusing (cleanup safety); remove it first"
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

# cleanup ONLY if container has our ownership labels (never rm -f arbitrary name).
cleanup_this_container() {
  local name="$1"
  docker inspect "${name}" >/dev/null 2>&1 || return 0
  local mb; mb="$(docker inspect -f '{{index .Config.Labels "com.ocserv-ci.managed-by"}}' "${name}" 2>/dev/null || true)"
  if [[ "${mb}" == "runner-provisioner" ]]; then
    log "cleanup: removing this-provisioner container ${name}"
    docker rm -f "${name}" >/dev/null 2>&1 || true
  else
    log "WARN: container ${name} lacks managed-by label; NOT removing (possible name collision)"
  fi
}

# audit_event <event> <name> <image> [extra] — append-only, root-owned, no token.
audit_event() {
  local ev="$1" name="$2" image="$3" extra="${4:-}"
  install -d -o root -g root -m 0750 "${AUDIT_DIR}" 2>/dev/null || true
  printf '%s event=%s name=%s image=%s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ev}" "${name}" "${image}" "${extra}" \
    >>"${AUDIT_LOG}" 2>/dev/null || log "WARN: audit write failed ${AUDIT_LOG}"
}

main() {
  [[ "$(current_uid)" -eq 0 ]] || die "must run as root (install via runner-host-install.sh)"
  parse_args "$@"
  [[ "${TOKEN_STDIN}" -eq 1 ]] || die "token source required: --registration-token-stdin"
  local config="${DEFAULT_CONFIG}"
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" && -n "${PROVISIONER_CONFIG:-}" ]]; then config="${PROVISIONER_CONFIG}"
  elif [[ -n "${PROVISIONER_CONFIG:-}" ]]; then die "PROVISIONER_CONFIG forbidden in live mode (use ${DEFAULT_CONFIG})"; fi
  assert_config_root_owned "${config}"
  assert_parent_paths_nonwritable "${config}"
  load_provisioner_config "${config}"
  [[ -n "${RUNNER_WAIT_TIMEOUT_OVERRIDE:-}" ]] && RUNNER_WAIT_TIMEOUT="${RUNNER_WAIT_TIMEOUT_OVERRIDE}"
  local wait_s; wait_s="$(parse_timeout_to_seconds "${RUNNER_WAIT_TIMEOUT}")"
  # Live: CSPRNG name only (--runner-name forbidden in live per Task 2).
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
  preflight_image_cached "${RUNNER_IMAGE}"
  preflight_name_free "${RUNNER_NAME}"
  local launched=0
  trap '[[ $launched -eq 1 ]] && cleanup_this_container "${RUNNER_NAME}"' EXIT INT TERM
  audit_event start "${RUNNER_NAME}" "${RUNNER_IMAGE}" "timeout=${RUNNER_WAIT_TIMEOUT}"

  local rc=0 ev=exit
  if timeout --foreground --signal=TERM --kill-after=10s "${wait_s}s" docker "${docker_argv[@]}" < /dev/stdin; then
    rc=0
  else
    rc=$?
    if [[ ${rc} -eq 124 ]]; then ev=timeout
    elif [[ ${rc} -gt 128 ]]; then ev=signal; fi
  fi
  launched=1
  log "runner ${RUNNER_NAME} ${ev} rc=${rc}"
  audit_event "${ev}" "${RUNNER_NAME}" "${RUNNER_IMAGE}" "rc=${rc}"
  trap - EXIT INT TERM
  cleanup_this_container "${RUNNER_NAME}"
  return ${rc}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 4: Run → PASS (19)**. `shellcheck` (no errors).
- [ ] **Step 5: Commit** `feat(phase1): docker-run (-i/labels) + flock + image preflight + config-metadata stub + label cleanup + audit events`.

**Checkpoint review (Task 1-3):** root trust boundary, stdin token + `-i`, single-slot flock, CSPRNG-only live name, image preflight, config metadata/parent-path runtime verification, label-verified cleanup, audit events, timeout capture.

---

## Task 4: Image (digest base, checksum payload, libicu76, no runtime pip, smoke test)

**Files:**
- Create: `docker/runner/Dockerfile`, `docker/runner/.dockerignore`

- [ ] **Step 1: Dockerfile** (base NO default; libicu76 for Actions Runner ICU dep on trixie; util-linux for findmnt)

```dockerfile
# Phase 1 ci-build runner image. Non-root (10001:10001); read-only rootfs at runtime.
# libicu76: GitHub Actions Runner (.NET) needs ICU on Debian 13/trixie — without it
# config.sh fails with Dotnet ICU dependency missing.
# No runtime pip (python3-yaml baked). util-linux for findmnt in entrypoint.
ARG TRIXIE_DIGEST
FROM "${TRIXIE_DIGEST}" AS base

RUN groupadd --system --gid 10001 runner \
 && useradd  --system --uid 10001 --gid 10001 --no-create-home --home-dir /runner runner

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git make python3 python3-yaml util-linux libicu76 \
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
- [ ] **Step 3: Commit** `feat(phase1): runner image (digest base, checksum payload, libicu76, no runtime pip)`.

> **Image smoke test (run after build, in Task 8):** verify runner native runtime starts (no token):
> `docker run --rm --entrypoint /bin/sh <image@digest> -ec '/opt/actions-runner-src/bin/Runner.Listener --version'`
> This catches missing libicu76 / payload corruption without a registration token.

---

## Task 5: Entrypoint (mountinfo assertions, path-aware stubs, /tmp noexec+nosuid+nodev)

(Unchanged from v1.2 Task 5 — findmnt-based assertions, path-aware stubs, no-preserve-ownership copy. See that task's full code; not repeated here to avoid drift. Entrypoint asserts: current_uid==10001, rootfs `ro`, /runner & /work tmpfs+nosuid+nodev, /tmp tmpfs+nosuid+nodev+noexec, then copy + stdin token + config.sh --ephemeral + run.sh.)

- [ ] Steps 1-5 as v1.2 (7 bats tests pass; shellcheck clean). Commit `feat(phase1): entrypoint (mountinfo assertions, /tmp noexec+nosuid+nodev, no-preserve copy)`.

**Checkpoint review (Task 4-5):** image supply chain (digest base, checksum payload, libicu76), image smoke (Runner.Listener --version), mount assertions, non-root copy.

---

## Task 6: Egress policy + managed chains + pure lib

**Files:**
- Create: `docker/runner/ci-build-egress.policy`, `docker/runner/ci-build-egress.policy.lib`, `test/test_runner_network.bats`

Policy describes the two managed chains (`OCSERV_CI_EGRESS` from DOCKER-USER + `OCSERV_CI_HOST_GUARD` in INPUT). Pure lib tests policy logic; **network-isolation acceptance is a runner-host integration test (runbook), NOT a pure-function claim.**

- [ ] **Step 1: Policy file**

```text
# ci-build egress — TWO managed iptables chains (applied+persisted by host-install).
# OCSERV_CI_EGRESS: jumped from DOCKER-USER; forwarded egress from br-ci-build-egress.
# OCSERV_CI_HOST_GUARD: in INPUT; container cannot reach host services/gateway.
# Docker MUST use iptables backend (installer verifies). IPv6 MUST be disabled (fail-closed).
# Model: deny private/link-local/metadata/host/publish; allow public 443/80.

[meta]
bridge = br-ci-build-egress
subnet = 172.30.0.0/24
gateway = 172.30.0.1
egress_chain = OCSERV_CI_EGRESS
host_guard_chain = OCSERV_CI_HOST_GUARD

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
# INPUT: drop anything from the bridge to the host (no host service reachable).
rule = -i br-ci-build-egress -j DROP

[ipv6]
require_disabled = true
```

- [ ] **Step 2: Pure lib + tests** (deny private/link-local/metadata; allow public 443/80)

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

@test "policy defines two managed chains + IPv6 fail-closed" {
  grep -q 'OCSERV_CI_EGRESS' "${POLICY}"
  grep -q 'OCSERV_CI_HOST_GUARD' "${POLICY}"
  grep -q 'require_disabled = true' "${POLICY}"
}
@test "policy denies RFC1918/link-local/metadata; allows only public 443/80; no GitHub IP allowlist" {
  grep -q '10.0.0.0/8' "${POLICY}"; grep -q '169.254.0.0/16' "${POLICY}"
  grep -q 'dport=443' "${POLICY}"; grep -q 'dport=80' "${POLICY}"
  ! grep -qi '140.82' "${POLICY}"; ! grep -qi '185.199' "${POLICY}"
}
@test "egress_dest_allowed: private denied; public 443 ok; public 22 denied" {
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 10.20.0.5 443; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 1.2.3.4 443; echo rc=\$?"; [ "$status" -eq 0 ]
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 1.2.3.4 22; echo rc=\$?"; [ "$status" -ne 0 ]
}
```

> **NOTE (acceptance boundary):** these pure tests verify policy *logic* only. Actual network isolation is accepted ONLY by the runner-host integration negative test in the runbook (curl to private/metadata MUST fail, curl github MUST succeed, `iptables -S OCSERV_CI_EGRESS` / `OCSERV_CI_HOST_GUARD` rules present). Pure-function tests do NOT claim network isolation.

- [ ] **Step 3: Run → PASS. Commit** `feat(phase1): managed-chain egress policy (egress + host-guard) + pure lib`.

---

## Task 7: Host install (correct bridge syntax, managed chains, INPUT guard, IPv6 fail-closed, persist hard-fail, parent-path verify) + Makefile + runbook

**Files:**
- Create: `scripts/runner-host-install.sh`, `docs/runner-ephemeral.md`; Modify `Makefile`

- [ ] **Step 1: host-install.sh** (correct `--opt com.docker.network.bridge.name=`; verify existing network attrs; build+flush two managed chains; INPUT guard; IPv6 fail-closed; persist hard-fail)

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
BRIDGE="br-ci-build-egress"
SUBNET="172.30.0.0/24"
GW="172.30.0.1"
EGRESS_CHAIN="OCSERV_CI_EGRESS"
HOST_GUARD="OCSERV_CI_HOST_GUARD"

main() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root"
  [[ -f "${PROVISIONER_SRC}" ]] || die "provisioner source not found"

  # Install provisioner + verify parent paths non-writable (trust boundary).
  for d in /usr/local /usr/local/libexec "${LIBEXEC_DIR}"; do
    local m; m="$(stat -c '%a' "$d")"
    case "${m}" in ?[2367]?|??[2367]) die "parent ${d} group/world-writable (mode ${m})";; esac
  done
  install -d -o root -g root -m 0755 "${LIBEXEC_DIR}"
  install -o root -g root -m 0755 "${PROVISIONER_SRC}" "${LIBEXEC_DIR}/runner-provisioner"
  [[ ! -L "${LIBEXEC_DIR}/runner-provisioner" && "$(stat -c '%U:%G' "${LIBEXEC_DIR}/runner-provisioner")" == "root:root" ]] \
    || die "installed provisioner verification failed"
  log "provisioner (self-contained) -> ${LIBEXEC_DIR}/runner-provisioner"

  install -d -o root -g root -m 0750 "${CONFIG_DIR}"
  if [[ ! -f "${CONFIG_DIR}/provisioner.conf" ]]; then
    cat >"${CONFIG_DIR}/provisioner.conf" <<'EOF'
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/OWNER/ocserv-ci-runner@sha256:REPLACE_64_HEX
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2 RUNNER_MEMORY=6g RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g RUNNER_TMPFS_RUNNER_SIZE=1g RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
    chmod 0600 "${CONFIG_DIR}/provisioner.conf"
  fi
  install -o root -g root -m 0644 "${SCRIPT_DIR}/../docker/runner/ci-build-egress.policy" "${CONFIG_DIR}/"

  # Docker bridge: create with CORRECT --opt syntax, or verify existing attrs (fail-closed).
  if ! docker network inspect ci-build-egress >/dev/null 2>&1; then
    docker network create --driver bridge --subnet "${SUBNET}" --gateway "${GW}" \
      --opt com.docker.network.bridge.name="${BRIDGE}" ci-build-egress
  else
    # Verify existing network matches expected attrs exactly.
    local drv sub gw br ipv6
    drv="$(docker network inspect ci-build-egress -f '{{.Driver}}')"
    sub="$(docker network inspect ci-build-egress -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
    gw="$(docker network inspect ci-build-egress -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')"
    br="$(docker network inspect ci-build-egress -f '{{index .Options "com.docker.network.bridge.name"}}')"
    ipv6="$(docker network inspect ci-build-egress -f '{{.EnableIPv6}}')"
    [[ "${drv}" == bridge ]] || die "ci-build-egress driver=${drv} (expected bridge)"
    [[ "${sub}" == "${SUBNET}" ]] || die "ci-build-egress subnet=${sub} (expected ${SUBNET})"
    [[ "${gw}" == "${GW}" ]] || die "ci-build-egress gateway=${gw} (expected ${GW})"
    [[ "${br}" == "${BRIDGE}" ]] || die "ci-build-egress bridge=${br} (expected ${BRIDGE})"
    [[ "${ipv6}" == false ]] || die "ci-build-egress EnableIPv6=${ipv6} (expected false)"
    log "ci-build-egress verified (attrs match)"
  fi

  # Verify Docker iptables backend (DOCKER-USER exists); fail closed.
  iptables -n -L DOCKER-USER >/dev/null 2>&1 || die "DOCKER-USER missing — Docker must use iptables backend"
  # IPv6 fail-closed: if ip6tables loaded and any rule accepts, container could bypass via IPv6.
  if ip6tables -n -L FORWARD 2>/dev/null | grep -qi accept; then
    die "ip6tables FORWARD has ACCEPT rules; IPv6 egress uncontrolled — disable IPv6 on this host/network"
  fi

  # Build managed chains: flush + rebuild in fixed order.
  iptables -N "${EGRESS_CHAIN}" 2>/dev/null || iptables -F "${EGRESS_CHAIN}"
  iptables -N "${HOST_GUARD}" 2>/dev/null || iptables -F "${HOST_GUARD}"

  # OCSERV_CI_EGRESS (forwarded egress from bridge): deny private/link-local/metadata/gw; allow public 443/80; drop rest.
  for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 "${GW}"; do
    iptables -A "${EGRESS_CHAIN}" -i "${BRIDGE}" -d "${cidr}" -j DROP -m comment --comment "ocserv-ci deny ${cidr}"
  done
  iptables -A "${EGRESS_CHAIN}" -i "${BRIDGE}" -p tcp --dport 443 -j RETURN -m comment --comment "ocserv-ci allow public 443"
  iptables -A "${EGRESS_CHAIN}" -i "${BRIDGE}" -p tcp --dport 80 -j RETURN -m comment --comment "ocserv-ci allow public 80"
  iptables -A "${EGRESS_CHAIN}" -i "${BRIDGE}" -j DROP -m comment --comment "ocserv-ci default deny"

  # Single jump from DOCKER-USER (idempotent: remove old jump first).
  while iptables -D DOCKER-USER -i "${BRIDGE}" -j "${EGRESS_CHAIN}" 2>/dev/null; do :; done
  iptables -I DOCKER-USER -i "${BRIDGE}" -j "${EGRESS_CHAIN}" -m comment --comment "ocserv-ci egress"

  # OCSERV_CI_HOST_GUARD (INPUT from bridge): drop all container→host.
  iptables -A "${HOST_GUARD}" -i "${BRIDGE}" -j DROP -m comment --comment "ocserv-ci host-guard"
  # Hook into INPUT (idempotent).
  while iptables -D INPUT -i "${BRIDGE}" -j "${HOST_GUARD}" 2>/dev/null; do :; done
  iptables -I INPUT -i "${BRIDGE}" -j "${HOST_GUARD}" -m comment --comment "ocserv-ci host-guard"

  log "managed chains ${EGRESS_CHAIN} + ${HOST_GUARD} loaded"

  # Persist HARD-FAIL (not WARN): the firewall must survive reboot.
  if ! command -v netfilter-persistent >/dev/null 2>&1; then
    die "netfilter-persistent missing — install iptables-persistent before proceeding (firewall must persist)"
  fi
  netfilter-persistent save || die "netfilter-persistent save failed (firewall not persisted)"

  log "install complete. Launch: sudo -v; printf '%s\\n' \"\$TOKEN\" | sudo -n ${LIBEXEC_DIR}/runner-provisioner --registration-token-stdin; unset TOKEN"
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 2: Makefile** (digest base required + tarball SHA format check)

```makefile
.PHONY: runner-image runner-provision
RUNNER_TARBALL_URL ?=
RUNNER_TARBALL_SHA256 ?=
TRIXIE_DIGEST ?=
REGISTRY ?= ghcr.io/gentlekingson

runner-image: ## Build + push runner image; print registry manifest digest
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

- [ ] **Step 3: runbook (`docs/runner-ephemeral.md`) — key sections**

```markdown
# Ephemeral ci-build Runner — Operator Runbook (Phase 1)

Single-slot, manually-triggered, bounded-wait ephemeral runner for lock-projection.

## Image supply chain + refresh SLA
build host: make runner-image TRIXIE_DIGEST=docker.io/library/debian@sha256:<64hex> \
  RUNNER_TARBALL_URL=<url> RUNNER_TARBALL_SHA256=<64hex>   (NO default base tag)
  → buildx build + push; prints manifest digest.
runner host: docker pull <registry>/ocserv-ci-runner@sha256:<manifest digest>
**Refresh SLA:** with --disableupdate, the runner image MUST be rebuilt+redeployed
within 30 days of a new GitHub Actions Runner release (GitHub stops scheduling to
old runners ~30 days after a new release). Track actions/runner releases.

## Host setup (one-time, root, from audited clone — NOT user-writable checkout)
sudo git clone <repo> /root/ocserv-backport-install && cd /root/ocserv-backport-install
sudo git checkout <verified-sha>
sudo bash scripts/runner-host-install.sh   # root-owned provisioner + managed-chain firewall (hard-fail persist)
# Edit /etc/ocserv-ci-runner/provisioner.conf: fill RUNNER_IMAGE (manifest digest).
sudo chmod 0600 /etc/ocserv-ci-runner/provisioner.conf   # main() enforces root:root 0600
sudo iptables -S OCSERV_CI_EGRESS; sudo iptables -S OCSERV_CI_HOST_GUARD   # verify rules

NEVER run `sudo scripts/runner-provisioner.sh` from a user-writable checkout.
Always: /usr/local/libexec/ocserv-ci/runner-provisioner

## Launch (single-slot; sudo -n so it won't consume the token from stdin)
sudo -v
printf '%s\n' "$REGISTRATION_TOKEN" | sudo -n /usr/local/libexec/ocserv-ci/runner-provisioner --registration-token-stdin
unset REGISTRATION_TOKEN
# CSPRNG-generated name (live --runner-name forbidden). Bounded wait 5m..60m.
# audit events: start/exit/timeout/signal in /var/log/ocserv-ci-runner/lifecycle.log (root:root 0640 dir 0750).

## Lifecycle audit + diagnostics
- lifecycle.log: event=start|exit|timeout|signal, name, image digest, rc, timeout (NO token). root:root, dir 0750 log 0640.
- Runner app logs in /runner (tmpfs) vanish on exit. On drill failure, BEFORE exit, operator
  manually exports审查过的 _diag from inside the container. NEVER auto-copy _diag to repo/artifact/public logs.

## Lockdown verify (while running)
docker inspect <name> --format 'Privileged={{.HostConfig.Privileged}} ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}} User={{.Config.User}} OpenStdin={{.Config.OpenStdin}} NetworkMode={{.HostConfig.NetworkMode}} CapAdd={{.HostConfig.CapAdd}} Binds={{.HostConfig.Binds}}'
# Expect Privileged=false ReadonlyRootfs=true User=10001:10001 OpenStdin=true NetworkMode=ci-build-egress CapAdd=[] Binds=[]

## Firewall integration acceptance (RUNNER HOST — this is the ONLY network-isolation acceptance)
docker run --rm --network ci-build-egress --entrypoint /bin/sh <image@digest> -ec '
  curl -fsS --max-time 5 https://github.com >/dev/null && echo "github OK"
  curl -fsS --max-time 5 http://10.20.0.1/ && echo FAIL || echo "private denied OK"
  curl -fsS --max-time 5 http://169.254.169.254/ && echo FAIL || echo "metadata denied OK"
'
sudo iptables -S OCSERV_CI_EGRESS | grep br-ci-build-egress
sudo iptables -S OCSERV_CI_HOST_GUARD | grep br-ci-build-egress

## Image smoke (no token)
docker run --rm --entrypoint /bin/sh <image@digest> -ec '/opt/actions-runner-src/bin/Runner.Listener --version'

## Cleanup offline records
GitHub UI → Settings → Actions → Runners → offline → Remove (Phase 1 does NOT auto-clean).
```

- [ ] **Step 4: `shellcheck scripts/runner-host-install.sh` + commit** `feat(phase1): host install (correct bridge, managed chains, host-guard, IPv6 fail-closed, hard-fail persist)`.

**Checkpoint review (Task 6-7):** real firewall (two managed chains + host INPUT guard + IPv6 fail-closed + hard-fail persist), workflow dep closure, root-owned install + parent-path verify, runbook, audit events.

---

## Task 8: Workflow dual-track (trusted-event, contents:read, no secrets) + full verification

**Files:**
- Modify: `.github/workflows/ci-testing.yml`

- [ ] **Step 1: Dual-track job — locked-down scheduling boundary**

In `.github/workflows/ci-testing.yml` top-level add `permissions: { contents: read }`, then the job:

```yaml
permissions:
  contents: read

# ... existing jobs ...

  lock-projection-cibuild:
    # Phase 1 dual-track on ephemeral ci-build runner. Trusted-event only (no fork PR),
    # minimal token (contents: read), NO secrets/environment/id-token injected.
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

- [ ] **Step 2: Workflow boundary assertions** (grep-based, in Step 4 verification)

```bash
# No pull_request / pull_request_target path can reach a ci-build job:
python3 -c "import yaml; w=yaml.safe_load(open('.github/workflows/ci-testing.yml')); on=w.get('on',w.get(True,{})); print('pull_request' in str(on) and 'BLOCK' or 'ok')"
# ci-build appears only in lock-projection-cibuild; no secrets/env/id-token on it:
grep -c 'ci-build' .github/workflows/*.yml   # expect exactly 1 (this job)
! grep -A30 'lock-projection-cibuild' .github/workflows/ci-testing.yml | grep -E 'secrets:|environment:|id-token:'
# Runner registration URL is repository-scoped (runbook assert; org-level runner forbidden).
```

- [ ] **Step 3: YAML + full suite + shellcheck**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci-testing.yml'))" && echo OK
make test
shellcheck scripts/runner-provisioner.sh scripts/runner-host-install.sh docker/runner/entrypoint.sh
```

- [ ] **Step 4: Local dry-run + image smoke + boundary grep** (NO real token)

```bash
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
tmpcfg="$(mktemp)"; cat >"$tmpcfg" <<EOF
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/o/i@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2 RUNNER_MEMORY=6g RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g RUNNER_TMPFS_RUNNER_SIZE=1g RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
echo "dummy-not-real" | PROVISIONER_CONFIG="$tmpcfg" bash -c \
  "source scripts/runner-provisioner.sh; current_uid(){ echo 0; }; _config_metadata(){ printf 'root:root 600 regular'; }; _path_mode(){ printf '755'; }; docker(){ return 0; }; main --registration-token-stdin --dry-run --runner-name ci-build-VERIFY" 2>&1
rm -f "$tmpcfg"
# Expect: timeout ... docker run ... -i --stop-timeout=10 ... labels ...; NEVER 'dummy-not-real'; rc 0.
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci-testing.yml
git commit -m "feat(phase1): dual-track lock-projection (trusted-event, contents:read, no secrets) on ci-build"
```

> Real runner-host lifecycle drill (real short-lived token) ONLY after Steps 1-4 + the runbook firewall integration acceptance + image smoke pass. Never use a real registration token in automation. Runner must be repository-scoped (not org-level).

---

## Acceptance checklist (Phase 0 §11.3 + user Phase 1 closure + v1.3 revisions)

```text
Provisioner (test_runner_provisioner.bats):
  ☐ self-contained (no _common.sh); forbidden args rejected
  ☐ stdin token; dry-run NEVER prints token; rejects non-root (current_uid stub)
  ☐ -i/--interactive + --stop-timeout + ownership labels (managed-by/phase/runner-name)
  ☐ safe params; no privileged/socket/volume/cap-add/host-net; no secret env
  ☐ image 64-hex digest; config _config_metadata stub (root:root 600 regular); parent-path verify
  ☐ single-slot flock (2nd rejected; dry-run skips)
  ☐ image preflight (docker image inspect); name-free preflight (cleanup safety)
  ☐ timeout bounds [5m,60m]; rc captured under set -e; label-verified cleanup; audit events
  ☐ live --runner-name FORBIDDEN (CSPRNG-only)

Entrypoint (test_runner_entrypoint.bats):
  ☐ current_uid stubbable; rootfs ro (mount option); /tmp tmpfs+nosuid+nodev+noexec (+negatives); no-preserve copy

Network (pure = logic only; ISOLATION accepted ONLY via runbook integration test):
  ☐ policy two managed chains + IPv6 fail-closed; deny private/link-local/metadata; allow public 443/80; no GitHub IP allowlist
  ☐ installer: correct bridge --opt; verify existing network attrs (fail-closed); build+flush chains; host INPUT guard; IPv6 fail-closed; persist HARD-FAIL
  ☐ RUNBOOK integration: github OK; private/metadata denied; iptables -S shows both chains

Image supply chain:
  ☐ base NO default (digest required); ADD --checksum=; libicu76; util-linux; NO runtime pip
  ☐ build→push→pull by manifest digest; --pull=never; preflight image inspect; tarball SHA 64-hex validated
  ☐ image smoke (Runner.Listener --version); refresh SLA 30d in runbook

Workflow (ci-testing.yml):
  ☐ permissions: contents: read; if: trusted-event (push/workflow_dispatch on main); no secrets/env/id-token
  ☐ ci-build appears exactly once; runner registration repo-scoped (not org)

Runtime inspect: Privileged=false ReadonlyRootfs=true User=10001:10001 OpenStdin=true NetworkMode=ci-build-egress CapAdd=[] Binds=[] tmpfs limits digest

GitHub lifecycle: ci-build label; one lock-projection job; auto-deregister; --rm; single-slot flock; no host persistence; no aptly/GPG/R2/CF/SSH/prod cred

Audit/diagnostics: lifecycle.log events (start/exit/timeout/signal, no token, root:root dir 0750 log 0640); _diag manual export only; future external forwarding noted
```
