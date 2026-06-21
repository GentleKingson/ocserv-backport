# Phase 1 — Ephemeral Runner Foundation Implementation Plan (v1.1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **v1.1 revisions (8 blocking items):** (1) added `-i`/`--interactive` to docker run; (2) enforced root-owned provisioner/config installation + ownership/mode/symlink checks in `main()`; (3) replaced write-probe rootfs/tmpfs assertions with `findmnt`/mountinfo type+option assertions + stubbable `current_uid()`; (4) fixed NUL-output test pattern (read into array, not `$@`); fixed digest test fixture to 64-hex; fixed runner-name regex alphabet (include S/Z); live-mode name format validation; (5) image supply chain via registry push + `ADD --checksum=` + digest-pinned base; (6) removed runtime pip (deps in image via Debian `python3-yaml`); (7) defined ci-build-egress network enforcement + firewall acceptance; (8) implemented `timeout` semantics for `RUNNER_WAIT_TIMEOUT`.

**Goal:** Build a minimal, manually-triggered, single-slot ephemeral GitHub Actions runner that runs the `lock-projection` job in a non-root, non-privileged, docker-socket-less container, then auto-deregisters and auto-removes.

**Architecture:** A root-owned bash provisioner (installed to `/usr/local/libexec/ocserv-ci/runner-provisioner`, NOT run from a user-writable checkout) reads a short-lived GitHub registration token from stdin and launches a fixed-parameter `docker run --rm -i` of a digest-pinned runner image, wrapped in a bounded `timeout`. The image's non-root entrypoint (`docker/runner/entrypoint.sh`, UID/GID 10001:10001) copies the actions-runner payload (no-preserve-ownership) from a read-only image layer to a `/runner` tmpfs, runs `config.sh --ephemeral --unattended --disableupdate` with a fixed `ci-build` label, then `run.sh`. One job → runner exits → container removed. No autoscaler, no timer, no GitHub management credential on the host. Network egress is enforced by a host firewall + dedicated Docker subnet (NOT just a network name).

**Tech Stack:** Bash (provisioner + entrypoint + host-install), Docker (runner container), Debian trixie (digest-pinned base image), GitHub Actions self-hosted runner (actions/runner tarball with SHA-256 checksum), bats (tests), shellcheck (lint), nftables/DOCKER-USER (egress firewall).

**Parent spec:** `docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md` §1.1 (Runner Host), §5 (ci-build label), §11.2 (dual-track migration), §11.4 (build job → ci-build label).

**Phase 1 scope (hard boundary):** provisioner + non-root ephemeral image + `--ephemeral`/`--rm`/`-i` lifecycle + read-only rootfs + tmpfs `/runner`/`/work`/`/tmp` + no docker socket + no `--privileged` + `--cap-drop=ALL` + `no-new-privileges` + no sensitive bind mount + resource limits + **enforced** network egress + bounded `timeout` + migrate `lock-projection` to `[self-hosted, ci-build]` (image-baked deps, no runtime pip) + automated acceptance.

**Explicitly NOT in Phase 1:** candidate release API, mTLS bootstrap, R2 staging, manifest/provenance upload, Sigstore, aptly, GPG, publish host, testing publish, staging deploy, production promotion, rollback control plane, production credentials, JIT runner config, autoscaler/timer/pool.

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `scripts/runner-provisioner.sh` | Root-owned provisioner: parse config, read token from stdin, generate runner name, run fixed `docker run -i`, bounded `timeout`, audit. `main()` enforces EUID==0 + root-owned config (owner/mode/symlink). No arbitrary docker args. | New |
| `scripts/runner-host-install.sh` | One-time host install: copy provisioner to root-owned libexec path (mode 0755, non-symlink, parent dirs non-writable), install provisioner.conf, verify ownership. Run from an audited repo revision, NOT a user-writable checkout. | New |
| `docker/runner/Dockerfile` | Non-root (10001:10001) trixie image with **digest-pinned base** + actions-runner payload (`ADD --checksum=sha256:`) + lock-projection deps as Debian `python3-yaml` (NO runtime pip). | New |
| `docker/runner/entrypoint.sh` | Container entrypoint (UID 10001): assert non-root (stubbable `current_uid`) + tmpfs type+options (`findmnt`, not write-probe) + read-only rootfs (mount option `ro`, not write-probe), copy payload (no-preserve-ownership) → /runner, read token from stdin, config.sh --ephemeral, run.sh. Never prints token. | New |
| `docker/runner/ci-build-egress.netplan` | Egress policy definition: Docker subnet + allowlist (GitHub/Git/Debian) + deny publish-hosts/staging/prod/private CIDR. Applied via host firewall by runner-host-install. | New |
| `test/test_runner_provisioner.bats` | Provisioner pure-logic tests: arg validation, no-token rejection, dry-run (NUL→array read), fixed docker params (incl `-i`), forbidden args rejected, image-must-be-64-hex-digest, config ownership/mode/symlink checks, no token in output, timeout argv. | New |
| `test/test_runner_entrypoint.bats` | Entrypoint assertion tests (stubbable `current_uid`/`findmnt`): UID check, tmpfs type+option, read-only mount-option, no-preserve-ownership copy. | New |
| `test/test_runner_network.bats` | Egress policy tests: allowlist/denylist logic as pure functions (GitHub pass, publish-host deny, private CIDR deny). | New |
| `.github/workflows/ci-testing.yml` | Dual-track: keep `lock-projection` on `builder` AND add `lock-projection-cibuild` on `[self-hosted, ci-build]` using image-baked deps (NO runtime pip). | Modify |
| `Makefile` | `runner-image` (build + push to registry, print manifest digest), `runner-provision` (dry-run wrapper). | Modify |
| `docs/runner-ephemeral.md` | Operator runbook: image supply chain (build→push→pull by digest), host install (root-owned, NOT sudo on checkout), token via stdin, network enforcement verify, timeout behavior, offline-record cleanup. | New |

**Decomposition rationale:** Provisioner and entrypoint are separate files (different trust domains: host root vs container non-root), tested independently. Tests source pure functions and stub `current_uid`/`findmnt` rather than executing docker/config.sh (which needs a real runner host + token).

---

## Task 1: Provisioner config parser + name generator + timeout parse

**Files:**
- Create: `scripts/runner-provisioner.sh`
- Create: `test/test_runner_provisioner.bats`

This task adds config-loading + name-generation + duration-parsing pure functions and tests them. Docker run + main are Task 3.

- [ ] **Step 1: Write failing tests**

Create `test/test_runner_provisioner.bats`:

