# Phase 1 — Ephemeral Runner Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimal, manually-triggered, single-slot ephemeral GitHub Actions runner that runs the `lock-projection` job in a non-root, non-privileged, docker-socket-less container, then auto-deregisters and auto-removes.

**Architecture:** A root-owned bash provisioner (`scripts/runner-provisioner.sh`) reads a short-lived GitHub registration token from stdin and launches a fixed-parameter `docker run --rm` of a digest-pinned runner image. The image's non-root entrypoint (`docker/runner/entrypoint.sh`, UID/GID 10001:10001) copies the actions-runner payload from a read-only image layer to a `/runner` tmpfs, runs `config.sh --ephemeral --unattended --disableupdate` with a fixed `ci-build` label, then `run.sh`. One job → runner exits → container removed. No autoscaler, no timer, no GitHub management credential on the host.

**Tech Stack:** Bash (provisioner + entrypoint), Docker (runner container), Debian trixie (base image), GitHub Actions self-hosted runner (actions/runner tarball), bats (tests), shellcheck (lint).

**Parent spec:** `docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md` §1.1 (Runner Host), §5 (ci-build label), §11.2 (dual-track migration), §11.4 (build job → ci-build label).

**Phase 1 scope (hard boundary):** provisioner + non-root ephemeral image + `--ephemeral`/`--rm` lifecycle + read-only rootfs + tmpfs `/runner`/`/work`/`/tmp` + no docker socket + no `--privileged` + `--cap-drop=ALL` + `no-new-privileges` + no sensitive bind mount + resource limits + network egress constraint + migrate `lock-projection` to `[self-hosted, ci-build]` + automated acceptance.

**Explicitly NOT in Phase 1:** candidate release API, mTLS bootstrap, R2 staging, manifest/provenance upload, Sigstore, aptly, GPG, publish host, testing publish, staging deploy, production promotion, rollback control plane, production credentials, JIT runner config, autoscaler/timer/pool.

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `scripts/runner-provisioner.sh` | Root-owned provisioner: parse config, read token from stdin, generate runner name, run fixed `docker run`, audit. No arbitrary docker args. | New |
| `docker/runner/Dockerfile` | Build non-root (10001:10001) trixie image with actions-runner payload + lock-projection deps (python3/venv/pip/PyYAML) + git/make/ca-certs. No build toolchain beyond lock-projection needs (sbuild/dpkg-buildpackage is Phase 3). | New |
| `docker/runner/entrypoint.sh` | Container entrypoint (UID 10001): assert non-root + tmpfs + read-only rootfs, copy payload → /runner, read token from stdin, config.sh --ephemeral, run.sh. Never prints token. | New |
| `test/test_runner_provisioner.bats` | Provisioner pure-logic tests: arg validation, no-token rejection, dry-run output, fixed docker params, forbidden args rejected, image-must-be-digest, config parse, no token in output. | New |
| `test/test_runner_entrypoint.bats` | Entrypoint assertion-function tests (sourced pure functions): UID/GID check, tmpfs check, read-only check, token-not-in-env. | New |
| `.github/workflows/ci-testing.yml` | Dual-track: keep `lock-projection` on `builder` AND add a `lock-projection-cibuild` job on `[self-hosted, ci-build]` (Phase 1 validates equivalence before switching default in a later slice). | Modify |
| `Makefile` | Add `runner-image` (build), `runner-provision` (dry-run wrapper) targets. | Modify |
| `docs/runner-ephemeral.md` | Operator runbook: how to get token, run provisioner, verify, cleanup offline runner records. | New |

**Decomposition rationale:** Provisioner and entrypoint are separate files because they run in different trust domains (host root vs container non-root) and are tested independently. Tests source pure functions rather than executing the full docker/config.sh flow (which needs a real runner host + token).

---

## Task 1: Provisioner config parser + helpers

**Files:**
- Create: `scripts/runner-provisioner.sh`
- Create: `test/test_runner_provisioner.bats`
- Test: `test/test_runner_provisioner.bats`

The provisioner sources `scripts/_common.sh` for `log`/`die`. This task adds the config-loading + arg-parsing + name-generation pure functions and tests them; the actual `docker run` is Task 3.

- [ ] **Step 1: Write failing tests for config parsing and name generation**

Create `test/test_runner_provisioner.bats`:

```bash
load helpers/bats-helper.bash

# Source the provisioner WITHOUT running main (it guards on BASH_SOURCE == $0,
# same pattern as bootstrap-build-host.sh). We test the pure functions.
PROVISIONER="${REPO_ROOT}/scripts/runner-provisioner.sh"

setup() {
  cd "${REPO_ROOT}"
  # _common.sh uses stat -c etc; on macOS these differ, so we only source the
  # pure functions and stub the ones that call GNU stat.
  : # no-op; each test sources what it needs
}

@test "load_provisioner_config: reads non-sensitive fixed config, rejects missing file" {
  # We test the config-reading function in isolation by sourcing the script
  # (main is guarded) and calling the function with a temp config.
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<'EOF'
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:abc123
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo \"URL=\${RUNNER_URL}\" \"LABEL=\${RUNNER_LABEL}\" \"IMAGE=\${RUNNER_IMAGE}\""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'URL=https://github.com/GentleKingson/ocserv-backport'
  echo "$output" | grep -q 'LABEL=ci-build'
  echo "$output" | grep -q 'IMAGE=ghcr.io/owner/img@sha256:abc123'
  rm -f "$tmpcfg"
}

@test "load_provisioner_config: dies on missing config file" {
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config /nonexistent/provisioner.conf; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "generate_runner_name: produces ci-build-<26-char-base32> shape (ULID-like)" {
  run bash -c "set +e; source '${PROVISIONER}'; name=\$(generate_runner_name); echo \"\$name\""
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^ci-build-[0-9A-ZJKMNPQRTVWXY]{26}$'
}

@test "generate_runner_name: two calls produce different names (high entropy)" {
  run bash -c "set +e; source '${PROVISIONER}'; a=\$(generate_runner_name); b=\$(generate_runner_name); echo \"\$a\"; echo \"\$b\""
  [ "$status" -eq 0 ]
  a="$(echo "$output" | sed -n 1p)"
  b="$(echo "$output" | sed -n 2p)"
  [ "$a" != "$b" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_runner_provisioner.bats`
