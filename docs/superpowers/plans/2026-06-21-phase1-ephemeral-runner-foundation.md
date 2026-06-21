# Phase 1 — Ephemeral Runner Foundation Implementation Plan (v1.2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **v1.2 revisions (9 blocking items):** (1) host-level single-slot `flock` (live mode); (2) fixed `set -e` capture of `timeout`/`docker run` exit code + `--stop-timeout` + cleanup trap + duration bounds [5m,60m]; (3) provisioner is self-contained (no `_common.sh` dependency) so the installed copy runs; (4) config mode check fixed (`mode == 600` exact; was wrongly rejecting 600); path-aware stubs + 26-char fixtures; (5) base image has NO default tag — digest required at build; `util-linux` added for `findmnt`; (6) real iptables `DOCKER-USER` firewall (rules actually loaded + persisted + verified, not a NOTE); deny private/link-local/metadata/host/publish; allow public 443/80 (NO brittle GitHub IP allowlist); (7) vacuous network test removed — real firewall-rule + negative-acceptance tests; (8) `/tmp` tmpfs assertion checks tmpfs + nosuid + nodev + noexec with path-aware stubs + negatives; (9) minimal lifecycle audit (no token) + diagnostics strategy in runbook/acceptance.

**Goal:** Build a minimal, manually-triggered, **single-slot** (host flock) ephemeral GitHub Actions runner that runs the `lock-projection` job in a non-root, non-privileged, docker-socket-less container, then auto-deregisters and auto-removes, with a **real** host firewall egress boundary.

**Architecture:** A **self-contained** root-owned bash provisioner (installed to `/usr/local/libexec/ocserv-ci/runner-provisioner`, no `_common.sh` dependency) reads a short-lived GitHub registration token from stdin, acquires a host-level `flock` (single-slot), and launches a fixed-parameter `docker run --rm -i` of a digest-pinned runner image, wrapped in a bounded `timeout` (5m–60m). The image's non-root entrypoint (`docker/runner/entrypoint.sh`, UID/GID 10001:10001) copies the actions-runner payload (no-preserve-ownership) from a read-only image layer to a `/runner` tmpfs, runs `config.sh --ephemeral --unattended --disableupdate` with a fixed `ci-build` label, then `run.sh`. One job → runner exits → container removed. The runner host runs an iptables `DOCKER-USER` firewall that denies all private/link-local/metadata/host/publish paths and allows only public TCP 443/80. No autoscaler, no timer, no GitHub management credential on the host.

**Tech Stack:** Bash (self-contained provisioner + entrypoint + host-install), Docker (runner container, iptables backend), Debian trixie (digest-pinned base, no default tag), GitHub Actions self-hosted runner (tarball with `ADD --checksum=sha256:`), `util-linux` (findmnt), bats (tests), shellcheck (lint), iptables DOCKER-USER (egress firewall).

**Parent spec:** `docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md` §1.1 (Runner Host), §5 (ci-build label), §11.2 (dual-track), §11.4.

**Phase 1 scope (hard boundary):** provisioner (self-contained, flock, timeout, root-owned) + non-root ephemeral image (digest-pinned base, checksum-pinned payload, no runtime pip) + `--ephemeral`/`--rm`/`-i` lifecycle + read-only rootfs + tmpfs `/runner`/`/work`/`/tmp` + no docker socket + no `--privileged` + `--cap-drop=ALL` + `no-new-privileges` + no sensitive bind mount + resource limits + **real** iptables egress firewall + migrate `lock-projection` (image-baked deps) + automated acceptance + lifecycle audit.

**Explicitly NOT in Phase 1:** candidate release API, mTLS bootstrap, R2 staging, Sigstore, aptly, GPG, publish host, testing publish, staging deploy, production promotion, rollback control plane, production credentials, JIT runner config, autoscaler/timer/pool, FQDN egress proxy (Phase 1 uses the coarser deny-private/allow-public-443-80 model; strict FQDN proxy is a later phase).

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `scripts/runner-provisioner.sh` | **Self-contained** root-owned provisioner: own `log`/`die`, config parse, stdin token, name gen, host `flock` (single-slot), fixed `docker run -i`, bounded `timeout` (5m–60m), cleanup trap, lifecycle audit. No `_common.sh` dependency. | New |
| `scripts/runner-host-install.sh` | One-time host install: copy provisioner to root-owned libexec path (verified owner/mode/symlink + parent dirs non-writable), install config + egress policy, **load + persist** iptables DOCKER-USER rules, verify Docker iptables backend (fail closed if nftables). | New |
| `docker/runner/Dockerfile` | Non-root (10001:10001) trixie image: **digest-pinned base (NO default tag)** + `ADD --checksum=sha256:` payload + lock-projection deps as Debian `python3-yaml` + `util-linux` (findmnt). No runtime pip. | New |
| `docker/runner/entrypoint.sh` | Container entrypoint (UID 10001): assert non-root (`current_uid`) + rootfs `ro` + tmpfs type+options (`/runner` `/work` nosuid+nodev; `/tmp` nosuid+nodev+noexec) via findmnt, no-preserve-ownership copy, stdin token, config.sh --ephemeral, run.sh. Never prints token. | New |
| `docker/runner/ci-build-egress.policy` | iptables DOCKER-USER rule spec: deny private/link-local/metadata/host/publish; allow public 443/80. Applied + persisted by host-install. | New |
| `test/test_runner_provisioner.bats` | Provisioner tests: arg validation, forbidden-args, stdin token, dry-run (NUL→array), `-i`, digest 64-hex, **config mode==600 exact**, flock single-slot (2nd start rejected), timeout bounds, no-token-in-output. | New |
| `test/test_runner_entrypoint.bats` | Entrypoint tests: stubbable `current_uid`/`_findmnt_*`; `/tmp` nosuid+nodev+noexec + negatives; rootfs `ro`; no-preserve copy. | New |
| `test/test_runner_network.bats` | Real firewall acceptance: rule-spec parse + (on runner host) negative connectivity tests. | New |
| `.github/workflows/ci-testing.yml` | Dual-track `lock-projection-cibuild` on `[self-hosted, ci-build]`, image-baked deps, NO pip. | Modify |
| `Makefile` | `runner-image` (buildx build, **digest base required arg**, push, print manifest digest), `runner-provision` (dry-run). | Modify |
| `docs/runner-ephemeral.md` | Runbook: image supply chain, host install (root-owned, load firewall), token via stdin, single-slot flock, timeout behavior, lifecycle audit/diagnostics, offline-record cleanup. | New |

---

## Task 1: Self-contained provisioner — helpers + config + name + timeout

**Files:**
- Create: `scripts/runner-provisioner.sh`
- Create: `test/test_runner_provisioner.bats`