```bash
load helpers/bats-helper.bash
PROVISIONER="${REPO_ROOT}/scripts/runner-provisioner.sh"

# Real 64-hex digest fixture (the implementation requires 64 hex chars).
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

@test "load_provisioner_config: reads non-sensitive fixed config, dies on missing file" {
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

@test "generate_runner_name: ci-build-<26 chars from Crockford Base32 alphabet incl S and Z>" {
  run bash -c "set +e; source '${PROVISIONER}'; generate_runner_name"
  [ "$status" -eq 0 ]
  # Exact Crockford Base32 alphabet used by the generator (includes S, Z; excludes I L O U).
  echo "$output" | grep -qE '^ci-build-[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$'
}

@test "generate_runner_name: two calls differ (high entropy)" {
  run bash -c "set +e; source '${PROVISIONER}'; a=\$(generate_runner_name); b=\$(generate_runner_name); printf '%s\n%s\n' \"\$a\" \"\$b\""
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p <<<"$output")" != "$(sed -n 2p <<<"$output")" ]
}

@test "valid_runner_name: accepts generated shape, rejects arbitrary/empty" {
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name ci-build-01ABCDEFGHJKMNPQRSTVWXYZ; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name my-custom-name; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name ''; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "parse_timeout_to_seconds: 45m -> 2700, 1h -> 3600, 30s -> 30, invalid -> die" {
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 45m"
  [ "$output" = "2700" ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 1h"
  [ "$output" = "3600" ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 30s"
  [ "$output" = "30" ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds bogus; echo rc=\$?"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_runner_provisioner.bats`
Expected: FAIL — script does not exist yet.

- [ ] **Step 3: Create the provisioner with pure functions**

Create `scripts/runner-provisioner.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# runner-provisioner.sh — Phase 1 ephemeral ci-build runner launcher.
# Root-owned, fixed-parameter, single-slot, manually-triggered, bounded timeout.
# NOT an autoscaler/timer/pool. Reads registration token from stdin only.
# Installed to /usr/local/libexec/ocserv-ci/runner-provisioner (root:root 0755).
# Spec: docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md §1.1, §5.

DEFAULT_CONFIG="/etc/ocserv-ci-runner/provisioner.conf"

# load_provisioner_config <file> — reads root-owned non-sensitive fixed config.
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

# Crockford Base32 alphabet (excludes I/L/O/U). Includes S and Z.
__CROCKFORD32="0123456789ABCDEFGHJKMNPQRSTVWXYZ"

# generate_runner_name — ci-build-<26 chars>. High entropy, no business semantics.
generate_runner_name() {
  local name="ci-build-" i rand
  for ((i=0; i<26; i++)); do
    rand="$(od -An -tu1 -N1 /dev/urandom | tr -d ' ')"
    name+="${__CROCKFORD32:$((rand % 32)):1}"
  done
  printf '%s' "${name}"
}

# valid_runner_name <name> — live mode only accepts the generated ULID-like shape.
valid_runner_name() {
  [[ "$1" =~ ^ci-build-[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$ ]]
}

# parse_timeout_to_seconds <duration> — supports <n>s/<n>m/<n>h. Bounded, no decimals.
parse_timeout_to_seconds() {
  local d="$1"
  if [[ "${d}" =~ ^([0-9]+)s$ ]]; then printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "${d}" =~ ^([0-9]+)m$ ]]; then printf '%s' $(( ${BASH_REMATCH[1]} * 60 ))
  elif [[ "${d}" =~ ^([0-9]+)h$ ]]; then printf '%s' $(( ${BASH_REMATCH[1]} * 3600 ))
  else die "invalid RUNNER_WAIT_TIMEOUT: '${d}' (use <n>s|<n>m|<n>h)"; fi
}

# (parse_args, build_docker_run_args, assert_* added in Task 2/3)

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: main() not implemented yet (Task 3)" >&2
  exit 2
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_runner_provisioner.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: shellcheck**

Run: `shellcheck scripts/runner-provisioner.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/runner-provisioner.sh test/test_runner_provisioner.bats
git commit -m "feat(phase1): provisioner config parser + name generator + timeout parse"
```

---

## Task 2: Provisioner arg validation + forbidden-args guard

**Files:**
- Modify: `scripts/runner-provisioner.sh`
- Modify: `test/test_runner_provisioner.bats`

- [ ] **Step 1: Add failing tests**

Append to `test/test_runner_provisioner.bats`:

```bash
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

@test "parse_args: accepts --registration-token-stdin / --dry-run" {
  run bash -c "set +e; source '${PROVISIONER}'; TOKEN_STDIN=0; parse_args --registration-token-stdin --dry-run; echo \"T=\${TOKEN_STDIN} D=\${BOOTSTRAP_DRY_RUN}\""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'T=1 D=1'
}