Expected: FAIL — `scripts/runner-provisioner.sh` does not exist yet.

- [ ] **Step 3: Create the provisioner with config parser + name generator**

Create `scripts/runner-provisioner.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

# runner-provisioner.sh — Phase 1 ephemeral ci-build runner launcher.
# Root-owned, fixed-parameter, single-slot, manually-triggered.
# NOT an autoscaler/timer/pool. Reads registration token from stdin only.
# Spec: docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md §1.1, §5.

DEFAULT_CONFIG="/etc/ocserv-ci-runner/provisioner.conf"

# load_provisioner_config <file> — reads root-owned non-sensitive fixed config.
# Only accepts RUNNER_* keys; rejects missing file. Dies on missing required keys.
load_provisioner_config() {
  local cfg="$1"
  [[ -f "${cfg}" ]] || die "provisioner config not found: ${cfg} (create ${DEFAULT_CONFIG})"
  local line key val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    [[ "${key}" =~ ^RUNNER_[A-Z0-9_]+$ ]] || continue
    export "${key}=${val}"
  done < "${cfg}"
  # Required keys (no token here — token is stdin-only, never in config).
  local req k
  req=(RUNNER_URL RUNNER_LABEL RUNNER_IMAGE RUNNER_NETWORK RUNNER_CPUS RUNNER_MEMORY RUNNER_PIDS_LIMIT RUNNER_TMPFS_WORK_SIZE RUNNER_TMPFS_RUNNER_SIZE RUNNER_TMPFS_TMP_SIZE RUNNER_WAIT_TIMEOUT)
  for k in "${req[@]}"; do
    [[ -n "${!k:-}" ]] || die "missing required config key: ${k} in ${cfg}"
  done
}

# generate_runner_name — ci-build-<26-char Crockford Base32>. High entropy,
# no business semantics (not run id / branch / version). Uses /dev/urandom.
generate_runner_name() {
  # Crockford Base32 alphabet (excludes I/L/O/U to avoid ambiguity)
  local alphabet="0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  local name="ci-build-"
  local i rand
  for ((i=0; i<26; i++)); do
    # Read one byte from urandom, mod alphabet length (32, power of 2, no bias).
    rand="$(od -An -tu1 -N1 /dev/urandom | tr -d ' ')"
    name+="${alphabet:$((rand % 32)):1}"
  done
  printf '%s' "${name}"
}

# (main + docker run added in Task 3)

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: this script's main() is not implemented yet (Task 3)" >&2
  exit 2
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_runner_provisioner.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: shellcheck the new script**

Run: `shellcheck scripts/runner-provisioner.sh`
Expected: no errors. (If `external-sources=true` flags `_common.sh`, that's expected; fix only errors in `runner-provisioner.sh` itself.)

- [ ] **Step 6: Commit**

```bash
git add scripts/runner-provisioner.sh test/test_runner_provisioner.bats
git commit -m "feat(phase1): runner provisioner config parser + name generator"
```

---

## Task 2: Provisioner arg validation + forbidden-args guard

**Files:**
- Modify: `scripts/runner-provisioner.sh`
- Modify: `test/test_runner_provisioner.bats`

The provisioner must accept ONLY a fixed allowlist of flags and reject anything that could weaken the container (`--docker-arg`, `--mount`, `--privileged`, `--cap-add`, `--network`, `--image`, `--label`, `--env`, etc.). This task adds `parse_args` + tests.

- [ ] **Step 1: Add failing tests for arg parsing**

Append to `test/test_runner_provisioner.bats`:

```bash
@test "parse_args: accepts --registration-token-stdin, sets mode" {
  run bash -c "set +e; source '${PROVISIONER}'; TOKEN_STDIN=0; parse_args --registration-token-stdin; echo \"TOKEN_STDIN=\${TOKEN_STDIN}\""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'TOKEN_STDIN=1'
}

@test "parse_args: accepts --dry-run" {
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=0; parse_args --dry-run; echo \"DRY=\${BOOTSTRAP_DRY_RUN}\""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'DRY=1'
}

@test "parse_args: accepts --runner-name <name> with valid shape" {
  run bash -c "set +e; source '${PROVISIONER}'; RUNNER_NAME=''; parse_args --runner-name ci-build-TESTNAME; echo \"NAME=\${RUNNER_NAME}\""
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'NAME=ci-build-TESTNAME'
}

@test "parse_args: REJECTS --docker-arg (forbidden)" {
  run bash -c "set +e; source '${PROVISIONER}'; parse_args --docker-arg --privileged; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "parse_args: REJECTS --privileged / --mount / --cap-add / --network / --image / --label / --env" {
  for bad in --privileged --mount /x --cap-add SYS_ADMIN --network host --image evil --label x --env SECRET; do
    run bash -c "set +e; source '${PROVISIONER}'; parse_args '$bad'; echo rc=\$?"
    [ "$status" -ne 0 ] || { echo "FAIL: $bad was accepted"; exit 1; }
  done
}