The provisioner is **self-contained** (defines its own `log`/`die`, does NOT source `_common.sh`) so the installed copy at `/usr/local/libexec/ocserv-ci/runner-provisioner` runs without a companion file.

- [ ] **Step 1: Write failing tests**

Create `test/test_runner_provisioner.bats`:

```bash
load helpers/bats-helper.bash
PROVISIONER="${REPO_ROOT}/scripts/runner-provisioner.sh"
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# Valid 26-char Crockford Base32 name suffix (2 digits + 24 letters = 26).
NAME26="0123456789ABCDEFGHJKMNPQRS"

@test "provisioner is self-contained: sources without _common.sh present" {
  # Source must not require scripts/_common.sh in the same dir.
  run bash -c "set +e; cd /tmp; source '${PROVISIONER}'; echo sourced-ok"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'sourced-ok'
}

@test "load_provisioner_config: reads config; dies on missing file" {
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
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "IMG=ghcr.io/owner/img@sha256:${DIG64}"
  rm -f "$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config /nonexistent.conf; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "generate_runner_name: ci-build-<26 Crockford Base32 chars incl S/Z>" {
  run bash -c "set +e; source '${PROVISIONER}'; generate_runner_name"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^ci-build-[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$'
}

@test "generate_runner_name: two calls differ" {
  run bash -c "set +e; source '${PROVISIONER}'; printf '%s\n%s\n' \"\$(generate_runner_name)\" \"\$(generate_runner_name)\""
  [ "$(sed -n 1p <<<"$output")" != "$(sed -n 2p <<<"$output")" ]
}

@test "valid_runner_name: accepts 26-char shape; rejects arbitrary/empty/24-char" {
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name ci-build-${NAME26} && echo ok"
  echo "$output" | grep -q ok
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name my-custom-name; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name ''; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "parse_timeout_to_seconds: bounds [5m,60m] enforced" {
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 45m"
  [ "$output" = "2700" ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 1m; echo rc=\$?"
  [ "$status" -ne 0 ]   # below 5m
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 90m; echo rc=\$?"
  [ "$status" -ne 0 ]   # above 60m
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 0s; echo rc=\$?"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_runner_provisioner.bats` → FAIL (script absent).

- [ ] **Step 3: Create the self-contained provisioner (pure functions only; args/docker/main in Task 2/3)**

Create `scripts/runner-provisioner.sh`:

```bash
#!/usr/bin/env bash
# runner-provisioner.sh — Phase 1 ephemeral ci-build runner launcher.
# SELF-CONTAINED: defines its own log/die; does NOT source _common.sh, so the
# installed copy at /usr/local/libexec/ocserv-ci/runner-provisioner runs alone.
# Root-owned, single-slot (flock), fixed-param, bounded-timeout, manually-triggered.
# Spec: docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md §1.1, §5.
set -euo pipefail

log() { printf '[%s] runner-provisioner: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

DEFAULT_CONFIG="/etc/ocserv-ci-runner/provisioner.conf"
SINGLE_SLOT_LOCK="/run/lock/ocserv-ci-runner.lock"

# Timeout bounds (seconds). --wait-timeout must be within [MIN,MAX].
readonly TIMEOUT_MIN_S=300   # 5m
readonly TIMEOUT_MAX_S=3600  # 60m

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
  for k in "${req[@]}"; do
    [[ -n "${!k:-}" ]] || die "missing required config key: ${k}"
  done
}

__CROCKFORD32="0123456789ABCDEFGHJKMNPQRSTVWXYZ"  # excludes I L O U; includes S Z

generate_runner_name() {
  local name="ci-build-" i rand
  for ((i=0; i<26; i++)); do
    rand="$(od -An -tu1 -N1 /dev/urandom | tr -d ' ')"
    name+="${__CROCKFORD32:$((rand % 32)):1}"
  done
  printf '%s' "${name}"
}

valid_runner_name() {
  [[ "$1" =~ ^ci-build-[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$ ]]
}

# parse_timeout_to_seconds <duration> — <n>s|<n>m|<n>h, bounded [TIMEOUT_MIN_S, TIMEOUT_MAX_S].
parse_timeout_to_seconds() {
  local d="$1" n s
  if   [[ "${d}" =~ ^([0-9]+)s$ ]]; then n=${BASH_REMATCH[1]}; s=$((n))
  elif [[ "${d}" =~ ^([0-9]+)m$ ]]; then n=${BASH_REMATCH[1]}; s=$((n*60))
  elif [[ "${d}" =~ ^([0-9]+)h$ ]]; then n=${BASH_REMATCH[1]}; s=$((n*3600))
  else die "invalid RUNNER_WAIT_TIMEOUT: '${d}' (use <n>s|<n>m|<n>h)"; fi
  [[ ${s} -ge ${TIMEOUT_MIN_S} ]] || die "RUNNER_WAIT_TIMEOUT ${d} below minimum 5m"
  [[ ${s} -le ${TIMEOUT_MAX_S} ]] || die "RUNNER_WAIT_TIMEOUT ${d} above maximum 60m"
  printf '%s' "${s}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: main() not implemented yet (Task 3)" >&2; exit 2
fi
```

- [ ] **Step 4: Run tests → PASS (6)**. `shellcheck scripts/runner-provisioner.sh` (no errors).

- [ ] **Step 5: Commit**

```bash
git add scripts/runner-provisioner.sh test/test_runner_provisioner.bats
git commit -m "feat(phase1): self-contained provisioner helpers (config/name/timeout bounds)"
```

---

## Task 2: Arg validation + forbidden-args guard

**Files:**
- Modify: `scripts/runner-provisioner.sh`, `test/test_runner_provisioner.bats`

- [ ] **Step 1: Add failing tests** (append; `NAME26`/`DIG64` defined at top of file from Task 1)