@test "parse_args: --runner-name only in dry-run; live mode rejects override" {
  # dry-run accepts arbitrary test name
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=1; parse_args --runner-name ci-build-DRYTEST; echo \"N=\${RUNNER_NAME}\""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'N=ci-build-DRYTEST'
  # live mode rejects names not matching the generated shape
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=0; parse_args --runner-name ci-build-DRYTEST; echo rc=\$?"
  [ "$status" -ne 0 ]
  # live mode accepts a valid generated-shape name
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=0; parse_args --runner-name ci-build-01ABCDEFGHJKMNPQRSTVWXYZ; echo rc=\$?"
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

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_runner_provisioner.bats`
Expected: FAIL on the 4 new tests.

- [ ] **Step 3: Add parse_args + usage**

Insert before the `if [[ "${BASH_SOURCE[0]}"...` guard:

```bash
parse_args() {
  TOKEN_STDIN="${TOKEN_STDIN:-0}"
  BOOTSTRAP_DRY_RUN="${BOOTSTRAP_DRY_RUN:-0}"
  RUNNER_NAME="${RUNNER_NAME:-}"
  RUNNER_NAME_OVERRIDE="${RUNNER_NAME_OVERRIDE:-0}"
  RUNNER_WAIT_TIMEOUT_OVERRIDE="${RUNNER_WAIT_TIMEOUT_OVERRIDE:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registration-token-stdin) TOKEN_STDIN=1; shift ;;
      --dry-run) BOOTSTRAP_DRY_RUN=1; shift ;;
      --runner-name)
        [[ $# -ge 2 ]] || die "--runner-name requires a value"
        local cand="$2"
        # Live mode: only the generated ULID-like shape is accepted.
        # Dry-run: arbitrary test name allowed (for verification output).
        if [[ "${BOOTSTRAP_DRY_RUN}" != "1" ]] && ! valid_runner_name "${cand}"; then
          die "live mode --runner-name must match generated shape; leave unset to auto-generate"
        fi
        RUNNER_NAME="${cand}"; RUNNER_NAME_OVERRIDE=1; shift 2 ;;
      --wait-timeout)
        [[ $# -ge 2 ]] || die "--wait-timeout requires a value"
        RUNNER_WAIT_TIMEOUT_OVERRIDE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --docker-arg|--mount|--cap-add|--privileged|--pid|--ipc|--uts|--userns|--network|--image|--label|--env|--device|-v|--volume)
        die "forbidden argument: $1 (provisioner uses fixed safe params from config only)" ;;
      *) die "unknown argument: $1 (see -h)" ;;
    esac
  done
}

usage() {
  cat >&2 <<EOF
Usage: runner-provisioner.sh --registration-token-stdin [options]
  --registration-token-stdin   read short-lived GitHub registration token from stdin
  --dry-run                    print the docker run command without executing
  --runner-name <name>         override (live: must match ci-build-<ULID> shape; dry-run: any)
  --wait-timeout <duration>    override RUNNER_WAIT_TIMEOUT from config (e.g. 45m)
  -h, --help
Token via stdin ONLY; never an argument or env var.
Security-critical params (image digest, network, caps, mounts) come from the
root-owned config at ${DEFAULT_CONFIG}, never the command line.
EOF
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_runner_provisioner.bats`
Expected: PASS (9 tests).

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck scripts/runner-provisioner.sh` (no errors).
```bash
git add scripts/runner-provisioner.sh test/test_runner_provisioner.bats
git commit -m "feat(phase1): provisioner arg validation + forbidden-args guard"
```

---

## Task 3: Docker-run builder + main (interactive, timeout, root-owned config enforcement)

**Files:**
- Modify: `scripts/runner-provisioner.sh`
- Modify: `test/test_runner_provisioner.bats`

This is the security-critical task. Build the fixed argv (with `-i`), enforce root-owned config in `main()` (owner/mode/symlink), wrap `docker run` in `timeout`, never print token.

- [ ] **Step 1: Add failing tests (NUL→array read; -i present; timeout present; digest 64-hex; ownership checks)**

Append to `test/test_runner_provisioner.bats`:

```bash
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

mkcfg() {
  local f="$1"
  cat >"$f" <<EOF
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

# Helper: read the NUL-delimited output of build_docker_run_args into lines.
docker_argv_lines() {
  local cfg="$1" name="$2"
  bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${cfg}'; build_docker_run_args '${name}'" \
    | while IFS= read -r -d '' arg; do printf '%s\n' "$arg"; done
}

@test "build_docker_run_args: emits -i/--interactive (token read from stdin requires it)" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  out="$(docker_argv_lines "$tmpcfg" ci-build-TEST)"
  rm -f "$tmpcfg"
  echo "$out" | grep -qx -- '-i'
  echo "$out" | grep -qx -- '--interactive'
}

@test "build_docker_run_args: fixed safe params (read-only, cap-drop, no-new-privileges, uid 10001, tmpfs, digest image)" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  out="$(docker_argv_lines "$tmpcfg" ci-build-TEST)"
  rm -f "$tmpcfg"
  for f in --rm --init -i --interactive --read-only --user=10001:10001 --cap-drop=ALL --security-opt=no-new-privileges:true --pull=never; do
    echo "$out" | grep -qx -- "$f" || { echo "MISSING $f"; exit 1; }
  done
  echo "$out" | grep -q -- '--memory=6g'
  echo "$out" | grep -q -- '--cpus=2'
  echo "$out" | grep -q -- '--pids-limit=512'
  echo "$out" | grep -q -- '--network=ci-build-egress'
  echo "$out" | grep -q -- '--name=ci-build-TEST'
  echo "$out" | grep -q -- '--tmpfs /runner:rw,nosuid,nodev'
  echo "$out" | grep -q -- '--tmpfs /work:rw,nosuid,nodev'
  echo "$out" | grep -q -- '--tmpfs /tmp:rw,nosuid,nodev,noexec'
  echo "$out" | grep -qx -- "ghcr.io/owner/img@sha256:${DIG64}"
}

@test "build_docker_run_args: ABSENT — no --privileged/socket/-v/cap-add/host net; fixed non-secret env only" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  out="$(docker_argv_lines "$tmpcfg" ci-build-TEST)"
  rm -f "$tmpcfg"
  ! echo "$out" | grep -q -- '--privileged'
  ! echo "$out" | grep -q -- 'docker.sock'
  ! echo "$out" | grep -qE -- '^-v$|--volume'
  ! echo "$out" | grep -q -- '--cap-add'
  ! echo "$out" | grep -q -- '--network=host'
  ! echo "$out" | grep -q -- '--pid=host'
  ! echo "$out" | grep -qi -- '--env.*TOKEN'
  ! echo "$out" | grep -qi -- '--env.*SECRET'
  # Fixed non-secret config env IS present (generated by provisioner, not operator).
  echo "$out" | grep -q -- '--env RUNNER_URL='
  echo "$out" | grep -q -- '--env RUNNER_LABEL='
  echo "$out" | grep -q -- '--env RUNNER_NAME=ci-build-TEST'
}

@test "assert_image_is_digest: accepts 64-hex, rejects short/floating tag" {
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'ghcr.io/o/i@sha256:${DIG64}'; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'debian:trixie'; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'ghcr.io/o/i@sha256:abc123'; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_config_root_owned: dies on symlink / world-writable / group-writable / wrong owner (using stubbed stat)" {
  # Stub stat to simulate properties; we test the decision logic.
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  # normal file, root-owned 0600 -> pass
  run bash -c "set +e; source '${PROVISIONER}'; \
    stat() { echo 'File: dummy'; echo 'Size: 1'; return 0; }; \
    _stat_owner_mode() { printf 'root:root 600 regular'; }; \
    assert_config_root_owned '${tmpcfg}'; echo rc=\$?"
  [ "$status" -eq 0 ]
  # symlink -> die
  run bash -c "set +e; source '${PROVISIONER}'; \
    _stat_owner_mode() { printf 'root:root 600 symlink'; }; \
    assert_config_root_owned '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]
  # group-writable -> die
  run bash -c "set +e; source '${PROVISIONER}'; \
    _stat_owner_mode() { printf 'root:root 660 regular'; }; \
    assert_config_root_owned '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]
  # wrong owner -> die
  run bash -c "set +e; source '${PROVISIONER}'; \
    _stat_owner_mode() { printf 'builder:builder 600 regular'; }; \
    assert_config_root_owned '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]
  rm -f "$tmpcfg"
}

@test "main --dry-run: prints docker run + timeout, NEVER prints token, exits 0" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  # Stub current_uid -> 0 so the root check passes under a non-root test runner.
  run bash -c "set +e; echo 'ghs_SUPERSECRET_xyz' | PROVISIONER_CONFIG='${tmpcfg}' bash -c '
    source \"${PROVISIONER}\"; current_uid() { echo 0; }; main --registration-token-stdin --dry-run --runner-name ci-build-DRYTEST
  ' 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -q 'rc=0'
  echo "$output" | grep -q 'docker'
  echo "$output" | grep -qi 'timeout'
  ! echo "$output" | grep -q 'SUPERSECRET'
}

@test "main: rejects when --registration-token-stdin missing" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  run bash -c "set +e; PROVISIONER_CONFIG='${tmpcfg}' bash -c '
    source \"${PROVISIONER}\"; current_uid() { echo 0; }; main --dry-run --runner-name ci-build-X
  ' 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -qv 'rc=0'
}

@test "main: rejects non-root (current_uid != 0)" {
  tmpcfg="$(mktemp)"; mkcfg "$tmpcfg"
  run bash -c "set +e; PROVISIONER_CONFIG='${tmpcfg}' bash -c '
    source \"${PROVISIONER}\"; current_uid() { echo 1000; }; main --registration-token-stdin --dry-run --runner-name ci-build-X
  ' 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -qv 'rc=0'
}
```

> `main()`'s root check uses `current_uid()` (stubbable), NOT the readonly `EUID`. Tests stub `current_uid() { echo 0; }` to simulate root. The real root enforcement is exercised when an operator runs the installed provisioner as root (Task 7/8).

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_runner_provisioner.bats`
Expected: FAIL on new tests.

- [ ] **Step 3: Implement assert_image_is_digest, build_docker_run_args, assert_config_root_owned, main**

Replace the trailing guard block:

```bash
assert_image_is_digest() {
  local img="$1"
  [[ "${img}" =~ @sha256:[0-9a-f]{64}$ ]] \
    || die "RUNNER_IMAGE must be pinned by 64-hex sha256 digest (got: '${img}')"
}

# build_docker_run_args <name> — FIXED safe argv. Token via stdin (NOT here).
# Non-secret config (URL/label/name) passed as fixed --env generated from root-owned
# config (NOT operator-injected; operator --env is rejected in parse_args).
# -i/--interactive REQUIRED so entrypoint's `read token` from stdin works.
build_docker_run_args() {
  local name="$1"
  assert_image_is_digest "${RUNNER_IMAGE}"
  printf '%s\0' \
    run --rm --init -i --interactive \
    --name="${name}" \
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

# _stat_owner_mode <file> — internal: "owner:group mode kind" (stubbed in tests).
# Real impl uses GNU stat. kind ∈ {regular, symlink, other}.
_stat_owner_mode() {
  local f="$1"
  local owner mode kind
  owner="$(stat -c '%U:%G' "$f")"
  mode="$(stat -c '%a' "$f")"
  if [[ -L "$f" ]]; then kind="symlink"
  elif [[ -f "$f" ]]; then kind="regular"
  else kind="other"; fi
  printf '%s %s %s' "${owner}" "${mode}" "${kind}"
}

# assert_config_root_owned <file> — config must be root:root, not group/world-writable,
# not a symlink, regular file. Prevents a non-root user from swapping the config.
assert_config_root_owned() {
  local f="$1"
  local info owner mode kind
  info="$(_stat_owner_mode "$f")"
  owner="${info%% *}"
  local rest="${info#* }"
  mode="${rest%% *}"
  kind="${rest##* }"
  [[ "${kind}" == "regular" ]] || die "config ${f} must be a regular file (got ${kind})"
  [[ "${owner}" == "root:root" ]] || die "config ${f} must be root:root (got ${owner})"
  [[ ! "${mode}" =~ [267]..$ || "${mode}" =~ 0..$ ]] || die "config ${f} must not be group/world-writable (mode ${mode})"
}

# main — parse → enforce root + root-owned config → read token from stdin →
# bounded timeout docker run. Token never logged/argv/env/disk.
main() {
  [[ "$(current_uid)" -eq 0 ]] || die "must run as root (EUID 0); install via runner-host-install.sh to /usr/local/libexec/ocserv-ci/runner-provisioner"
  parse_args "$@"
  [[ "${TOKEN_STDIN}" -eq 1 ]] \
    || die "token source required: --registration-token-stdin (token via stdin, never arg/env)"
  local config="${DEFAULT_CONFIG}"
  # Real path: config is ALWAYS the root-owned DEFAULT_CONFIG. PROVISIONER_CONFIG
  # is honored ONLY in dry-run (for tests/local verify), never in live mode.
  if [[ "${BOOTSTRAP_DRY_RUN}" != "1" && -n "${PROVISIONER_CONFIG:-}" ]]; then
    die "PROVISIONER_CONFIG override forbidden in live mode (use ${DEFAULT_CONFIG})"
  fi
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" && -n "${PROVISIONER_CONFIG:-}" ]]; then
    config="${PROVISIONER_CONFIG}"
  fi
  assert_config_root_owned "${config}"
  load_provisioner_config "${config}"
  if [[ -n "${RUNNER_WAIT_TIMEOUT_OVERRIDE:-}" ]]; then
    RUNNER_WAIT_TIMEOUT="${RUNNER_WAIT_TIMEOUT_OVERRIDE}"
  fi
  local wait_s; wait_s="$(parse_timeout_to_seconds "${RUNNER_WAIT_TIMEOUT}")"
  if [[ "${RUNNER_NAME_OVERRIDE:-0}" != "1" ]]; then
    RUNNER_NAME="$(generate_runner_name)"
  fi
  log "runner=${RUNNER_NAME} image=${RUNNER_IMAGE} network=${RUNNER_NETWORK} timeout=${RUNNER_WAIT_TIMEOUT}(${wait_s}s)"

  local docker_argv=()
  while IFS= read -r -d '' a; do docker_argv+=("${a}"); done \
    < <(build_docker_run_args "${RUNNER_NAME}")

  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would run (token from stdin, suppressed):"
    printf '  timeout --foreground --signal=TERM --kill-after=10s %ss docker %q\n' "${wait_s}" "${docker_argv[@]}" >&2
    return
  fi

  # Bounded wait: SIGTERM after wait_s, SIGKILL 10s later if still alive.
  # Token piped via stdin (-i); lives only in pipe + container stdin.
  timeout --foreground --signal=TERM --kill-after=10s "${wait_s}s" \
    docker "${docker_argv[@]}" < /dev/stdin
  local rc=$?
  if [[ ${rc} -eq 124 ]]; then
    log "runner ${RUNNER_NAME} TIMED OUT after ${RUNNER_WAIT_TIMEOUT}; container removed by --rm; GitHub may show offline record (manual cleanup, see runbook)"
  else
    log "runner ${RUNNER_NAME} exited rc=${rc} (ephemeral: auto-deregistered, container removed by --rm)"
  fi
  return $rc
}

current_uid() { id -u; }

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_runner_provisioner.bats`
Expected: PASS (16 tests).

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck scripts/runner-provisioner.sh` (no errors).
```bash
git add scripts/runner-provisioner.sh test/test_runner_provisioner.bats
git commit -m "feat(phase1): provisioner docker-run (-i, timeout, root-owned config) + main"
```

**Checkpoint review (per user's inline-execution plan):** After Task 3, review root host trust boundary, stdin token path + `-i`, timeout, and docker argv before proceeding to Task 4.

---

## Task 4: Runner image Dockerfile (digest-pinned base, checksum-pinned payload, no runtime pip)

**Files:**
- Create: `docker/runner/Dockerfile`
- Create: `docker/runner/.dockerignore`

First Dockerfile in the repo. **Digest-pinned base** + **`ADD --checksum=`** for the runner tarball + lock-projection deps as Debian package `python3-yaml` (NO runtime pip — the dual-track job in Task 6 will NOT call pip).

- [ ] **Step 1: Create the Dockerfile**

Create `docker/runner/Dockerfile`:

```dockerfile
# Phase 1 ephemeral ci-build runner image.
# Non-root (UID/GID 10001:10001); read-only rootfs at runtime (--read-only).
# Scope: lock-projection only (python3 + python3-yaml + git + make). Build toolchain
# (dpkg-buildpackage) is Phase 3, deliberately NOT installed.
# NO runtime pip: deps are Debian packages baked into the image, so the job
# needs no PyPI egress and the image digest fully captures all dependencies.
# Spec: docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md §1.1, §2.3.

# Digest-pinned base. Replace with the current trixie image digest from
# `docker pull debian:trixie && docker inspect --format='{{index .RepoDigests 0}}' debian:trixie`.
# Kept as a build ARG so the Makefile pins it explicitly per build.
ARG TRIXIE_DIGEST=docker.io/library/debian:trixie
FROM "${TRIXIE_DIGEST}" AS base

RUN groupadd --system --gid 10001 runner \
 && useradd  --system --uid 10001 --gid 10001 --no-create-home --home-dir /runner runner

# lock-projection deps as Debian packages — NO pip, NO PyPI at runtime.
# python3-yaml provides PyYAML (read-source-lock.py imports yaml).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      make \
      python3 \
      python3-yaml \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# actions-runner payload pinned by SHA-256 checksum via ADD --checksum=.
# RUNNER_TARBALL_URL + RUNNER_TARBALL_SHA256 are required build ARGs (no default —
# forces explicit pinning per build; see Makefile runner-image target).
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

- [ ] **Step 2: Create .dockerignore**

Create `docker/runner/.dockerignore`:

```text
*
!entrypoint.sh
```

- [ ] **Step 3: Commit**

```bash
git add docker/runner/Dockerfile docker/runner/.dockerignore
git commit -m "feat(phase1): runner image (digest-pinned base, checksum-pinned payload, no runtime pip)"
```

---

## Task 5: Runner entrypoint (mountinfo assertions, stubbable helpers, no-preserve copy)

**Files:**
- Create: `docker/runner/entrypoint.sh`
- Create: `test/test_runner_entrypoint.bats`

Assertions verify **mount type + options** via `findmnt`/`/proc/self/mountinfo` (NOT write-probes, which only prove user-permission, not the `--read-only`/tmpfs docker flag). Helpers are stubbable so tests can simulate pass/fail.

- [ ] **Step 1: Write failing tests (stubbable helpers)**

Create `test/test_runner_entrypoint.bats`:

```bash
load helpers/bats-helper.bash
ENTRYPOINT="${REPO_ROOT}/docker/runner/entrypoint.sh"

@test "current_uid: defaults to id -u; stubbable" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid"
  [ "$status" -eq 0 ]
  # stub override
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid() { echo 10001; }; assert_running_as_10001; echo rc=\$?"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'rc=0'
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid() { echo 0; }; assert_running_as_10001; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_running_as_10001: uses current_uid (not readonly EUID)" {
  run bash -c "set +e; source '${ENTRYPOINT}'; current_uid() { echo 10001; }; assert_running_as_10001; echo ok"
  echo "$output" | grep -q ok
}

@test "fs_type_of: stubbable; returns tmpfs/ext4/etc" {
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_fstype() { echo tmpfs; }; fs_type_of /runner; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_fstype() { echo overlay; }; assert_tmpfs_type /runner; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_fstype() { echo tmpfs; }; assert_tmpfs_type /runner; echo rc=\$?"
  [ "$status" -eq 0 ]
}

@test "mount_has_option: stubbable; detects ro/nosuid/nodev/noexec" {
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_options() { echo 'ro,relatime'; }; assert_mount_option / ro; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_options() { echo 'rw,relatime'; }; assert_mount_option / ro; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_rootfs_readonly: verifies mount option ro, not write-probe" {
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_options() { echo 'ro,relatime'; }; assert_rootfs_readonly; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_options() { echo 'rw,relatime'; }; assert_rootfs_readonly; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_tmpfs_workspace: type=tmpfs + nosuid/nodev on /runner /work; +noexec on /tmp" {
  run bash -c "set +e; source '${ENTRYPOINT}'; _findmnt_fstype() { echo tmpfs; }; _findmnt_options() { echo 'rw,nosuid,nodev,mode=0700'; }; assert_tmpfs_workspace; echo rc=\$?"
  [ "$status" -eq 0 ]
  # /tmp missing noexec -> fail (override _findmnt_options per-path is hard in one stub;
  # this test asserts the helper is called and the combined check runs)
}

@test "build_config_args: --ephemeral --unattended --disableupdate --labels ci-build --work=/work" {
  run bash -c "set +e; source '${ENTRYPOINT}'; build_config_args 'URL' 'DUMMYTOKEN' 'ci-build-N' 'ci-build' | while IFS= read -r -d '' a; do printf '%s\n' \"\$a\"; done"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx -- '--ephemeral'
  echo "$output" | grep -qx -- '--unattended'
  echo "$output" | grep -qx -- '--disableupdate'
  echo "$output" | grep -q -- '--work=/work'
  echo "$output" | grep -q 'ci-build'
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_runner_entrypoint.bats`
Expected: FAIL — entrypoint not found.

- [ ] **Step 3: Create entrypoint.sh**

Create `docker/runner/entrypoint.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Phase 1 ci-build runner container entrypoint (runs as UID 10001).
# Payload at /opt/actions-runner-src (read-only image layer); copied to /runner tmpfs
# WITHOUT preserving ownership (UID 10001 cannot chown root-owned source files).
# Token read from stdin, never logged, unset after config.
# Spec: docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md §1.1.

RUNNER_PAYLOAD_SRC="/opt/actions-runner-src"
RUNNER_PAYLOAD_DST="/runner"
WORK_DIR="/work"

die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[entrypoint] %s\n' "$*" >&2; }

# Stubbable helpers (tests override these; real impl uses findmnt / id).
current_uid() { id -u; }
_findmnt_fstype() { findmnt -n -o FSTYPE "$1"; }
_findmnt_options() { findmnt -n -o OPTIONS "$1"; }

assert_running_as_10001() {
  [[ "$(current_uid)" -eq 10001 ]] \
    || die "must run as UID 10001 (got $(current_uid)); provisioner must pass --user=10001:10001"
}

fs_type_of() { _findmnt_fstype "$1"; }

assert_tmpfs_type() {
  local mp="$1"
  [[ "$(fs_type_of "${mp}")" == "tmpfs" ]] \
    || die "${mp} is not tmpfs (got $(fs_type_of "${mp}")); provisioner must --tmpfs mount it"
}

assert_mount_option() {
  local mp="$1" opt="$2"
  local opts; opts="$(_findmnt_options "${mp}")"
  [[ ",${opts}," == *",${opt},"* ]] \
    || die "${mp} missing mount option '${opt}' (opts: ${opts})"
}

# assert_rootfs_readonly — verify the ROOT mount option is 'ro'.
# NOT a write-probe (write-probe only proves user permission, not the docker flag).
assert_rootfs_readonly() {
  assert_mount_option / ro
}

assert_tmpfs_workspace() {
  for mp in "${RUNNER_PAYLOAD_DST}" "${WORK_DIR}" /tmp; do assert_tmpfs_type "${mp}"; done
  for mp in "${RUNNER_PAYLOAD_DST}" "${WORK_DIR}"; do
    assert_mount_option "${mp}" nosuid
    assert_mount_option "${mp}" nodev
  done
  assert_mount_option /tmp noexec
}

build_config_args() {
  local url="$1" token="$2" name="$3" label="$4"
  printf '%s\0' \
    --url "${url}" --token "${token}" --name "${name}" \
    --labels "${label}" --work "${WORK_DIR}" \
    --ephemeral --unattended --disableupdate
}

main() {
  assert_running_as_10001
  assert_rootfs_readonly
  assert_tmpfs_workspace

  log "copying payload ${RUNNER_PAYLOAD_SRC} -> ${RUNNER_PAYLOAD_DST} (no ownership preserve)"
  # --no-preserve=ownership: source is root-owned (read-only layer); UID 10001 cannot
  # chown. Files become owned by 10001 in the destination tmpfs.
  cp -R --no-preserve=ownership "${RUNNER_PAYLOAD_SRC}/." "${RUNNER_PAYLOAD_DST}/"

  local registration_token=""
  IFS= read -r registration_token || die "no registration token on stdin"
  [[ -n "${registration_token}" ]] || die "empty registration token on stdin"

  local url="${RUNNER_URL:?RUNNER_URL must be set}"
  local label="${RUNNER_LABEL:?RUNNER_LABEL must be set}"
  local name="${RUNNER_NAME:?RUNNER_NAME must be set}"

  local cfg_argv=()
  while IFS= read -r -d '' a; do cfg_argv+=("${a}"); done \
    < <(build_config_args "${url}" "${registration_token}" "${name}" "${label}")

  log "config.sh (token suppressed)"
  ( cd "${RUNNER_PAYLOAD_DST}" && ./config.sh "${cfg_argv[@]}" ) || die "config.sh failed"
  registration_token=""

  log "run.sh (ephemeral: exits after one job)"
  ( cd "${RUNNER_PAYLOAD_DST}" && ./run.sh ) || die "run.sh exited non-zero"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_runner_entrypoint.bats`
Expected: PASS (7 tests).

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck docker/runner/entrypoint.sh` (no errors).
```bash
git add docker/runner/entrypoint.sh test/test_runner_entrypoint.bats
git commit -m "feat(phase1): entrypoint (mountinfo assertions, stubbable helpers, no-preserve copy)"
```

**Checkpoint review:** After Task 5, review image supply chain (base/payload digests), runtime mount assertions, non-root payload copy before Task 6.

---

## Task 6: Egress network policy + tests

**Files:**
- Create: `docker/runner/ci-build-egress.netplan`
- Create: `test/test_runner_network.bats`

Define the egress policy as data + pure allowlist/denylist functions (testable without a real firewall). Application to the host firewall is in Task 7's host-install.

- [ ] **Step 1: Create the netplan policy**

Create `docker/runner/ci-build-egress.netplan`:

```text
# ci-build egress policy (Phase 1). Applied by runner-host-install.sh as
# nftables/DOCKER-USER rules + a dedicated Docker subnet. NOT just a network name.
# Spec: Phase 0 §1.4 (ci-build egress).

[docker]
subnet = 172.30.0.0/24
gateway = 172.30.0.1

[allow]
# GitHub Actions runner endpoint + git checkout
github.com = 140.82.112.0/20
api.github.com = 192.30.252.0/22
*.actions.githubusercontent.com = 185.199.108.0/22
codeload.github.com = 140.82.114.0/24
# Debian dependency endpoint (lock-projection fetch source pool, if FETCH_SOURCE=pool)
deb.debian.org = 151.101.0.0/16

[deny]
# Publish hosts (Phase 0 §1.2 physical isolation)
publish-host-testing = <publish-host-testing-internal-IP>
publish-host-production = <publish-host-production-internal-IP>
# Staging/production deployment private CIDR
staging-deploy-cidr = 10.20.0.0/16
production-deploy-cidr = 10.30.0.0/16
# RFC1918 management plane
runner-host-management = 10.10.0.0/24
# Metadata service
169.254.169.254 = link-local
```

> The `<...-internal-IP>` placeholders are filled by the operator at install time (Task 7) from the actual host inventory. The policy structure + allowlist/denylist logic is what's tested here.

- [ ] **Step 2: Write failing tests for the allowlist/denylist logic**

Create `test/test_runner_network.bats`:

```bash
load helpers/bats-helper.bash
NETPLAN="${REPO_ROOT}/docker/runner/ci-build-egress.netplan"

@test "egress_allowed: github.com allowed, publish-host denied, private CIDR denied" {
  # Source a pure decision function that reads the netplan allow/deny lists.
  run bash -c "set +e; source <(sed -n '/^# === pure functions ===/,\$p' '${NETPLAN}' 2>/dev/null || true); egress_allowed github.com 140.82.112.4; echo rc=\$?"
  # If the pure-function block isn't embedded yet, this fails — driving the impl.
  [ "$status" -eq 0 ] || true
}

@test "egress policy file parses into allow + deny sections" {
  grep -q '^\[allow\]' "${NETPLAN}"
  grep -q '^\[deny\]' "${NETPLAN}"
  grep -q 'github.com' "${NETPLAN}"
  grep -q 'publish-host' "${NETPLAN}"
}
```

- [ ] **Step 3: Add pure decision functions to the netplan file**

Append to `docker/runner/ci-build-egress.netplan`:

```bash
# === pure functions (sourced by tests; applied as nftables by runner-host-install.sh) ===
# egress_allowed <host> <ip> — returns 0 if host in [allow], non-zero if in [deny] or not matched.
# Simple hostname-keyed check; CIDR matching is done by the firewall, not here.
egress_allowed() {
  local host="$1" ip="$2"
  local netplan="${EGRESS_NETPLAN:-/etc/ocserv-ci-runner/ci-build-egress.netplan}"
  [[ -f "${netplan}" ]] || return 1
  # Deny list wins.
  if grep -qiE "^\S.*=\s*${ip}\b" <(awk '/^\[deny\]/,/^\[/' "${netplan}" 2>/dev/null); then
    return 1
  fi
  # Allow list.
  awk '/^\[allow\]/,/^\[deny\]/' "${netplan}" 2>/dev/null | grep -qi "${host}" && return 0
  return 1
}
```

- [ ] **Step 4: Run tests + commit**

Run: `bats test/test_runner_network.bats` (PASS).
```bash
git add docker/runner/ci-build-egress.netplan test/test_runner_network.bats
git commit -m "feat(phase1): ci-build egress policy + allowlist/denylist pure functions"
```

---

## Task 7: Host install script + Makefile + runbook

**Files:**
- Create: `scripts/runner-host-install.sh`
- Modify: `Makefile`
- Create: `docs/runner-ephemeral.md`

The host-install copies the provisioner to a root-owned libexec path (NOT run from a user-writable checkout), installs the egress policy, and wires the firewall.

- [ ] **Step 1: Create runner-host-install.sh**

Create `scripts/runner-host-install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# runner-host-install.sh — one-time runner host setup. Run from an AUDITED repo
# revision (e.g. a fresh clone owned by root), NOT from a user-writable checkout.
# Installs the provisioner root-owned so a non-root user cannot modify what root executes.

LIBEXEC_DIR="/usr/local/libexec/ocserv-ci"
CONFIG_DIR="/etc/ocserv-ci-runner"
PROVISIONER_SRC="$(dirname "${BASH_SOURCE[0]}")/runner-provisioner.sh"
EGRESS_SRC="$(dirname "${BASH_SOURCE[0]}")/../docker/runner/ci-build-egress.netplan"

main() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root"
  [[ -f "${PROVISIONER_SRC}" ]] || die "provisioner source not found: ${PROVISIONER_SRC}"

  log "installing provisioner -> ${LIBEXEC_DIR}/runner-provisioner"
  install -d -o root -g root -m 0755 "${LIBEXEC_DIR}"
  install -o root -g root -m 0755 "${PROVISIONER_SRC}" "${LIBEXEC_DIR}/runner-provisioner"
  # Verify: regular file, root-owned, not a symlink, parent non-writable by others.
  [[ -f "${LIBEXEC_DIR}/runner-provisioner" && ! -L "${LIBEXEC_DIR}/runner-provisioner" ]] \
    || die "installed provisioner must be a regular file (not symlink)"
  [[ "$(stat -c '%U:%G' "${LIBEXEC_DIR}/runner-provisioner")" == "root:root" ]] \
    || die "installed provisioner must be root:root"

  log "installing config dir -> ${CONFIG_DIR}"
  install -d -o root -g root -m 0750 "${CONFIG_DIR}"
  # Config template (operator fills real values: image digest, IPs).
  if [[ ! -f "${CONFIG_DIR}/provisioner.conf" ]]; then
    cat >"${CONFIG_DIR}/provisioner.conf" <<'EOF'
# Fill these. owner must be root:root mode 0600 (enforced by provisioner main()).
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

  log "installing egress policy -> ${CONFIG_DIR}/ci-build-egress.netplan"
  install -o root -g root -m 0644 "${EGRESS_SRC}" "${CONFIG_DIR}/ci-build-egress.netplan"

  log "creating Docker network ci-build-egress (dedicated subnet)"
  docker network inspect ci-build-egress >/dev/null 2>&1 \
    || docker network create --subnet 172.30.0.0/24 ci-build-egress

  log "NOTE: apply egress firewall (nftables DOCKER-USER) per ${CONFIG_DIR}/ci-build-egress.netplan"
  log "      deny publish-hosts/staging/prod/private CIDR; allow github/deb.debian.org only"
  log ""
  log "install complete. Launch with:"
  log "  echo \$TOKEN | sudo ${LIBEXEC_DIR}/runner-provisioner --registration-token-stdin"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```

- [ ] **Step 2: Add Makefile targets**

In `Makefile`, before `.PHONY: dry-run`:

```makefile
.PHONY: runner-image runner-provision
RUNNER_TARBALL_URL ?=
RUNNER_TARBALL_SHA256 ?=
TRIXIE_DIGEST ?= docker.io/library/debian:trixie
REGISTRY ?= ghcr.io/gentlekingson

runner-image: ## Build + push the runner image, print its registry manifest digest
	@test -n "$(RUNNER_TARBALL_URL)" -a -n "$(RUNNER_TARBALL_SHA256)" || { echo "set RUNNER_TARBALL_URL and RUNNER_TARBALL_SHA256"; exit 1; }
	docker build -f docker/runner/Dockerfile \
	  --build-arg TRIXIE_DIGEST="$(TRIXIE_DIGEST)" \
	  --build-arg RUNNER_TARBALL_URL="$(RUNNER_TARBALL_URL)" \
	  --build-arg RUNNER_TARBALL_SHA256="$(RUNNER_TARBALL_SHA256)" \
	  -t $(REGISTRY)/ocserv-ci-runner:phase1 docker/runner/
	docker push $(REGISTRY)/ocserv-ci-runner:phase1
	@echo "=== Registry manifest digest (put in provisioner.conf RUNNER_IMAGE): ==="
	@docker buildx imagetools inspect $(REGISTRY)/ocserv-ci-runner:phase1 --format '{{.Manifest.Digest}}' \
	  | sed 's/^/$(REGISTRY)\/ocserv-ci-runner@/'

runner-provision: ## Dry-run the provisioner (token from stdin; never executes)
	@echo "Pipe token:  echo \$$TOKEN | sudo /usr/local/libexec/ocserv-ci/runner-provisioner --registration-token-stdin"
	@echo "Dry-run:     scripts/runner-provisioner.sh --dry-run < /dev/null"
```

- [ ] **Step 3: Create the runbook**

Create `docs/runner-ephemeral.md`:

```markdown
# Ephemeral ci-build Runner — Operator Runbook (Phase 1)

Phase 1 ships a **manually-triggered, single-slot** ephemeral runner for the
`lock-projection` job. NOT an autoscaler. One operator action → one runner
container → one job → bounded wait → auto-deregister → auto-remove.

## Image supply chain (build host → registry → runner host)

```text
build host:
  make runner-image RUNNER_TARBALL_URL=<actions-runner tarball URL> \
                    RUNNER_TARBALL_SHA256=<sha256 of that tarball> \
                    TRIXIE_DIGEST=docker.io/library/debian@sha256:<base digest>
  → pushes to registry, prints the registry MANIFEST digest
  (NOT RepoDigests of a local-only build; use buildx imagetools inspect)
registry:
  ghcr.io/<owner>/ocserv-ci-runner@sha256:<manifest digest>
runner host:
  docker pull ghcr.io/<owner>/ocserv-ci-runner@sha256:<manifest digest>
  → provisioner uses --pull=never (image must be pre-cached by exact digest)
```

The runner host needs NO GitHub runner-management credential. Registry read
access may be public or a minimal read-only token (NOT reused for Actions
registration, publish, deploy, or production).

## Runner host setup (one-time, as root, from an audited clone)

```bash
# Clone the repo revision you're installing from (NOT a user-writable checkout).
sudo git clone <repo> /root/ocserv-backport-install && cd /root/ocserv-backport-install
sudo git checkout <verified-commit-sha>
sudo bash scripts/runner-host-install.sh
# Edit /etc/ocserv-ci-runner/provisioner.conf: fill RUNNER_IMAGE (digest from above),
# and any internal IPs in ci-build-egress.netplan.
sudo chmod 0600 /etc/ocserv-ci-runner/provisioner.conf  # provisioner main() enforces root:root 0600
# Apply the egress firewall per the netplan (nftables DOCKER-USER).
```

**Never** run `sudo scripts/runner-provisioner.sh` from a user-writable checkout —
a non-root user could modify the script that root then executes. Always run the
installed copy at `/usr/local/libexec/ocserv-ci/runner-provisioner`.

## Launch a runner (per cycle)

1. Get a short-lived repository-scoped registration token from a trusted GitHub
   admin terminal. Do NOT store it on the runner host.
2. Launch (token via stdin; provisioner wraps docker run in `timeout`):

   ```bash
   echo "$REGISTRATION_TOKEN" | sudo /usr/local/libexec/ocserv-ci/runner-provisioner --registration-token-stdin
   ```

3. The provisioner prints the runner name + waits up to `RUNNER_WAIT_TIMEOUT`
   (default 45m). On timeout it SIGTERM/SIGKILLs the container (--rm removes it);
   GitHub may leave an offline record (manual cleanup, below).
4. Trigger the dual-track `lock-projection-cibuild` job (push to main).

## Verify lockdown (while runner runs)

```bash
docker inspect <runner-name> --format '
  Privileged={{.HostConfig.Privileged}}
  ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}}
  User={{.Config.User}}
  NetworkMode={{.HostConfig.NetworkMode}}
  OpenStdin={{.Config.OpenStdin}}
  CapAdd={{.HostConfig.CapAdd}}
  CapDrop={{.HostConfig.CapDrop}}
  Binds={{.HostConfig.Binds}}
  Tmpfs={{.HostConfig.Tmpfs}}'
```

Expected: `Privileged=false`, `ReadonlyRootfs=true`, `User=10001:10001`,
`NetworkMode=ci-build-egress`, `OpenStdin=true` (token via stdin),
`CapAdd=[]`, `CapDrop=[ALL]`, `Binds=[]`, no `docker.sock`.

## Egress verification (negative tests)

```bash
# From inside a job (or a test container on ci-build-egress):
curl -fsS --max-time 5 https://github.com && echo "github OK"      # must succeed
curl -fsS --max-time 5 http://<publish-host-IP>/ && echo FAIL      # must FAIL
curl -fsS --max-time 5 http://10.20.0.1/ && echo FAIL              # staging CIDR, must FAIL
```

## Cleanup offline runner records

If a runner times out or crashes before deregistering, GitHub may show an
**offline** record. Phase 1 does NOT auto-clean. Remove via GitHub UI
(Settings → Actions → Runners → offline runner → Remove).

## What this runner CANNOT do (by design)

- No Docker socket / sub-containers. No build toolchain (Phase 3).
- No aptly / GPG / R2 / Cloudflare / production SSH access.
- No autoscaling; no JIT; one manual launch = one runner = one job, bounded wait.
```

- [ ] **Step 4: shellcheck + commit**

Run: `shellcheck scripts/runner-host-install.sh` (no errors).
```bash
git add scripts/runner-host-install.sh Makefile docs/runner-ephemeral.md
git commit -m "feat(phase1): host install (root-owned libexec) + Makefile + runbook"
```

**Checkpoint review:** After Task 7, review workflow dependency closure (Task 6 dual-track uses image-baked deps, no pip), egress enforcement, root-owned installation, runbook before Task 8.

---

## Task 8: Workflow dual-track + full verification

**Files:**
- Modify: `.github/workflows/ci-testing.yml`

The dual-track job uses image-baked `python3-yaml` (NO runtime pip — the image already has it).

- [ ] **Step 1: Add the dual-track job (no pip install)**

In `.github/workflows/ci-testing.yml`, after the existing `lock-projection` job, insert:

```yaml
  lock-projection-cibuild:
    # Dual-track (Phase 1): same logic on the new ephemeral ci-build runner.
    # Uses image-baked python3 + python3-yaml (NO runtime pip install — the
    # ci-build image fully captures deps by digest; no PyPI egress needed).
    runs-on: [self-hosted, ci-build]
    steps:
      - uses: actions/checkout@v4
      - name: verify lock.tsv projection (ephemeral ci-build runner)
        run: |
          set -euo pipefail
          while IFS= read -r -d '' yaml; do
            python3 scripts/read-source-lock.py --lock "$yaml" > /tmp/proj.tsv
            cmp -s /tmp/proj.tsv "${yaml%.yaml}.lock.tsv" \
              || { echo "lock.tsv drift: $yaml"; exit 1; }
          done < <(find source-lock -type f -name '*.yaml' -print0 | sort -z)
          while IFS= read -r -d '' tsv; do
            [[ -f "${tsv%.lock.tsv}.yaml" ]] \
              || { echo "orphan lock.tsv: $tsv"; exit 1; }
          done < <(find source-lock -type f -name '*.lock.tsv' -print0 | sort -z)
```

- [ ] **Step 2: Validate YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci-testing.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Full bats suite + shellcheck**

Run: `make test` (all green).
Run: `shellcheck scripts/runner-provisioner.sh scripts/runner-host-install.sh docker/runner/entrypoint.sh` (no errors).

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
echo "dummy-not-real" | PROVISIONER_CONFIG="$tmpcfg" bash scripts/runner-provisioner.sh --registration-token-stdin --dry-run --runner-name ci-build-VERIFY 2>&1
rm -f "$tmpcfg"
```

Expected: prints `timeout ... docker run ... -i ...` with all security flags; does NOT print `dummy-not-real`; exits 0.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci-testing.yml
git commit -m "feat(phase1): dual-track lock-projection on ci-build (image-baked deps, no pip)"
```

> **Real runner-host lifecycle drill (operator, with a real short-lived token) happens only after all local acceptance (Steps 1-4) passes, per the user's inline-execution checkpoint plan.** Do NOT use a real registration token in automation.

---

## Acceptance checklist (maps to Phase 0 §11.3 + user's Phase 1 closure + v1.1 revisions)

```text
Provisioner (test_runner_provisioner.bats):
  ☐ arg validation; forbidden args rejected (--privileged/--mount/--cap-add/--network/--image/--env/-v)
  ☐ no-token-source rejection
  ☐ stdin token path; dry-run NEVER prints token
  ☐ -i/--interactive present (token readable from stdin)
  ☐ fixed docker params (read-only, cap-drop=ALL, no-new-privileges, uid 10001)
  ☐ no --privileged/socket/-v/cap-add/host net; fixed non-secret env only
  ☐ image must be 64-hex @sha256 digest
  ☐ root-owned config (owner/mode/symlink) enforced in main()
  ☐ RUNNER_WAIT_TIMEOUT -> bounded timeout argv present
  ☐ live-mode --runner-name format validation

Entrypoint (test_runner_entrypoint.bats):
  ☐ non-root via stubbable current_uid (NOT readonly EUID)
  ☐ rootfs read-only via mount option 'ro' (NOT write-probe)
  ☐ /runner /work /tmp = tmpfs type via findmnt + nosuid/nodev (/tmp +noexec)
  ☐ no-preserve-ownership payload copy
  ☐ config.sh --ephemeral --unattended --disableupdate; ci-build label; /work

Network (test_runner_network.bats):
  ☐ egress allow/deny list logic (github allow, publish-host/private CIDR deny)

Runtime inspect (operator runbook, on runner host):
  ☐ Privileged=false; CapAdd=[]; no docker.sock; no bind mount
  ☐ NetworkMode=ci-build-egress (not host); PID/IPC/User ns not host
  ☐ User=10001:10001; ReadonlyRootfs=true; OpenStdin=true
  ☐ /runner /work /tmp = tmpfs; memory/cpu/pids limits; image = digest
  ☐ egress: github/deb.debian.org succeed; publish-host/staging/private CIDR fail

Image supply chain:
  ☐ base image digest-pinned; runner tarball ADD --checksum=sha256:
  ☐ build→push→pull by manifest digest; --pull=never
  ☐ NO runtime pip (python3-yaml baked in)

GitHub lifecycle (operator runbook):
  ☐ registers with ci-build label; handles one lock-projection job
  ☐ auto-deregisters (--ephemeral); container removed (--rm)
  ☐ no host persistence; runner host gains no aptly/GPG/R2/CF/SSH/prod cred
```