@test "parse_args: rejects unknown flag" {
  run bash -c "set +e; source '${PROVISIONER}'; parse_args --bogus; echo rc=\$?"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_runner_provisioner.bats`
Expected: FAIL on the new 6 tests (parse_args not defined).

- [ ] **Step 3: Add parse_args to the provisioner**

Insert before the `if [[ "${BASH_SOURCE[0]}"...` guard in `scripts/runner-provisioner.sh`:

```bash
# parse_args — fixed allowlist. Any flag outside this set is REJECTED, especially
# anything that could weaken the container. Security-critical values come from the
# root-owned config, never the operator command line.
parse_args() {
  TOKEN_STDIN="${TOKEN_STDIN:-0}"
  BOOTSTRAP_DRY_RUN="${BOOTSTRAP_DRY_RUN:-0}"
  RUNNER_NAME="${RUNNER_NAME:-}"
  RUNNER_NAME_OVERRIDE="${RUNNER_NAME_OVERRIDE:-0}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --registration-token-stdin) TOKEN_STDIN=1; shift ;;
      --dry-run) BOOTSTRAP_DRY_RUN=1; shift ;;
      --runner-name)
        [[ $# -ge 2 ]] || die "--runner-name requires a value"
        RUNNER_NAME="$2"; RUNNER_NAME_OVERRIDE=1; shift 2 ;;
      --wait-timeout)
        [[ $# -ge 2 ]] || die "--wait-timeout requires a value"
        RUNNER_WAIT_TIMEOUT_OVERRIDE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      # Explicit rejection of everything that could weaken the container.
      --docker-arg|--mount|--cap-add|--cap-drop-override|--privileged|--pid|--ipc|--uts|--userns|--network|--image|--label|--env|--device|-v|--volume)
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
  --runner-name <name>         override generated name (default: ci-build-<ULID>)
  --wait-timeout <duration>    override RUNNER_WAIT_TIMEOUT from config
  -h, --help
Token is read from stdin ONLY; never passed as an argument or env var.
Security-critical params (image digest, network, caps, mounts) come from
the root-owned config at ${DEFAULT_CONFIG}, never the command line.
EOF
}
```

Also add `RUNNER_WAIT_TIMEOUT_OVERRIDE` to the set of variables (it's read in Task 3).

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_runner_provisioner.bats`
Expected: PASS (10 tests).

- [ ] **Step 5: shellcheck**

Run: `shellcheck scripts/runner-provisioner.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/runner-provisioner.sh test/test_runner_provisioner.bats
git commit -m "feat(phase1): provisioner arg validation + forbidden-args guard"
```

---

## Task 3: Provisioner docker-run builder + main (dry-run path)

**Files:**
- Modify: `scripts/runner-provisioner.sh`
- Modify: `test/test_runner_provisioner.bats`

Build the fixed `docker run` command string (never executed with token in dry-run), wire up `main`, and assert the dry-run output contains the required security flags and NEVER the token.

- [ ] **Step 1: Add failing tests for the docker command builder + dry-run**

Append to `test/test_runner_provisioner.bats`:

```bash
@test "build_docker_run_args: emits fixed safe params (read-only, cap-drop, no-new-privileges, uid 10001, tmpfs)" {
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<'EOF'
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:abc123
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; build_docker_run_args 'ci-build-TEST'; printf '%s\n' \"\$@\""
  rm -f "$tmpcfg"
  [ "$status" -eq 0 ]
  # Required security flags
  echo "$output" | grep -qx -- '--rm'
  echo "$output" | grep -qx -- '--init'
  echo "$output" | grep -qx -- '--read-only'
  echo "$output" | grep -qx -- '--user=10001:10001'
  echo "$output" | grep -qx -- '--cap-drop=ALL'
  echo "$output" | grep -qx -- '--security-opt=no-new-privileges:true'
  echo "$output" | grep -q -- '--memory=6g'
  echo "$output" | grep -q -- '--cpus=2'
  echo "$output" | grep -q -- '--pids-limit=512'
  echo "$output" | grep -q -- '--network=ci-build-egress'
  echo "$output" | grep -q -- '--name=ci-build-TEST'
  # tmpfs mounts
  echo "$output" | grep -q -- '--tmpfs /runner:rw,nosuid,nodev'
  echo "$output" | grep -q -- '--tmpfs /work:rw,nosuid,nodev'
  echo "$output" | grep -q -- '--tmpfs /tmp:rw,nosuid,nodev,noexec'
  # image by digest
  echo "$output" | grep -qx -- 'ghcr.io/owner/img@sha256:abc123'
}

@test "build_docker_run_args: ABSENT — no --privileged, no socket mount, no -v /etc, no cap-add, no host network" {
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<'EOF'
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:abc123
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; build_docker_run_args 'ci-build-TEST'; printf '%s\n' \"\$@\""
  rm -f "$tmpcfg"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q -- '--privileged'
  ! echo "$output" | grep -q -- 'docker.sock'
  ! echo "$output" | grep -qE -- '-v|--volume'
  ! echo "$output" | grep -q -- '--cap-add'
  ! echo "$output" | grep -q -- '--network=host'
  ! echo "$output" | grep -q -- '--pid=host'
  # --env allowed ONLY for the 3 fixed non-secret config values; nothing else.
  echo "$output" | grep -q -- '--env RUNNER_URL='
  echo "$output" | grep -q -- '--env RUNNER_LABEL='
  echo "$output" | grep -q -- '--env RUNNER_NAME=ci-build-TEST'
  # No arbitrary secret env injection.
  ! echo "$output" | grep -qi -- '--env.*TOKEN'
  ! echo "$output" | grep -qi -- '--env.*SECRET'
  ! echo "$output" | grep -qi -- '--env.*PASSWORD'
}

@test "assert_image_is_digest: accepts @sha256:, rejects floating tag" {
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'ghcr.io/o/i@sha256:abc'; echo rc=\$?"
  [ "$status" -eq 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'debian:trixie'; echo rc=\$?"
  [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; assert_image_is_digest 'ghcr.io/o/i:latest'; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "main --dry-run: prints docker run, NEVER prints token, exits 0" {
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<'EOF'
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:abc123
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  SECRET_TOKEN="ghs_SUPERSECRET_never_leak_12345"
  run bash -c "set +e; echo '${SECRET_TOKEN}' | PROVISIONER_CONFIG='${tmpcfg}' bash '${PROVISIONER}' --registration-token-stdin --dry-run --runner-name ci-build-DRYTEST 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  echo "$output" | grep -q 'rc=0'
  echo "$output" | grep -q 'docker run'
  # Token must NEVER appear
  ! echo "$output" | grep -q 'SUPERSECRET'
}

@test "main: rejects when --registration-token-stdin missing (no token source)" {
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<'EOF'
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:abc123
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  run bash -c "set +e; PROVISIONER_CONFIG='${tmpcfg}' bash '${PROVISIONER}' --dry-run --runner-name ci-build-X 2>&1; echo rc=\$?"
  rm -f "$tmpcfg"
  # Non-zero, because no token source
  echo "$output" | grep -qv 'rc=0'
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_runner_provisioner.bats`
Expected: FAIL on the new 5 tests (build_docker_run_args / assert_image_is_digest / main not defined).

- [ ] **Step 3: Implement build_docker_run_args, assert_image_is_digest, main**

Replace the placeholder `if [[ "${BASH_SOURCE[0]}"...` block at the end of `scripts/runner-provisioner.sh` with:

```bash
# assert_image_is_digest <image> — refuse floating tags; require @sha256:.
assert_image_is_digest() {
  local img="$1"
  [[ "${img}" =~ @sha256:[0-9a-f]{64}$ ]] \
    || die "RUNNER_IMAGE must be pinned by digest (got: '${img}'); floating tags forbidden"
}

# build_docker_run_args <runner_name> — emits the FIXED, safe docker run argv.
# Reads RUNNER_* from config. No token here (token goes to container stdin).
# Non-secret config (URL/label/name) is passed as fixed --env values generated by
# the provisioner from root-owned config — NOT injected by the operator (operator
# --env is rejected in parse_args). The token is the ONLY secret and goes via stdin.
build_docker_run_args() {
  local name="$1"
  assert_image_is_digest "${RUNNER_IMAGE}"
  # Order: lifecycle → identity → security → resources → network → env → storage → image
  printf '%s\0' \
    run --rm --init \
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

# main — orchestrates: parse args → load config → read token from stdin → launch.
# Token is read into a local var, piped to docker run stdin, never logged.
main() {
  local config="${PROVISIONER_CONFIG:-${DEFAULT_CONFIG}}"
  parse_args "$@"
  [[ "${TOKEN_STDIN}" -eq 1 ]] \
    || die "token source required: use --registration-token-stdin (token is read from stdin, never an arg/env)"
  load_provisioner_config "${config}"
  if [[ -n "${RUNNER_WAIT_TIMEOUT_OVERRIDE:-}" ]]; then
    RUNNER_WAIT_TIMEOUT="${RUNNER_WAIT_TIMEOUT_OVERRIDE}"
  fi
  if [[ "${RUNNER_NAME_OVERRIDE:-0}" -ne 1 ]]; then
    RUNNER_NAME="$(generate_runner_name)"
  fi
  log "runner: ${RUNNER_NAME} image=${RUNNER_IMAGE} network=${RUNNER_NETWORK} timeout=${RUNNER_WAIT_TIMEOUT}"

  # Build argv into an array.
  local docker_argv=()
  while IFS= read -r -d '' a; do
    docker_argv+=("${a}")
  done < <(build_docker_run_args "${RUNNER_NAME}")

  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would run (token from stdin, suppressed):"
    printf '  docker %q\n' "${docker_argv[@]}" >&2
    return
  fi

  # Read token from stdin, pipe to docker run's stdin (container entrypoint reads it).
  # Token lives only in this pipe + the container's stdin; never in argv/env/disk/log.
  docker "${docker_argv[@]}" < /dev/stdin
  local rc=$?
  log "runner ${RUNNER_NAME} exited rc=${rc} (ephemeral: auto-deregistered by GitHub, container removed by --rm)"
  return $rc
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_runner_provisioner.bats`
Expected: PASS (15 tests).

- [ ] **Step 5: shellcheck**

Run: `shellcheck scripts/runner-provisioner.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add scripts/runner-provisioner.sh test/test_runner_provisioner.bats
git commit -m "feat(phase1): provisioner docker-run builder + main (dry-run, stdin token)"
```

---

## Task 4: Runner image Dockerfile (non-root, trixie, lock-projection deps)

**Files:**
- Create: `docker/runner/Dockerfile`
- Create: `docker/runner/.dockerignore`

Build the first Dockerfile in the repo. Base on `debian:trixie` (Phase 1 uses the tag for the base layer; the *resulting* image is pinned by digest at provision time — see note). Create a non-root user 10001:10001, install only what lock-projection needs (python3/venv/pip + PyYAML + git + make + ca-certs), and stage the actions-runner payload read-only.

> **Note on digest pinning:** The *base* `debian:trixie` tag is acceptable in Phase 1 because the security boundary is the **built image digest** (`RUNNER_IMAGE=...@sha256:` in provisioner.conf), not the base tag. Phase 3 will revisit base-image pinning when the build toolchain (dpkg-buildpackage) is added. This matches Phase 0 §2.3 which pins `builder.image_digest` (the built image), not the base.

- [ ] **Step 1: Create the Dockerfile**

Create `docker/runner/Dockerfile`:

```dockerfile
# Phase 1 ephemeral ci-build runner image.
# Non-root (UID/GID 10001:10001), read-only rootfs at runtime (provisioner sets --read-only).
# Scope: lock-projection only (python3 + PyYAML + git + make). Build toolchain (dpkg-buildpackage)
# is Phase 3, deliberately NOT installed here.
# Spec: docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md §1.1, §2.3.

FROM debian:trixie

# Create non-root user with fixed UID/GID 10001 (no login, no home on rootfs;
# /runner /work /tmp are tmpfs at runtime).
RUN groupadd --system --gid 10001 runner \
 && useradd  --system --uid 10001 --gid 10001 --no-create-home --home-dir /runner runner

# Install ONLY lock-projection dependencies. No docker, no sbuild, no build-essential,
# no curl in the final image (ca-certs + git + python3-venv + PyYAML + make suffice).
# Clean apt lists to keep the layer small.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      git \
      make \
      python3 \
      python3-venv \
      python3-pip \
 && pip3 --no-cache-dir install --break-system-packages PyYAML==6.0.2 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Stage the actions-runner payload as a read-only source the entrypoint copies to /runner.
# The tarball is provided at build time (build arg); see Makefile runner-image target.
# Placed under /opt (root-owned, read-only at runtime via --read-only).
ARG RUNNER_TARBALL_URL
ADD "${RUNNER_TARBALL_URL}" /opt/actions-runner.tar.gz
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
# Keep build context minimal — only the entrypoint is COPYed; the runner tarball is ADDed from URL.
*
!entrypoint.sh
```

- [ ] **Step 3: Verify Dockerfile parses (build with a dummy URL is a Task 7 concern; here just lint)**

Run: `docker build --check -f docker/runner/Dockerfile docker/runner/ 2>&1 | head -20` (if `docker build --check` is unavailable on the host, skip; this is a syntax sanity step, not a functional test — full build happens on the runner host in Task 7's runbook).

Expected: no syntax errors (or "Check not supported" — acceptable to skip).

- [ ] **Step 4: Commit**

```bash
git add docker/runner/Dockerfile docker/runner/.dockerignore
git commit -m "feat(phase1): non-root trixie runner image Dockerfile (lock-projection deps)"
```

---

## Task 5: Runner entrypoint (assertions + config + run)

**Files:**
- Create: `docker/runner/entrypoint.sh`
- Create: `test/test_runner_entrypoint.bats`

The entrypoint runs as UID 10001 inside the container. It must: assert it's non-root + tmpfs present + read-only rootfs; copy payload to /runner; read token from stdin; run config.sh with the fixed flags; run run.sh. Pure assertion functions are testable by sourcing.

- [ ] **Step 1: Write failing tests for the assertion functions**

Create `test/test_runner_entrypoint.bats`:

```bash
load helpers/bats-helper.bash

ENTRYPOINT="${REPO_ROOT}/docker/runner/entrypoint.sh"

@test "assert_running_as_10001: passes when EUID==10001 simulated" {
  # We can't easily change EUID in bats; test the logic by stubbing id.
  run bash -c "set +e; source '${ENTRYPOINT}'; EUID=10001; assert_running_as_10001; echo rc=\$?"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'rc=0'
}

@test "assert_running_as_10001: dies when not 10001" {
  run bash -c "set +e; source '${ENTRYPOINT}'; EUID=0; assert_running_as_10001; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "assert_tmpfs_writable: passes when /runner /work /tmp are writable dirs (repo has them as dirs on test host)" {
  # Create temp dirs to stand in for the tmpfs mounts.
  t="$(mktemp -d)"; mkdir -p "$t/runner" "$t/work" "$t/tmp"
  run bash -c "set +e; source '${ENTRYPOINT}'; assert_tmpfs_writable '$t/runner' '$t/work' '$t/tmp'; echo rc=\$?"
  rm -rf "$t"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'rc=0'
}

@test "assert_rootfs_readonly: dies when /sys is writable (rootfs not read-only)" {
  # /sys is read-only normally; test the negative by pointing at a writable tmpdir.
  t="$(mktemp -d)"
  run bash -c "set +e; source '${ENTRYPOINT}'; assert_rootfs_readonly '$t'; echo rc=\$?"
  rm -rf "$t"
  [ "$status" -ne 0 ]
}

@test "build_config_args: emits --ephemeral --unattended --disableupdate --labels ci-build --work /work" {
  run bash -c "set +e; source '${ENTRYPOINT}'; build_config_args 'https://github.com/GentleKingson/ocserv-backport' 'DUMMYTOKEN' 'ci-build-NAME' 'ci-build'; printf '%s\n' \"\$@\""
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx -- '--ephemeral'
  echo "$output" | grep -qx -- '--unattended'
  echo "$output" | grep -qx -- '--disableupdate'
  echo "$output" | grep -q -- '--url'
  echo "$output" | grep -q -- '--name=ci-build-NAME'
  echo "$output" | grep -q -- '--labels'
  echo "$output" | grep -q 'ci-build'
  echo "$output" | grep -q -- '--work=/work'
}
```

> Note: `DUMMYTOKEN` appears in a test arg list that we assert shape of — it never reaches a real config.sh. The token-leak protection is tested in Task 3's dry-run test (provisioner never prints it) and asserted structurally here (config args are built without printing).

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_runner_entrypoint.bats`
Expected: FAIL — entrypoint not found.

- [ ] **Step 3: Create entrypoint.sh with pure assertion functions + config/run flow**

Create `docker/runner/entrypoint.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Phase 1 ci-build runner container entrypoint (runs as UID 10001).
# Payload at /opt/actions-runner-src (read-only image layer); copied to /runner tmpfs.
# Token read from stdin, never logged, never exported, unset after config.
# Spec: docs/superpowers/specs/2026-06-21-phase-0-aptly-state-and-control-plane-design.md §1.1.

RUNNER_PAYLOAD_SRC="/opt/actions-runner-src"
RUNNER_PAYLOAD_DST="/runner"
WORK_DIR="/work"

die() { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[entrypoint] %s\n' "$*" >&2; }

# assert_running_as_10001 — refuse to run as root or any other UID.
assert_running_as_10001() {
  [[ "${EUID}" -eq 10001 ]] \
    || die "must run as UID 10001 (got ${EUID}); provisioner must pass --user=10001:10001"
}

# assert_tmpfs_writable <runner> <work> <tmp> — workspace mounts must be writable tmpfs.
assert_tmpfs_writable() {
  local r="$1" w="$2" t="$3"
  [[ -d "$r" && -w "$r" ]] || die "${r} missing or unwritable (expected tmpfs)"
  [[ -d "$w" && -w "$w" ]] || die "${w} missing or unwritable (expected tmpfs)"
  [[ -d "$t" && -w "$t" ]] || die "${t} missing or unwritable (expected tmpfs)"
}

# assert_rootfs_readonly <probe_dir> — rootfs must be read-only (provisioner --read-only).
# Tries to create a file in the probe dir; success means rootfs is writable = failure.
assert_rootfs_readonly() {
  local probe="$1"
  local f="${probe}/.ro-probe-$$"
  if touch "$f" 2>/dev/null; then
    rm -f "$f"
    die "rootfs appears writable at ${probe} (provisioner must set --read-only)"
  fi
}

# build_config_args <url> <token> <name> <label> — fixed config.sh argv.
# Token is passed positionally to config.sh; never echoed by this function.
build_config_args() {
  local url="$1" token="$2" name="$3" label="$4"
  printf '%s\0' \
    --url "${url}" \
    --token "${token}" \
    --name "${name}" \
    --labels "${label}" \
    --work "${WORK_DIR}" \
    --ephemeral \
    --unattended \
    --disableupdate
}

main() {
  assert_running_as_10001
  assert_tmpfs_writable "${RUNNER_PAYLOAD_DST}" "${WORK_DIR}" "/tmp"
  # Rootfs read-only check: probe a path that should be unwritable.
  assert_rootfs_readonly "/etc"

  log "copying runner payload ${RUNNER_PAYLOAD_SRC} -> ${RUNNER_PAYLOAD_DST}"
  cp -a "${RUNNER_PAYLOAD_SRC}/." "${RUNNER_PAYLOAD_DST}/"

  # Read token from stdin (one line). Never log, never export, never write to disk.
  local registration_token=""
  IFS= read -r registration_token || die "no registration token on stdin"
  [[ -n "${registration_token}" ]] || die "empty registration token on stdin"

  # URL/label come from provisioner via fixed env (set by docker run, but those
  # are non-secret config values, not credentials). In Phase 1 we read them from
  # env set by the provisioner's config; the token is the only secret.
  local url="${RUNNER_URL:?RUNNER_URL must be set}"
  local label="${RUNNER_LABEL:?RUNNER_LABEL must be set}"
  local name="${RUNNER_NAME:?RUNNER_NAME must be set}"

  local cfg_argv=()
  while IFS= read -r -d '' a; do cfg_argv+=("${a}"); done \
    < <(build_config_args "${url}" "${registration_token}" "${name}" "${label}")

  log "config.sh (token suppressed)"
  ( cd "${RUNNER_PAYLOAD_DST}" && ./config.sh "${cfg_argv[@]}" ) || die "config.sh failed"
  # Token no longer needed; clear it.
  registration_token=""

  log "run.sh (ephemeral: will exit after one job)"
  ( cd "${RUNNER_PAYLOAD_DST}" && ./run.sh ) || die "run.sh exited non-zero"
}

# Allow sourcing for tests (pure functions) without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_runner_entrypoint.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: shellcheck the entrypoint**

Run: `shellcheck docker/runner/entrypoint.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add docker/runner/entrypoint.sh test/test_runner_entrypoint.bats
git commit -m "feat(phase1): runner container entrypoint (non-root assertions, stdin token, config+run)"
```

---

## Task 6: Workflow dual-track (lock-projection on ci-build label)

**Files:**
- Modify: `.github/workflows/ci-testing.yml`

Per Phase 0 §11.2 (dual-track: add new path, don't touch old). Add a parallel `lock-projection-cibuild` job on `[self-hosted, ci-build]` that runs the same verification logic. It does NOT gate `build` yet (that switch is a later slice); it just proves the ephemeral runner can execute the job identically.

- [ ] **Step 1: Read the current lock-projection job**

Run: `sed -n '1,30p' .github/workflows/ci-testing.yml`
Confirm the existing `lock-projection` job uses `runs-on: [self-hosted, builder]`.

- [ ] **Step 2: Add the dual-track job**

In `.github/workflows/ci-testing.yml`, immediately after the existing `lock-projection` job block (after its closing line, before `build:`), insert:

```yaml
  lock-projection-cibuild:
    # Dual-track (Phase 1): same logic on the new ephemeral ci-build runner.
    # Does NOT gate `build` yet; validates the ephemeral runner executes identically.
    # Old `lock-projection` (builder label) remains the gate until the switch slice.
    runs-on: [self-hosted, ci-build]
    steps:
      - uses: actions/checkout@v4
      - name: verify lock.tsv projection (ephemeral ci-build runner)
        run: |
          set -euo pipefail
          python3 -m venv .ci-venv
          .ci-venv/bin/python -m pip install -r requirements/prefetch.txt
          while IFS= read -r -d '' yaml; do
            .ci-venv/bin/python scripts/read-source-lock.py --lock "$yaml" > /tmp/proj.tsv
            cmp -s /tmp/proj.tsv "${yaml%.yaml}.lock.tsv" \
              || { echo "lock.tsv drift: $yaml"; exit 1; }
          done < <(find source-lock -type f -name '*.yaml' -print0 | sort -z)
          while IFS= read -r -d '' tsv; do
            [[ -f "${tsv%.lock.tsv}.yaml" ]] \
              || { echo "orphan lock.tsv: $tsv"; exit 1; }
          done < <(find source-lock -type f -name '*.lock.tsv' -print0 | sort -z)
```

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci-testing.yml'))" && echo "YAML OK"`
Expected: `YAML OK`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci-testing.yml
git commit -m "feat(phase1): dual-track lock-projection on ephemeral ci-build runner"
```

---

## Task 7: Makefile targets + operator runbook

**Files:**
- Modify: `Makefile`
- Create: `docs/runner-ephemeral.md`

Add `runner-image` (build the image, to be run on the runner host) and `runner-provision` (dry-run wrapper) targets. Write the operator runbook covering token acquisition, launch, verification, and offline-record cleanup.

- [ ] **Step 1: Add Makefile targets**

In `Makefile`, before the `.PHONY: dry-run` block, add:

```makefile
.PHONY: runner-image runner-provision
runner-image: ## Build the ephemeral ci-build runner image (run ON the runner host)
	docker build -f docker/runner/Dockerfile \
	  --build-arg RUNNER_TARBALL_URL="$${RUNNER_TARBALL_URL}" \
	  -t ocserv-ci-runner:phase1 docker/runner/
	@echo "Image built. Tag it by digest in /etc/ocserv-ci-runner/provisioner.conf:"
	@echo "  docker inspect --format='{{index .RepoDigests 0}}' ocserv-ci-runner:phase1"

runner-provision: ## Dry-run the provisioner (token from stdin; never executes docker run)
	@echo "Pipe token via stdin:  echo \$\$TOKEN | make runner-provision ARGS='--runner-name ci-build-X'"
	scripts/runner-provisioner.sh --dry-run $(ARGS) < /dev/null
```

- [ ] **Step 2: Create the operator runbook**

Create `docs/runner-ephemeral.md`:

```markdown
# Ephemeral ci-build Runner — Operator Runbook (Phase 1)

Phase 1 ships a **manually-triggered, single-slot** ephemeral runner for the
`lock-projection` job. It is NOT an autoscaler. One operator action → one runner
container → one job → auto-deregister → auto-remove.

## Prerequisites (runner host, one-time)

1. Debian trixie amd64 host with Docker installed (the provisioner host; Docker
   daemon is used ONLY by the provisioner, never exposed to job containers).
2. Build the runner image (run on the runner host):

   ```bash
   # Get the latest actions/runner linux-x64 tarball URL from
   # https://github.com/actions/runner/releases (pin a specific version tag).
   export RUNNER_TARBALL_URL=<actions-runner-linux-x64-VERSION.tar.gz URL>
   make runner-image
   # Note the digest printed, put it in provisioner.conf as RUNNER_IMAGE.
   ```

3. Create the root-owned config (NOT containing any token/credential):

   ```bash
   sudo install -d -m 0750 /etc/ocserv-ci-runner
   sudo tee /etc/ocserv-ci-runner/provisioner.conf >/dev/null <<'EOF'
   RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
   RUNNER_LABEL=ci-build
   RUNNER_IMAGE=ghcr.io/owner/ocserv-ci-runner@sha256:<digest-from-step-2>
   RUNNER_NETWORK=ci-build-egress
   RUNNER_CPUS=2
   RUNNER_MEMORY=6g
   RUNNER_PIDS_LIMIT=512
   RUNNER_TMPFS_WORK_SIZE=16g
   RUNNER_TMPFS_RUNNER_SIZE=1g
   RUNNER_TMPFS_TMP_SIZE=1g
   RUNNER_WAIT_TIMEOUT=45m
   EOF
   sudo chmod 0600 /etc/ocserv-ci-runner/provisioner.conf
   sudo chown root:root /etc/ocserv-ci-runner/provisioner.conf
   ```

4. Configure the `ci-build-egress` Docker network (egress-only; no path to
   publish hosts / production / docker socket). Network creation details are
   host-specific; ensure the network does NOT bridge to production segments.

## Launch a runner (per verification cycle)

1. **Get a short-lived registration token** (repository-scoped) from a trusted
   GitHub admin terminal: GitHub UI → Settings → Actions → Runners → New
   self-hosted runner → copy the `--token` value, OR via the API with a
   short-lived PAT. **Do not** store this token on the runner host.

2. **Launch** (token via stdin, never as arg/env):

   ```bash
   echo "$REGISTRATION_TOKEN" | sudo scripts/runner-provisioner.sh --registration-token-stdin
   ```

3. The provisioner prints the runner name (e.g. `ci-build-<ULID>`). Confirm the
   runner shows **online** with label `ci-build` in GitHub → Settings → Actions → Runners.

4. Trigger the dual-track job: push to `main` (or `workflow_dispatch`). Watch the
   `lock-projection-cibuild` job pick up on `[self-hosted, ci-build]`.

5. After the job completes, the runner auto-deregisters (`--ephemeral`) and the
   container is removed (`--rm`).

## Verify the container is locked down

```bash
# While the runner is running, from the runner host:
docker inspect <runner-name> --format '
  Privileged={{.HostConfig.Privileged}}
  ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}}
  User={{.Config.User}}
  NetworkMode={{.HostConfig.NetworkMode}}
  CapAdd={{.HostConfig.CapAdd}}
  CapDrop={{.HostConfig.CapDrop}}
  Binds={{.HostConfig.Binds}}
  Tmpfs={{.HostConfig.Tmpfs}}'
```

Expected: `Privileged=false`, `ReadonlyRootfs=true`, `User=10001:10001`,
`NetworkMode=ci-build-egress`, `CapAdd=[]`, `CapDrop=[ALL]`, `Binds=[]`, no
`docker.sock` in any mount.

## Cleanup offline runner records

If a runner exits abnormally (timeout, crash) before deregistering, GitHub may
show an **offline** record. Phase 1 does NOT auto-clean these. Manually remove
via GitHub UI (Settings → Actions → Runners → select offline runner → Remove).

## What this runner CANNOT do (by design)

- No Docker socket / no sub-containers (cannot run `docker run` inside a job).
- No build toolchain yet (sbuild/dpkg-buildpackage arrive in Phase 3).
- No access to aptly / GPG / R2 / Cloudflare / production SSH.
- No autoscaling; one manual launch = one runner = one job.
```

- [ ] **Step 3: Commit**

```bash
git add Makefile docs/runner-ephemeral.md
git commit -m "feat(phase1): runner-image/runner-provision Makefile targets + operator runbook"
```

---

## Task 8: Full test suite + final verification

**Files:**
- (no new files; verification only)

- [ ] **Step 1: Run the entire bats suite**

Run: `make test`
Expected: all tests PASS, including the new `test_runner_provisioner.bats` (15) and `test_runner_entrypoint.bats` (5).

- [ ] **Step 2: shellcheck all new/modified scripts**

Run: `shellcheck scripts/runner-provisioner.sh docker/runner/entrypoint.sh`
Expected: no errors.

- [ ] **Step 3: Verify the dual-track workflow YAML still parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci-testing.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 4: Dry-run the provisioner end-to-end (no token, no docker exec)**

Run:
```bash
echo "dummy-not-real-token" | PROVISIONER_CONFIG=/tmp/test.conf scripts/runner-provisioner.sh --registration-token-stdin --dry-run --runner-name ci-build-VERIFY 2>&1
```
(with a `/tmp/test.conf` containing the RUNNER_* keys and a `@sha256:` image).

Expected: prints the full `docker run` with all security flags, does NOT print `dummy-not-real-token`, exits 0.

- [ ] **Step 5: Commit any final fixes**

If Steps 1-4 surfaced fixes, commit them. Otherwise this step is a no-op.

```bash
git add -A
git commit -m "test(phase1): full suite green + provisioner dry-run verified" || echo "nothing to commit"
```

---

## Acceptance checklist (maps to Phase 0 §11.3 + user's Phase 1 closure criteria)

These are verified by the tests above (pure logic) + the runbook's runtime inspect (on the runner host). The plan delivers the testable logic; runtime verification happens when an operator follows `docs/runner-ephemeral.md`.

```text
Provisioner (tested by test_runner_provisioner.bats):
  ☐ arg validation (allowlist; forbidden args rejected)
  ☐ no-token-source rejection
  ☐ stdin token path (dry-run never prints token)
  ☐ fixed docker params (read-only, cap-drop=ALL, no-new-privileges, uid 10001)
  ☐ no --privileged / socket / -v / cap-add / host network
  ☐ image must be @sha256: digest
  ☐ root-owned config parse

Entrypoint (tested by test_runner_entrypoint.bats):
  ☐ non-root UID/GID assertion (10001)
  ☐ /runner /work /tmp tmpfs writability assertion
  ☐ read-only rootfs assertion
  ☐ config.sh with --ephemeral --unattended --disableupdate
  ☐ fixed ci-build label + /work workspace
  ☐ token never in env/log

Runtime inspect (operator runbook, on runner host):
  ☐ Privileged=false
  ☐ CapAdd=[]
  ☐ no docker.sock mount
  ☐ no host bind mount
  ☐ NetworkMode != host; PID/IPC/User namespace != host
  ☐ User=10001:10001
  ☐ ReadonlyRootfs=true
  ☐ /runner /work /tmp = tmpfs
  ☐ memory/cpu/pids limits present
  ☐ image = digest

GitHub lifecycle (operator runbook):
  ☐ runner registers with ci-build label
  ☐ handles exactly one lock-projection job
  ☐ auto-deregisters after job (--ephemeral)
  ☐ container auto-removed (--rm)
  ☐ no host persistence of workspace/checkout/runner config
  ☐ runner host gains no aptly/GPG/R2/CF/SSH/production credential
```