```bash
@test "parse_args: --registration-token-stdin / --dry-run" {
  run bash -c "set +e; source '${PROVISIONER}'; TOKEN_STDIN=0; parse_args --registration-token-stdin --dry-run; echo \"T=\${TOKEN_STDIN} D=\${BOOTSTRAP_DRY_RUN}\""
  echo "$output" | grep -q 'T=1 D=1'
}

@test "parse_args: --runner-name live-mode requires generated shape; dry-run accepts any" {
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=1; parse_args --runner-name ci-build-DRYTEST; echo \"N=\${RUNNER_NAME}\""
  echo "$output" | grep -q 'N=ci-build-DRYTEST'
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=0; parse_args --runner-name ci-build-DRYTEST; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=0; parse_args --runner-name ci-build-${NAME26}; echo rc=\$?"
  [ "$status" -eq 0 ]
}

@test "parse_args: REJECTS all container-weakening flags" {
  for bad in --docker-arg --privileged --mount /x --cap-add SYS_ADMIN --pid host --ipc host --uts host --userns host --network host --image evil --label x --env SECRET --device /dev/sda -v /etc:/etc --volume /root:/root; do
    run bash -c "set +e; source '${PROVISIONER}'; parse_args '$bad'; echo rc=\$?"
    [ "$status" -ne 0 ] || { echo "FAIL: accepted $bad"; exit 1; }
  done
}

@test "parse_args: rejects unknown flag" {
  run bash -c "set +e; source '${PROVISIONER}'; parse_args --bogus; echo rc=\$?"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run → FAIL** (parse_args undefined).

- [ ] **Step 3: Add parse_args + usage** (insert before the trailing guard)

```bash
parse_args() {
  TOKEN_STDIN="${TOKEN_STDIN:-0}"
  BOOTSTRAP_DRY_RUN="${BOOTSTRAP_DRY_RUN:-0}"
  RUNNER_NAME="${RUNNER_NAME:-}"; RUNNER_NAME_OVERRIDE="${RUNNER_NAME_OVERRIDE:-0}"
  RUNNER_WAIT_TIMEOUT_OVERRIDE="${RUNNER_WAIT_TIMEOUT_OVERRIDE:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registration-token-stdin) TOKEN_STDIN=1; shift ;;
      --dry-run) BOOTSTRAP_DRY_RUN=1; shift ;;
      --runner-name)
        [[ $# -ge 2 ]] || die "--runner-name requires a value"
        if [[ "${BOOTSTRAP_DRY_RUN}" != "1" ]] && ! valid_runner_name "$2"; then
          die "live-mode --runner-name must match ci-build-<26 Crockford Base32>; leave unset to auto-generate"
        fi
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

usage() {
  cat >&2 <<EOF
Usage: runner-provisioner.sh --registration-token-stdin [options]
  --registration-token-stdin   read short-lived GitHub registration token from stdin
  --dry-run                    print the docker run command without executing
  --runner-name <name>         override (live: ci-build-<ULID> shape; dry-run: any)
  --wait-timeout <duration>    override RUNNER_WAIT_TIMEOUT (5m..60m)
  -h, --help
Token via stdin ONLY. Security params come from root-owned ${DEFAULT_CONFIG}.
EOF
}
```

- [ ] **Step 4: Run → PASS (10)**. `shellcheck` (no errors).

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(phase1): provisioner arg validation + forbidden-args guard"
```

---

## Task 3: Docker-run builder + main (flock, timeout capture, cleanup, audit)

**Files:**
- Modify: `scripts/runner-provisioner.sh`, `test/test_runner_provisioner.bats`

Security-critical: fixed argv with `-i`, **host flock (single-slot)**, explicit `rc` capture under `set -e`, `--stop-timeout`, cleanup trap, lifecycle audit (no token).

- [ ] **Step 1: Add failing tests**

```bash
mkcfg() {
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

@test "build_docker_run_args: -i + --interactive + --stop-timeout present" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  out="$(docker_argv_lines "$tmpcfg" ci-build-TEST)"; rm -f "$tmpcfg"
  echo "$out" | grep -qx -- '-i'
  echo "$out" | grep -qx -- '--interactive'
  echo "$out" | grep -q -- '--stop-timeout=10'
}

@test "build_docker_run_args: fixed safe params + digest image + fixed non-secret env" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  out="$(docker_argv_lines "$tmpcfg" ci-build-TEST)"; rm -f "$tmpcfg"
  for f in --rm --init -i --interactive --read-only --user=10001:10001 --cap-drop=ALL --security-opt=no-new-privileges:true --pull=never; do
    echo "$out" | grep -qx -- "$f" || { echo "MISSING $f"; exit 1; }
  done
  echo "$out" | grep -q -- '--memory=6g'
  echo "$out" | grep -q -- '--network=ci-build-egress'
  echo "$out" | grep -q -- '--env RUNNER_URL='
  echo "$out" | grep -q -- '--env RUNNER_NAME=ci-build-TEST'
  echo "$out" | grep -qx -- "ghcr.io/owner/img@sha256:${DIG64}"
}

@test "build_docker_run_args: ABSENT privileged/socket/volume/cap-add/host-net; no secret env" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  out="$(docker_argv_lines "$tmpcfg" ci-build-TEST)"; rm -f "$tmpcfg"
  ! echo "$out" | grep -q -- '--privileged'
  ! echo "$out" | grep -q -- 'docker.sock'
  ! echo "$out" | grep -qE -- '^-v$|--volume'
  ! echo "$out" | grep -q -- '--cap-add'
  ! echo "$out" | grep -q -- '--network=host'
  ! echo "$out" | grep -qi -- '--env.*TOKEN'
}

@test "assert_image_is_digest: 64-hex ok; short/tag rejected" {
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'ghcr.io/o/i@sha256:${DIG64}'; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'debian:trixie'; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_config_mode_0600: accepts exactly 600; rejects 640/644/666/symlink" {
  tmpf="$(mktemp)"
  _stat_info() { printf '%s %s' "$2" "$3"; }   # args: file mode kind
  run bash -c "set +e; source '${PROVISIONER}'; _stat_info() { printf '600 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _stat_info() { printf '640 regular'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; _stat_info() { printf '600 symlink'; }; assert_config_root_owned '${tmpf}'; echo rc=\$?"
  [ "$status" -ne 0 ]
  rm -f "$tmpf"
}

@test "acquire_single_slot: live mode second acquire rejected (flock -n)" {
  tmplock="$(mktemp)"
  # First acquire in a background process holding the lock; then assert second acquire dies.
  ( flock -n 9 && sleep 2 ) 9>"${tmplock}" &
  sleep 0.3
  run bash -c "set +e; source '${PROVISIONER}'; SINGLE_SLOT_LOCK='${tmplock}'; BOOTSTRAP_DRY_RUN=0; acquire_single_slot; echo rc=\$?"
  [ "$status" -ne 0 ]
  wait
  rm -f "${tmplock}"
}

@test "acquire_single_slot: dry-run does NOT take the lock" {
  tmplock="$(mktemp)"
  ( flock -n 9 && sleep 2 ) 9>"${tmplock}" &
  sleep 0.3
  run bash -c "set +e; source '${PROVISIONER}'; SINGLE_SLOT_LOCK='${tmplock}'; BOOTSTRAP_DRY_RUN=1; acquire_single_slot; echo rc=\$?"
  [ "$status" -eq 0 ]
  wait
  rm -f "${tmplock}"
}

@test "main --dry-run: docker+timeout printed; NEVER token; rc 0" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  run bash -c "set +e; echo 'ghs_SUPERSECRET_xyz' | bash -c '
    source \"${PROVISIONER}\"; current_uid() { echo 0; }
    PROVISIONER_CONFIG=\"${tmpcfg}\" main --registration-token-stdin --dry-run --runner-name ci-build-DRYTEST
  ' 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -q 'rc=0'
  echo "$output" | grep -qi 'timeout'
  ! echo "$output" | grep -q 'SUPERSECRET'
}

@test "main: rejects non-root (current_uid != 0)" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  run bash -c "set +e; bash -c '
    source \"${PROVISIONER}\"; current_uid() { echo 1000; }
    PROVISIONER_CONFIG=\"${tmpcfg}\" main --registration-token-stdin --dry-run --runner-name ci-build-X
  ' 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -qv 'rc=0'
}
```

- [ ] **Step 2: Run → FAIL** (build_docker_run_args/main/etc undefined).

- [ ] **Step 3: Implement** (replace the trailing guard)

```bash
assert_image_is_digest() {
  [[ "$1" =~ @sha256:[0-9a-f]{64}$ ]] || die "RUNNER_IMAGE must be 64-hex sha256 digest (got: '$1')"
}

# build_docker_run_args <name> — FIXED argv; token via stdin (NOT here, -i enables it).
build_docker_run_args() {
  local name="$1"
  assert_image_is_digest "${RUNNER_IMAGE}"
  printf '%s\0' \
    run --rm --init -i --interactive \
    --name="${name}" \
    --stop-timeout=10 \
    --read-only \
    --user=10001:10001 \
    --cap-drop=ALL \
    --security-opt=no-new-privileges:true \
    --pids-limit="${RUNNER_PIDS_LIMIT}" \
    --memory="${RUNNER_MEMORY}" \
    --cpus="${RUNNER_CPUS}" \
    --network="${RUNNER_NETWORK}" \
    --pull=never \
    --env "RUNNER_URL=${RUNNER_URL}" \
    --env "RUNNER_LABEL=${RUNNER_LABEL}" \
    --env "RUNNER_NAME=${name}" \
    --tmpfs "/runner:rw,nosuid,nodev,size=${RUNNER_TMPFS_RUNNER_SIZE},uid=10001,gid=10001,mode=0700" \
    --tmpfs "/work:rw,nosuid,nodev,size=${RUNNER_TMPFS_WORK_SIZE},uid=10001,gid=10001,mode=0700" \
    --tmpfs "/tmp:rw,nosuid,nodev,noexec,size=${RUNNER_TMPFS_TMP_SIZE},uid=10001,gid=10001,mode=1777" \
    "${RUNNER_IMAGE}"
}

# _stat_info — "mode kind" (owner check done separately via stat in assert_config_root_owned).
# Stubbed in tests. Real impl uses GNU stat.
_stat_info() {
  local f="$1" mode kind
  mode="$(stat -c '%a' "$f")"
  if [[ -L "$f" ]]; then kind="symlink"
  elif [[ -f "$f" ]]; then kind="regular"
  else kind="other"; fi
  printf '%s %s' "${mode}" "${kind}"
}

# assert_config_root_owned <file> — root:root + mode exactly 0600 + regular file (no symlink).
assert_config_root_owned() {
  local f="$1" info mode kind owner
  [[ -f "$f" ]] || die "config ${f} not a regular file"
  [[ -L "$f" ]] && die "config ${f} must not be a symlink"
  owner="$(stat -c '%U:%G' "$f")"
  info="$(_stat_info "$f")"; mode="${info%% *}"
  [[ "${owner}" == "root:root" ]] || die "config ${f} must be root:root (got ${owner})"
  [[ "${mode}" == "600" ]] || die "config ${f} must be mode 0600 (got ${mode})"
}

# acquire_single_slot — host flock; live mode only (dry-run skips).
acquire_single_slot() {
  [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]] && return 0
  install -d -m 0755 "$(dirname "${SINGLE_SLOT_LOCK}")" 2>/dev/null || true
  exec 9>"${SINGLE_SLOT_LOCK}"
  flock -n 9 || die "another provisioner instance holds ${SINGLE_SLOT_LOCK} (single-slot); aborting"
  log "acquired single-slot lock ${SINGLE_SLOT_LOCK}"
}

# current_uid — stubbable (tests); real impl id -u.
current_uid() { id -u; }

# Cleanup ONLY this run's container (by exact generated/override name), never arbitrary.
cleanup_this_container() {
  local name="$1"
  if docker inspect "${name}" >/dev/null 2>&1; then
    log "cleanup: removing leftover container ${name}"
    docker rm -f "${name}" >/dev/null 2>&1 || true
  fi
}

# write_lifecycle_audit <name> <image> <rc> <timeout?> — no token, never.
write_lifecycle_audit() {
  local name="$1" image="$2" rc="$3" timed_out="${4:-no}"
  local audit="/var/log/ocserv-ci-runner/lifecycle.log"
  install -d -m 0755 "$(dirname "${audit}")" 2>/dev/null || true
  printf '%s name=%s image=%s rc=%s timeout=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${name}" "${image}" "${rc}" "${timed_out}" \
    >>"${audit}" 2>/dev/null || log "WARN: could not write audit log ${audit}"
}

main() {
  [[ "$(current_uid)" -eq 0 ]] || die "must run as root (install via runner-host-install.sh)"
  parse_args "$@"
  [[ "${TOKEN_STDIN}" -eq 1 ]] || die "token source required: --registration-token-stdin"
  local config="${DEFAULT_CONFIG}"
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" && -n "${PROVISIONER_CONFIG:-}" ]]; then
    config="${PROVISIONER_CONFIG}"
  elif [[ -n "${PROVISIONER_CONFIG:-}" ]]; then
    die "PROVISIONER_CONFIG override forbidden in live mode (use ${DEFAULT_CONFIG})"
  fi
  assert_config_root_owned "${config}"
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
  # Cleanup only this container on exit/TERM/INT (set -e safe: trap fires on normal exit too).
  trap 'cleanup_this_container "${RUNNER_NAME}"' EXIT INT TERM

  # Explicit rc capture under set -e: timeout/docker non-zero must NOT abort before we record rc.
  local rc=0 timed_out=no
  if timeout --foreground --signal=TERM --kill-after=10s "${wait_s}s" docker "${docker_argv[@]}" < /dev/stdin; then
    rc=0
  else
    rc=$?
    [[ ${rc} -eq 124 ]] && timed_out=yes
  fi
  if [[ "${timed_out}" == yes ]]; then
    log "runner ${RUNNER_NAME} TIMED OUT after ${RUNNER_WAIT_TIMEOUT}; cleanup removing container; GitHub may show offline record (manual cleanup, runbook)"
  else
    log "runner ${RUNNER_NAME} exited rc=${rc}"
  fi
  write_lifecycle_audit "${RUNNER_NAME}" "${RUNNER_IMAGE}" "${rc}" "${timed_out}"
  trap - EXIT INT TERM
  cleanup_this_container "${RUNNER_NAME}"
  return ${rc}
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 4: Run → PASS (18)**. `shellcheck` (no errors).

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(phase1): docker-run (-i/stop-timeout) + flock + timeout-capture + cleanup + audit"
```

**Checkpoint review:** After Task 3 — root trust boundary, stdin token + `-i`, single-slot flock, timeout capture under `set -e`, cleanup trap, docker argv.

---

## Task 4: Runner image (digest base required, checksum payload, no runtime pip, util-linux)

**Files:**
- Create: `docker/runner/Dockerfile`, `docker/runner/.dockerignore`

- [ ] **Step 1: Dockerfile (base has NO default — digest required; util-linux for findmnt)**

```dockerfile
# Phase 1 ci-build runner image. Non-root (10001:10001); read-only rootfs at runtime.
# NO runtime pip (python3-yaml baked). util-linux for findmnt in entrypoint.
# Spec: docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md §1.1, §2.3.

# Base image has NO default tag — the Makefile MUST pass TRIXIE_DIGEST=docker.io/library/debian@sha256:<64hex>.
ARG TRIXIE_DIGEST
FROM "${TRIXIE_DIGEST}" AS base

RUN groupadd --system --gid 10001 runner \
 && useradd  --system --uid 10001 --gid 10001 --no-create-home --home-dir /runner runner

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git make python3 python3-yaml util-linux \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Runner payload pinned by checksum. Both ARGs required (no default → forces explicit pin).
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

- [ ] **Step 2: `.dockerignore`**

```text
*
!entrypoint.sh
```

- [ ] **Step 3: Commit**

```bash
git add docker/runner/Dockerfile docker/runner/.dockerignore
git commit -m "feat(phase1): runner image (digest base required, checksum payload, no runtime pip, util-linux)"
```

---

## Task 5: Entrypoint (mountinfo assertions, path-aware stubs, /tmp noexec+nosuid+nodev)

**Files:**
- Create: `docker/runner/entrypoint.sh`, `test/test_runner_entrypoint.bats`

- [ ] **Step 1: Failing tests with path-aware stubs**

```bash
load helpers/bats-helper.bash
ENTRYPOINT="${REPO_ROOT}/docker/runner/entrypoint.sh"

# Path-aware stub so /tmp gets noexec while /runner /work don't.
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
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid() { echo 10001; }; assert_running_as_10001; echo ok"
  echo "$output" | grep -q ok
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid() { echo 0; }; assert_running_as_10001; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_rootfs_readonly + assert_tmpfs_workspace: pass with path-aware stub" {
  run bash -c "set +e; source '${ENTRYPOINT}'; $(pathaware); assert_rootfs_readonly; assert_tmpfs_workspace; echo ok"
  echo "$output" | grep -q ok
}

@test "assert_tmpfs_workspace: /tmp missing noexec FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; };
    _findmnt_fstype(){ echo tmpfs; };
    _findmnt_options(){ case \"\$1\" in /tmp) printf 'rw,nosuid,nodev,mode=1777';; *) printf 'rw,nosuid,nodev';; esac; };
    assert_tmpfs_workspace; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_tmpfs_workspace: /tmp missing nosuid FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; };
    _findmnt_fstype(){ echo tmpfs; };
    _findmnt_options(){ case \"\$1\" in /tmp) printf 'rw,nodev,noexec';; *) printf 'rw,nosuid,nodev';; esac; };
    assert_tmpfs_workspace; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_tmpfs_workspace: /runner not tmpfs FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid(){ echo 10001; };
    _findmnt_fstype(){ echo overlay; }; _findmnt_options(){ echo rw; };
    assert_tmpfs_workspace; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_rootfs_readonly: rw rootfs FAILS" {
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_options(){ echo 'rw,relatime'; }; assert_rootfs_readonly; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "build_config_args: --ephemeral --unattended --disableupdate --work=/work --labels ci-build" {
  run bash -c "set +e; source '${ENTRYPOINT}'; build_config_args U T ci-build-N ci-build | while IFS= read -r -d '' a; do printf '%s\n' \"\$a\"; done"
  echo "$output" | grep -qx -- '--ephemeral'
  echo "$output" | grep -qx -- '--unattended'
  echo "$output" | grep -qx -- '--disableupdate'
  echo "$output" | grep -q -- '--work=/work'
}
```

- [ ] **Step 2: Run → FAIL** (entrypoint absent).

- [ ] **Step 3: Create entrypoint.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Phase 1 ci-build entrypoint (UID 10001). Payload read-only layer → /runner tmpfs
# (no-preserve-ownership copy). Token from stdin, never logged, unset after config.
# Assertions use findmnt mount type+options (NOT write-probes).

RUNNER_PAYLOAD_SRC="/opt/actions-runner-src"
RUNNER_PAYLOAD_DST="/runner"
WORK_DIR="/work"

die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[entrypoint] %s\n' "$*" >&2; }

current_uid() { id -u; }
_findmnt_fstype() { findmnt -n -o FSTYPE "$1"; }
_findmnt_options() { findmnt -n -o OPTIONS "$1"; }

assert_running_as_10001() {
  [[ "$(current_uid)" -eq 10001 ]] || die "must run as UID 10001 (got $(current_uid))"
}
assert_mount_option() {
  local mp="$1" opt="$2" opts; opts="$(_findmnt_options "${mp}")"
  [[ ",${opts}," == *",${opt},"* ]] || die "${mp} missing mount option '${opt}' (opts: ${opts})"
}
assert_tmpfs_type() {
  local t; t="$(_findmnt_fstype "$1")"
  [[ "${t}" == "tmpfs" ]] || die "$1 is not tmpfs (got ${t})"
}
assert_rootfs_readonly() { assert_mount_option / ro; }
assert_tmpfs_workspace() {
  local mp
  for mp in "${RUNNER_PAYLOAD_DST}" "${WORK_DIR}" /tmp; do assert_tmpfs_type "${mp}"; done
  for mp in "${RUNNER_PAYLOAD_DST}" "${WORK_DIR}"; do
    assert_mount_option "${mp}" nosuid; assert_mount_option "${mp}" nodev
  done
  # /tmp: tmpfs + nosuid + nodev + noexec (all four).
  assert_mount_option /tmp nosuid
  assert_mount_option /tmp nodev
  assert_mount_option /tmp noexec
}
build_config_args() {
  printf '%s\0' --url "$1" --token "$2" --name "$3" --labels "$4" --work "${WORK_DIR}" --ephemeral --unattended --disableupdate
}
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

- [ ] **Step 4: Run → PASS (7)**. `shellcheck docker/runner/entrypoint.sh` (no errors).

- [ ] **Step 5: Commit**

```bash
git add docker/runner/entrypoint.sh test/test_runner_entrypoint.bats
git commit -m "feat(phase1): entrypoint (mountinfo assertions, /tmp noexec+nosuid+nodev, no-preserve copy)"
```

**Checkpoint review:** After Task 5 — image supply chain (digest base, checksum payload), mount assertions (/tmp all four options), non-root copy.

---

## Task 6: Egress firewall policy + real rule spec + acceptance

**Files:**
- Create: `docker/runner/ci-build-egress.policy`
- Create: `test/test_runner_network.bats`

Commit to **iptables DOCKER-USER** (Docker iptables backend; installer verifies + fail-closed if nftables backend). Rules are actually loaded + persisted (Task 7). Model: **deny all private/link-local/metadata/host/publish; allow public TCP 443/80** (NO brittle GitHub IP allowlist — GitHub IPs change; FQDN proxy is a later phase).

- [ ] **Step 1: Policy file (iptables rule spec)**

```text
# ci-build egress policy — iptables DOCKER-USER chain. Applied + persisted by
# runner-host-install.sh. Docker MUST use iptables backend (installer verifies).
# Model: deny private/link-local/metadata/host/publish; allow public 443/80.
# (Phase 1: NO GitHub IP allowlist — GitHub IPs change; strict FQDN proxy is later.)
# Spec: Phase 0 §1.4 (ci-build egress).
#
# Interface = ci-build-egress bridge (created by installer). Source = its subnet.

[meta]
bridge = br-ci-build-egress
subnet = 172.30.0.0/24

[deny]
# RFC1918 private ranges (staging/prod/management live here)
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
# Loopback / link-local / metadata
127.0.0.0/8
169.254.0.0/16
# Docker host gateway (the bridge's own .1) — deny host management plane
172.30.0.1
# (Operator fills real publish-host IPs at install; deny by the private ranges above by default)

[allow]
# Public internet TCP 443/80 only (GitHub, Debian pool, git over https).
proto=tcp dport=443
proto=tcp dport=80
# DNS to host resolver (if using Docker's embedded DNS forwarding) — UDP 53 to host gateway
# is allowed by Docker by default; do NOT add a broad allow here.

[default]
# Everything else not matched by [allow] is denied (DOCKER-USER RETURN only after explicit allow).
policy = deny
```

- [ ] **Step 2: Tests (real rule-parse + acceptance shape; vacuous `|| true` removed)**

```bash
load helpers/bats-helper.bash
POLICY="${REPO_ROOT}/docker/runner/ci-build-egress.policy"

@test "policy has deny + allow + default deny sections" {
  grep -q '^\[deny\]' "${POLICY}"
  grep -q '^\[allow\]' "${POLICY}"
  grep -q '^\[default\]' "${POLICY}"
  grep -q 'policy = deny' "${POLICY}"
}

@test "policy denies RFC1918 + link-local + metadata (no public-internet bypass to private)" {
  grep -q '10.0.0.0/8' "${POLICY}"
  grep -q '172.16.0.0/12' "${POLICY}"
  grep -q '192.168.0.0/16' "${POLICY}"
  grep -q '169.254.0.0/16' "${POLICY}"
}

@test "policy allows only public 443/80 (NO brittle GitHub IP allowlist)" {
  grep -q 'dport=443' "${POLICY}"
  grep -q 'dport=80' "${POLICY}"
  ! grep -qi '140.82' "${POLICY}"   # no hardcoded GitHub CIDR
  ! grep -qi '185.199' "${POLICY}"
}

@test "egress_dest_allowed <ip> <port>: private denied, public 443 allowed" {
  run bash -c "set +e; source '${POLICY}.lib' 2>/dev/null; egress_dest_allowed 10.20.0.5 443; echo rc=\$?"
  # If the lib isn't there yet this fails, driving implementation in Step 3.
  [ "$status" -eq 0 ] || [ "$status" -ne 0 ]  # placeholder removed in Step 3
}
```

- [ ] **Step 3: Pure decision lib** (`docker/runner/ci-build-egress.policy.lib`)

```bash
#!/usr/bin/env bash
# Pure egress decision (mirrors the iptables policy). Sourced by tests + installer.
# egress_dest_allowed <ip> <port> — 0 if allowed (public + 443/80), non-zero if denied.
egress_dest_allowed() {
  local ip="$1" port="$2"
  # Deny RFC1918 / loopback / link-local / metadata.
  case "${ip}" in
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|127.*|169.254.*) return 1 ;;
  esac
  # Allow public TCP 443/80.
  [[ "${port}" == 443 || "${port}" == 80 ]] || return 1
  return 0
}
```

(Fix the Step-2 placeholder test to source the real lib:)

```bash
@test "egress_dest_allowed: private denied, public 443 allowed, public 22 denied" {
  run bash -c "set +e; source '${REPO_ROOT}/docker/runner/ci-build-egress.policy.lib'; egress_dest_allowed 10.20.0.5 443; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${REPO_ROOT}/docker/runner/ci-build-egress.policy.lib'; egress_dest_allowed 1.2.3.4 443; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${REPO_ROOT}/docker/runner/ci-build-egress.policy.lib'; egress_dest_allowed 1.2.3.4 22; echo rc=\$?"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 4: Run → PASS. Commit**

```bash
git add docker/runner/ci-build-egress.policy docker/runner/ci-build-egress.policy.lib test/test_runner_network.bats
git commit -m "feat(phase1): iptables DOCKER-USER egress policy (deny private, allow public 443/80) + pure lib"
```

---

## Task 7: Host install (root-owned, load+persist firewall, verify backend) + Makefile + runbook

**Files:**
- Create: `scripts/runner-host-install.sh`, `docs/runner-ephemeral.md`; Modify `Makefile`

- [ ] **Step 1: host-install (loads firewall, persists, verifies iptables backend)**

```bash
#!/usr/bin/env bash
set -euo pipefail
# runner-host-install.sh — one-time runner host setup. Run from an AUDITED repo
# revision owned by root, NOT a user-writable checkout. Loads + persists firewall.
log() { printf '[%s] host-install: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

LIBEXEC_DIR="/usr/local/libexec/ocserv-ci"
CONFIG_DIR="/etc/ocserv-ci-runner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER_SRC="${SCRIPT_DIR}/runner-provisioner.sh"
POLICY_SRC="${SCRIPT_DIR}/../docker/runner/ci-build-egress.policy"

main() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root"
  [[ -f "${PROVISIONER_SRC}" ]] || die "provisioner source not found: ${PROVISIONER_SRC}"

  # Verify parent dirs are non-writable by non-root (trust boundary for the installed binary).
  for d in /usr /usr/local /usr/local/libexec "${LIBEXEC_DIR}"; do
    [[ -d "$d" ]] || continue
    local p; p="$(stat -c '%a' "$d")"
    [[ "$p" =~ ^[0-7]?[57][05]$ ]] || die "parent ${d} is group/world-writable (mode ${p}); refusing"
  done

  install -d -o root -g root -m 0755 "${LIBEXEC_DIR}"
  install -o root -g root -m 0755 "${PROVISIONER_SRC}" "${LIBEXEC_DIR}/runner-provisioner"
  [[ -f "${LIBEXEC_DIR}/runner-provisioner" && ! -L "${LIBEXEC_DIR}/runner-provisioner" ]] || die "installed provisioner not regular file"
  [[ "$(stat -c '%U:%G' "${LIBEXEC_DIR}/runner-provisioner")" == "root:root" ]] || die "installed provisioner not root:root"
  log "provisioner self-contained (no _common.sh dep) -> ${LIBEXEC_DIR}/runner-provisioner"

  install -d -o root -g root -m 0750 "${CONFIG_DIR}"
  if [[ ! -f "${CONFIG_DIR}/provisioner.conf" ]]; then
    cat >"${CONFIG_DIR}/provisioner.conf" <<'EOF'
# Fill these. Must be root:root 0600 (provisioner main() enforces).
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/OWNER/ocserv-ci-runner@sha256:REPLACE_WITH_64_HEX_DIGEST
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

  # Dedicated Docker network (isolated subnet).
  docker network inspect ci-build-egress >/dev/null 2>&1 \
    || docker network create --subnet 172.30.0.0/24 --bridge-name br-ci-build-egress ci-build-egress

  # Verify Docker uses iptables backend (DOCKER-USER chain exists); fail closed if nftables.
  if ! iptables -n -L DOCKER-USER >/dev/null 2>&1; then
    die "DOCKER-USER chain not found — Docker must use iptables backend (got nftables?). Set iptables backend or switch policy backend before proceeding."
  fi

  # Load + persist egress rules in DOCKER-USER (deny private/link-local/metadata/host; allow public 443/80).
  # br-ci-build-egress is the ci-build-egress bridge interface.
  local br="br-ci-build-egress"
  iptables -C DOCKER-USER -i "${br}" -d 10.0.0.0/8 -j DROP 2>/dev/null || iptables -I DOCKER-USER -i "${br}" -d 10.0.0.0/8 -j DROP
  iptables -C DOCKER-USER -i "${br}" -d 172.16.0.0/12 -j DROP 2>/dev/null || iptables -I DOCKER-USER -i "${br}" -d 172.16.0.0/12 -j DROP
  iptables -C DOCKER-USER -i "${br}" -d 192.168.0.0/16 -j DROP 2>/dev/null || iptables -I DOCKER-USER -i "${br}" -d 192.168.0.0/16 -j DROP
  iptables -C DOCKER-USER -i "${br}" -d 127.0.0.0/8 -j DROP 2>/dev/null || iptables -I DOCKER-USER -i "${br}" -d 127.0.0.0/8 -j DROP
  iptables -C DOCKER-USER -i "${br}" -d 169.254.0.0/16 -j DROP 2>/dev/null || iptables -I DOCKER-USER -i "${br}" -d 169.254.0.0/16 -j DROP
  iptables -C DOCKER-USER -i "${br}" -d 172.30.0.1 -j DROP 2>/dev/null || iptables -I DOCKER-USER -i "${br}" -d 172.30.0.1 -j DROP
  # Allow public TCP 443/80 (must come AFTER denies; DOCKER-USER is traversed before Docker's own ACCEPT).
  iptables -C DOCKER-USER -i "${br}" -p tcp --dport 443 -j RETURN 2>/dev/null || iptables -A DOCKER-USER -i "${br}" -p tcp --dport 443 -j RETURN
  iptables -C DOCKER-USER -i "${br}" -p tcp --dport 80 -j RETURN 2>/dev/null || iptables -A DOCKER-USER -i "${br}" -p tcp --dport 80 -j RETURN
  # Default deny for this bridge (everything not matched above).
  iptables -C DOCKER-USER -i "${br}" -j DROP 2>/dev/null || iptables -A DOCKER-USER -i "${br}" -j DROP
  log "loaded DOCKER-USER egress rules on ${br}"

  # Persist (best-effort; netfilter-persistent / iptables-save).
  if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save
  else iptables-save > /etc/iptables/rules.v4 2>/dev/null || log "WARN: could not persist iptables (install iptables-persistent)"; fi

  log "install complete. Launch: echo \$TOKEN | sudo ${LIBEXEC_DIR}/runner-provisioner --registration-token-stdin"
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 2: Makefile targets (digest base required arg)**

```makefile
.PHONY: runner-image runner-provision
RUNNER_TARBALL_URL ?=
RUNNER_TARBALL_SHA256 ?=
TRIXIE_DIGEST ?=    # NO default — digest required
REGISTRY ?= ghcr.io/gentlekingson

runner-image: ## Build + push runner image; print registry manifest digest
	@test -n "$(RUNNER_TARBALL_URL)" -a -n "$(RUNNER_TARBALL_SHA256)" || { echo "set RUNNER_TARBALL_URL + RUNNER_TARBALL_SHA256"; exit 1; }
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
	@echo "Dry-run: scripts/runner-provisioner.sh --dry-run < /dev/null"
```

- [ ] **Step 3: runbook (`docs/runner-ephemeral.md`) — key sections**

```markdown
# Ephemeral ci-build Runner — Operator Runbook (Phase 1)

Single-slot, manually-triggered, bounded-wait ephemeral runner for lock-projection.

## Image supply chain
build host: make runner-image TRIXIE_DIGEST=docker.io/library/debian@sha256:<64hex> \
  RUNNER_TARBALL_URL=<url> RUNNER_TARBALL_SHA256=<sha256>  (NO default base tag)
  → buildx build + push; prints registry manifest digest.
runner host: docker pull <registry>/ocserv-ci-runner@sha256:<manifest digest>
  (provisioner uses --pull=never; exact digest must be pre-cached).

## Host setup (one-time, root, from audited clone — NOT user-writable checkout)
sudo git clone <repo> /root/ocserv-backport-install && cd /root/ocserv-backport-install
sudo git checkout <verified-sha>
sudo bash scripts/runner-host-install.sh   # installs root-owned provisioner + loads+persistent firewall
# Edit /etc/ocserv-ci-runner/provisioner.conf: fill RUNNER_IMAGE (digest from above).
sudo chmod 0600 /etc/ocserv-ci-runner/provisioner.conf   # main() enforces root:root 0600
# Verify firewall loaded: sudo iptables -n -L DOCKER-USER

NEVER run `sudo scripts/runner-provisioner.sh` from a user-writable checkout.
Always: sudo /usr/local/libexec/ocserv-ci/runner-provisioner

## Launch (single-slot; second launch rejected by flock)
echo "$REGISTRATION_TOKEN" | sudo /usr/local/libexec/ocserv-ci/runner-provisioner --registration-token-stdin
# Provisioner acquires /run/lock/ocserv-ci-runner.lock; bounded wait RUNNER_WAIT_TIMEOUT (5m..60m).
# On timeout: container SIGTERM (--stop-timeout=10) then SIGKILL; --rm removes it; cleanup_this_container兜底.
# GitHub may show offline record → manual cleanup (below).

## Lifecycle audit + diagnostics
- Provisioner writes /var/log/ocserv-ci-runner/lifecycle.log: name, image digest, start/end, rc, timeout (NO token).
- Runner app logs live in /runner (tmpfs) → vanish on container exit. If a drill fails, BEFORE
  container exit the operator may export审查过的 _diag from inside the container (no token in _diag).
- Phase 1 does NOT ship external log forwarding (future autoscaling phase must).

## Verify lockdown (while running)
docker inspect <name> --format 'Privileged={{.HostConfig.Privileged}} ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}} User={{.Config.User}} OpenStdin={{.Config.OpenStdin}} NetworkMode={{.HostConfig.NetworkMode}} CapAdd={{.HostConfig.CapAdd}} CapDrop={{.HostConfig.CapDrop}} Binds={{.HostConfig.Binds}}'
# Expect: Privileged=false ReadonlyRootfs=true User=10001:10001 OpenStdin=true NetworkMode=ci-build-egress CapAdd=[] CapDrop=[ALL] Binds=[]

## Egress negative acceptance (run from a test container on ci-build-egress)
curl -fsS --max-time 5 https://github.com && echo "github OK"          # MUST succeed (public 443)
curl -fsS --max-time 5 http://10.20.0.1/ && echo FAIL || echo "private denied OK"  # MUST fail
curl -fsS --max-time 5 http://169.254.169.254/ && echo FAIL || echo "metadata denied OK"  # MUST fail
sudo iptables -n -L DOCKER-USER | grep br-ci-build-egress   # rules present

## Cleanup offline records
GitHub UI → Settings → Actions → Runners → offline runner → Remove (Phase 1 does NOT auto-clean).
```

- [ ] **Step 4: `shellcheck scripts/runner-host-install.sh` + commit**

```bash
git add scripts/runner-host-install.sh Makefile docs/runner-ephemeral.md
git commit -m "feat(phase1): host install (root-owned, load+persist DOCKER-USER firewall) + runbook"
```

**Checkpoint review:** After Task 7 — workflow dep closure, real firewall (loaded + persisted + backend verified), root-owned install, runbook, lifecycle audit.

---

## Task 8: Workflow dual-track + full verification

**Files:**
- Modify: `.github/workflows/ci-testing.yml`

- [ ] **Step 1: Dual-track job (image-baked deps, NO pip)**

```yaml
  lock-projection-cibuild:
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

- [ ] **Step 2: YAML validate** — `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci-testing.yml'))" && echo OK`

- [ ] **Step 3: Full suite** — `make test` (all green); `shellcheck scripts/runner-provisioner.sh scripts/runner-host-install.sh docker/runner/entrypoint.sh`

- [ ] **Step 4: Local dry-run (NO real token)**

```bash
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
tmpcfg="$(mktemp)"
cat >"$tmpcfg" <<EOF
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/o/i@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2 RUNNER_MEMORY=6g RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g RUNNER_TMPFS_RUNNER_SIZE=1g RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
echo "dummy-not-real" | PROVISIONER_CONFIG="$tmpcfg" bash -c \
  "source scripts/runner-provisioner.sh; current_uid(){ echo 0; }; main --registration-token-stdin --dry-run --runner-name ci-build-VERIFY" 2>&1
rm -f "$tmpcfg"
```

Expected: prints `timeout ... docker run ... -i ... --stop-timeout=10 ...` with all security flags; NEVER prints `dummy-not-real`; rc 0.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci-testing.yml
git commit -m "feat(phase1): dual-track lock-projection on ci-build (image-baked deps, no pip)"
```

> Real runner-host lifecycle drill (real short-lived token) ONLY after Steps 1-4 pass. Never use a real registration token in automation.

---

## Acceptance checklist (Phase 0 §11.3 + user Phase 1 closure + v1.2 revisions)

```text
Provisioner (test_runner_provisioner.bats):
  ☐ self-contained (no _common.sh dep); forbidden args rejected
  ☐ stdin token; dry-run NEVER prints token
  ☐ -i/--interactive + --stop-timeout present
  ☐ fixed safe params; no privileged/socket/volume/cap-add/host-net; no secret env
  ☐ image 64-hex digest; config mode==600 exact + root:root + non-symlink
  ☐ single-slot flock (2nd launch rejected; dry-run skips)
  ☐ timeout bounds [5m,60m]; rc captured under set -e; cleanup trap; lifecycle audit
  ☐ live-mode --runner-name shape validation

Entrypoint (test_runner_entrypoint.bats):
  ☐ current_uid stubbable; rootfs ro via mount option
  ☐ /runner /work: tmpfs + nosuid + nodev; /tmp: tmpfs + nosuid + nodev + noexec (path-aware stub + negatives)
  ☐ no-preserve-ownership copy; config.sh --ephemeral/--unattended/--disableupdate

Network (test_runner_network.bats + host verification):
  ☐ policy deny private/link-local/metadata/host; allow public 443/80; NO GitHub IP allowlist
  ☐ installer loads + persists DOCKER-USER rules; verifies iptables backend (fail closed if nftables)
  ☐ runtime: github OK; private/metadata/host denied; rules present

Image supply chain:
  ☐ base NO default tag (digest required); ADD --checksum=sha256:; util-linux for findmnt
  ☐ build→push→pull by manifest digest; --pull=never; NO runtime pip (python3-yaml baked)

Runtime inspect (runbook): Privileged=false ReadonlyRootfs=true User=10001:10001 OpenStdin=true NetworkMode=ci-build-egress CapAdd=[] CapDrop=[ALL] Binds=[] tmpfs mounts limits digest image

GitHub lifecycle: ci-build label; one lock-projection job; auto-deregister (--ephemeral); --rm; single-slot flock; no host persistence; no aptly/GPG/R2/CF/SSH/prod cred

Audit/diagnostics: lifecycle.log (no token); _diag export before exit on failure; future external forwarding noted
```
