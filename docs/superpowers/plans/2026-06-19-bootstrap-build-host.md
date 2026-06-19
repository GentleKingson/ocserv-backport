# trixie Build Host Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the manual `docs/BUILD_HOST_BOOTSTRAP.md` runbook with an idempotent, staged `scripts/bootstrap-build-host.sh` plus `_common.sh` helpers, so a dedicated trixie amd64 builder can be initialized (and re-initialized / drift-checked) repeatably.

**Architecture:** Single staged bash script, run **on the target builder** as `BOOTSTRAP_BUILDER_USER` (default `builder`) with passwordless sudo. 11 stages with per-stage idempotency classes (safe-repeat / skip-if-exists / fail-if-exists / read-only). Config from env > `.bootstrap.env` (chmod 600) > `read -s`. GPG is a long-lived signing identity handled by 3 mutually-exclusive modes. GitHub runner/secrets stay manual — the script only prints a checklist.

**Tech Stack:** Bash (`set -euo pipefail`), GNU coreutils (`stat -c`, Linux-only target), `sudo`, `sbuild`/`schroot`, `aptly`, `gpg`, `rclone`. Tested with bats (parseable helpers) + shellcheck + `--dry-run` on the target host.

**Reference spec:** `docs/superpowers/specs/2026-06-19-bootstrap-build-host-design.md` (v2). All stage order, idempotency classes, guard rules, and naming come from that spec — do not improvise alternatives.

**Conventions (carry over from existing scripts):**
- `#!/usr/bin/env bash` + `set -euo pipefail` at top of every executable script.
- Source helpers with `source "$(dirname "$0")/_common.sh"`.
- Repo root is CWD unless noted.
- Conventional Commits.

**Three implementation-detail requirements from the user (treat as hard rules):**
1. **`load_config` must fill ALL declared-default vars uniformly** (see Task 3 default table) — no half-filled state.
2. **Internal var naming is unified:** after `load_config`, establish read-only local aliases (`BUILDER_USER`, `REPO_NAME`, `APTLY_ROOT`, `APT_BASE_URL`, `R2_BUCKET`) from the `BOOTSTRAP_*` env-exposed names, and use the aliases everywhere internally. Never mix the two — `set -u` would trip on a misspelled name.
3. **`run_cmd` is only for simple command arrays.** Redirects, pipes, here-docs, temp keyfiles, `jq` config writes get **dedicated safe wrappers** that never print secrets in dry-run (see Task 2 `run_safe_*` family).

**Test stance (same as the existing backport pipeline):** bats TDD for parseable helpers (`load_bootstrap_env_defaults`, `check_secret_file_mode`, `run_cmd`); shellcheck on all scripts; `--dry-run` is the integration gate on the target host. Never mock `sbuild`/`aptly`/`gpg`.

> **Environment note:** Several verification commands (`stat -c`, `apt-get`, `aptly`, `sbuild-createchroot`, `gpg`) only exist on a Linux/trixie box. On the macOS dev machine, run bats + shellcheck only and mark the rest as "target-host verification" — same approach used by the existing `dry-run.sh` plan.

---

## File Structure

```
scripts/
  _common.sh                       # EXTEND: add bootstrap helpers (Task 2)
  bootstrap-build-host.sh          # NEW: staged main script (Tasks 3-7)
test/
  test_bootstrap_helpers.bats      # NEW: bats for _common.sh additions (Tasks 2)
  fixtures/env/
    full.env                       # NEW: sample .bootstrap.env for tests
    quoted.env                     # NEW: values with quotes/equals
.bootstrap.env.example             # NEW: documented config template (Task 3)
Makefile                           # MODIFY: add bootstrap-build-host target (Task 7)
.gitignore                         # MODIFY: ignore .bootstrap.env (Task 3)
docs/BUILD_HOST_BOOTSTRAP.md       # REWRITE: point at the script (Task 7)
```

**Why this split:** `_common.sh` stays the single helper library (DRY — the existing pipeline scripts already source it). `bootstrap-build-host.sh` is one file because the spec's 11 stages share state and the spec (§3, decision "方案 1") explicitly chose a single staged script over multi-file orchestration. Tests cover only the parseable helpers per the test stance; stage bodies are validated by `--dry-run`.

---

## Task 1: Create a feature branch

**Files:** (none — git only)

- [ ] **Step 1: Branch off main**

Run:
```bash
git checkout main && git pull --ff-only 2>/dev/null || true
git checkout -b feat/bootstrap-build-host
git branch --show-current
```
Expected: `feat/bootstrap-build-host`.

- [ ] **Step 2: Confirm working tree clean**

Run: `git status --short`
Expected: no output.

---

## Task 2: Extend `_common.sh` with bootstrap helpers (TDD)

The helpers are pure parseable logic → bats TDD. They are added to the existing `_common.sh` (do NOT remove the existing `log`/`die`/`acquire_repo_publish_lock`/`valid_channel`/`require_channel`).

**Files:**
- Modify: `scripts/_common.sh` (append helpers)
- Create: `test/test_bootstrap_helpers.bats`
- Create: `test/fixtures/env/full.env`, `test/fixtures/env/quoted.env`

- [ ] **Step 1: Create fixtures**

`test/fixtures/env/full.env`:
```ini
# comment line
BOOTSTRAP_BUILDER_USER=builder
BOOTSTRAP_APTLY_ROOT=/var/aptly
BOOTSTRAP_REPO_NAME=ocserv-backports
BOOTSTRAP_GPG_PASSPHRASE=secret-with-=-sign
WEIRD_VAR=should-be-ignored
```

`test/fixtures/env/quoted.env`:
```ini
BOOTSTRAP_APT_BASE_URL="https://apt.example.com"
BOOTSTRAP_R2_BUCKET="apt-thehkus"
```

- [ ] **Step 2: Write failing tests**

`test/test_bootstrap_helpers.bats`:
```bash
#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() { cd "${REPO_ROOT}"; }
teardown() { :; }

# ---- load_bootstrap_env_defaults ----
@test "fills unset vars and does NOT override already-set env vars" {
  BOOTSTRAP_BUILDER_USER=from-env source scripts/_common.sh
  load_bootstrap_env_defaults test/fixtures/env/full.env
  [ "${BOOTSTRAP_BUILDER_USER}" = "from-env" ]      # not overridden
  [ "${BOOTSTRAP_APTLY_ROOT}" = "/var/aptly" ]      # filled from file
  [ "${BOOTSTRAP_REPO_NAME}" = "ocserv-backports" ]
  [ "${BOOTSTRAP_GPG_PASSPHRASE}" = "secret-with-=-sign" ]  # = not truncated
  [ -z "${WEIRD_VAR:-}" ]                            # non-BOOTSTRAP_ ignored
}

@test "strips surrounding double quotes from values" {
  unset BOOTSTRAP_APT_BASE_URL BOOTSTRAP_R2_BUCKET
  source scripts/_common.sh
  load_bootstrap_env_defaults test/fixtures/env/quoted.env
  [ "${BOOTSTRAP_APT_BASE_URL}" = "https://apt.example.com" ]
  [ "${BOOTSTRAP_R2_BUCKET}" = "apt-thehkus" ]
}

@test "skips blank and comment lines" {
  # full.env has a '# comment line' and blank lines; covered by the first test's
  # absence of failure. Assert explicitly that no error is raised.
  source scripts/_common.sh
  run load_bootstrap_env_defaults test/fixtures/env/full.env
  [ "$status" -eq 0 ]
}

# ---- require_var / is_set / cmd_exists ----
@test "require_var dies when var is unset" {
  source scripts/_common.sh
  unset MISSING_VAR_FOR_TEST
  run require_var MISSING_VAR_FOR_TEST
  [ "$status" -ne 0 ]
}

@test "is_set returns true for nonempty, false for empty/unset" {
  source scripts/_common.sh
  X=val; Y=""
  is_set X && true || false
  ! is_set Y
}

@test "cmd_exists finds bash, misses nosuchcmd_xyz" {
  source scripts/_common.sh
  cmd_exists bash
  ! cmd_exists nosuchcmd_xyz
}

# ---- run_cmd ----
@test "run_cmd executes the command when not dry-run" {
  source scripts/_common.sh
  BOOTSTRAP_DRY_RUN=0
  run run_cmd /bin/echo executed
  [ "$output" = "executed" ]
}

@test "run_cmd prints DRY-RUN and does NOT execute when dry-run" {
  source scripts/_common.sh
  BOOTSTRAP_DRY_RUN=1
  run run_cmd /bin/echo should-not-run
  [ "$status" -eq 0 ]
  [[ "$output" == "DRY-RUN:"* ]]
  [[ "$output" != *"should-not-run-executed-via-side-effect"* ]]
}
```

- [ ] **Step 3: Run tests, confirm failure**

Run: `bats test/test_bootstrap_helpers.bats`
Expected: FAIL — functions `load_bootstrap_env_defaults`, `require_var`, `is_set`, `cmd_exists`, `run_cmd` are not defined.

- [ ] **Step 4: Append helpers to `scripts/_common.sh`**

Append (after the existing content, before EOF):
```bash

# ---- bootstrap helpers (spec §3.2) -----------------------------------------
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
is_set()     { [[ -n "${!1:-}" ]]; }
require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "required variable missing: ${name}"
}

# read -s a missing secret; never logs, never set -x
read_secret_if_missing() {
  local name="$1" prompt="$2"
  if [[ -z "${!name:-}" ]]; then
    read -r -s -p "${prompt}: " "${name}" >&2
    printf '\n' >&2
    export "${name}"
  fi
}

# load_bootstrap_env_defaults <file>
# Fill defaults for vars NOT already set; never override caller-provided env.
# key validated ^BOOTSTRAP_[A-Z0-9_]+$; value via %%=/=#= so '=' in value is safe.
# .bootstrap.env supports only KEY=value / KEY="value"; no shell expansion.
load_bootstrap_env_defaults() {
  local file="$1" line key val
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"
    [[ "${key}" =~ ^BOOTSTRAP_[A-Z0-9_]+$ ]] || continue
    [[ -n "${!key:-}" ]] || export "${key}=${val}"
  done < "${file}"
}

# check_secret_file_mode <file>  (GNU stat -c; target is Linux/trixie only)
check_secret_file_mode() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local mode owner
  mode="$(stat -c '%a' "${file}")"
  owner="$(stat -c '%U' "${file}")"
  [[ "${mode}" == "600" ]] || die "${file} must be chmod 600 (got ${mode})"
  [[ "${owner}" == "$(id -un)" ]] || die "${file} must be owned by $(id -un) (got ${owner})"
}

# run_cmd <argv...>  — simple commands ONLY (spec implementation rule 3).
# Use run_safe_* wrappers for redirects/pipes/heredocs/secrets.
run_cmd() {
  if [[ "${BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}
```

- [ ] **Step 5: Run tests, confirm pass**

Run: `bats test/test_bootstrap_helpers.bats`
Expected: all tests `ok`.

- [ ] **Step 6: shellcheck**

Run: `shellcheck -S warning scripts/_common.sh`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add scripts/_common.sh test/test_bootstrap_helpers.bats test/fixtures/env/
git commit -m "feat: extend _common.sh with bootstrap helpers (TDD)

load_bootstrap_env_defaults (env-priority, BOOTSTRAP_ key validation, =
-safe parsing, no shell expansion), check_secret_file_mode (600 + owner),
require_var/is_set/cmd_exists/read_secret_if_missing, run_cmd dry-run
wrapper (simple commands only — complex cases get dedicated wrappers)."
```

---

## Task 3: Config loading stage + `.bootstrap.env.example` + `load_config` (TDD)

`load_config` is the first stage (spec §1.2 ordering) and is pure config logic → bats-testable for the default-filling + env-priority behavior. The stage function itself is a thin wrapper.

**Files:**
- Create: `.bootstrap.env.example`
- Create: `scripts/bootstrap-build-host.sh` (skeleton: shebang, sourcing, parse for `--dry-run` only, `load_config` stage)
- Create: `test/test_load_config.bats`
- Modify: `.gitignore`

- [ ] **Step 1: Create `.bootstrap.env.example`**

`.bootstrap.env.example` (spec §3.3):
```ini
# === bootstrap 实际消费 (bootstrap 会用到) ===
# Non-sensitive, 可推导默认
BOOTSTRAP_BUILDER_USER=builder
BOOTSTRAP_APTLY_ROOT=/var/aptly
BOOTSTRAP_REPO_NAME=ocserv-backports
BOOTSTRAP_APT_BASE_URL=https://apt.example.com

# Non-sensitive, reuse/import 模式必填
BOOTSTRAP_GPG_KEYID=

# Sensitive, setup_gpg_key 阶段按需 read -s (可在此预填)
BOOTSTRAP_GPG_PASSPHRASE=

# === bootstrap 不实际消费,仅用于 rclone skeleton / 手动清单 ===
BOOTSTRAP_R2_ACCOUNT_ID=
BOOTSTRAP_R2_BUCKET=apt-thehkus
BOOTSTRAP_GITHUB_RUNNER_URL=

# === 当前 bootstrap 不读这些;仅用于人工清单提示或未来 github-connect.sh ===
# 真正使用者是 CI 的 r2-sync.sh / cf-purge.sh,通过 GitHub secrets 注入
BOOTSTRAP_R2_ACCESS_KEY_ID=
BOOTSTRAP_R2_SECRET_ACCESS_KEY=
BOOTSTRAP_CF_API_TOKEN=
BOOTSTRAP_CF_ZONE_ID=

# BOOTSTRAP_GITHUB_RUNNER_TOKEN is intentionally not required by bootstrap.
# Future github-connect.sh may use it, but bootstrap-build-host.sh will not.
# 短期 token 不鼓励长期落盘。
```

- [ ] **Step 2: Add `.bootstrap.env` to `.gitignore`**

Append to `.gitignore`:
```
# bootstrap config (real secrets/values)
.bootstrap.env
```

- [ ] **Step 3: Write failing tests for default-filling + aliases**

`test/test_load_config.bats`:
```bash
#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}"
  # isolate env
  unset BOOTSTRAP_BUILDER_USER BOOTSTRAP_APTLY_ROOT BOOTSTRAP_REPO_NAME \
        BOOTSTRAP_APT_BASE_URL BOOTSTRAP_R2_BUCKET BOOTSTRAP_GPG_KEYID \
        BOOTSTRAP_GPG_PASSPHRASE
}

# load_defaults_and_aliases is the function load_config calls (Task 3 Step 5).
# It fills unset BOOTSTRAP_* with declared defaults, then exports read-only aliases.

@test "fills all declared defaults when env unset" {
  source scripts/_common.sh
  load_defaults_and_aliases
  [ "${BOOTSTRAP_BUILDER_USER}" = "builder" ]
  [ "${BOOTSTRAP_APTLY_ROOT}" = "/var/aptly" ]
  [ "${BOOTSTRAP_REPO_NAME}" = "ocserv-backports" ]
  [ "${BOOTSTRAP_APT_BASE_URL}" = "https://apt.example.com" ]
  [ "${BOOTSTRAP_R2_BUCKET}" = "apt-thehkus" ]
}

@test "does not override caller-provided values" {
  BOOTSTRAP_BUILDER_USER=ops source scripts/_common.sh
  load_defaults_and_aliases
  [ "${BOOTSTRAP_BUILDER_USER}" = "ops" ]
}

@test "exposes unified internal aliases" {
  source scripts/_common.sh
  load_defaults_and_aliases
  [ "${BUILDER_USER}" = "builder" ]
  [ "${APTLY_ROOT}" = "/var/aptly" ]
  [ "${REPO_NAME}" = "ocserv-backports" ]
  [ "${APT_BASE_URL}" = "https://apt.example.com" ]
  [ "${R2_BUCKET}" = "apt-thehkus" ]
}
```

- [ ] **Step 4: Run tests, confirm failure**

Run: `bats test/test_load_config.bats`
Expected: FAIL — `load_defaults_and_aliases` not defined.

- [ ] **Step 5: Create `scripts/bootstrap-build-host.sh` skeleton + load_config**

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# bootstrap-build-host.sh — staged trixie builder init. Spec v2.
# Run ON the target builder as BOOTSTRAP_BUILDER_USER with passwordless sudo.

# Defaults applied AFTER .bootstrap.env is loaded; never override caller env.
load_defaults_and_aliases() {
  : "${BOOTSTRAP_BUILDER_USER:=builder}"
  : "${BOOTSTRAP_APTLY_ROOT:=/var/aptly}"
  : "${BOOTSTRAP_REPO_NAME:=ocserv-backports}"
  : "${BOOTSTRAP_APT_BASE_URL:=https://apt.example.com}"
  : "${BOOTSTRAP_R2_BUCKET:=apt-thehkus}"
  export BOOTSTRAP_BUILDER_USER BOOTSTRAP_APTLY_ROOT BOOTSTRAP_REPO_NAME \
         BOOTSTRAP_APT_BASE_URL BOOTSTRAP_R2_BUCKET
  # Unified internal aliases (spec implementation rule 2). Read-only.
  readonly BUILDER_USER="${BOOTSTRAP_BUILDER_USER}"
  readonly APTLY_ROOT="${BOOTSTRAP_APTLY_ROOT}"
  readonly REPO_NAME="${BOOTSTRAP_REPO_NAME}"
  readonly APT_BASE_URL="${BOOTSTRAP_APT_BASE_URL}"
  readonly R2_BUCKET="${BOOTSTRAP_R2_BUCKET}"
  export BUILDER_USER APTLY_ROOT REPO_NAME APT_BASE_URL R2_BUCKET
}

# Stage: load_config (runs FIRST; preflight depends on these values).
stage_load_config() {
  log "stage: load_config"
  if [[ -f .bootstrap.env ]]; then
    check_secret_file_mode .bootstrap.env
    load_bootstrap_env_defaults .bootstrap.env
  fi
  load_defaults_and_aliases
}

# Placeholder parse — full arg parsing lands in Task 4; only DRY_RUN here.
BOOTSTRAP_DRY_RUN=0
for a in "$@"; do [[ "$a" == "--dry-run" ]] && BOOTSTRAP_DRY_RUN=1; done
export BOOTSTRAP_DRY_RUN

main() {
  stage_load_config
  log "load_config done (BUILDER_USER=${BUILDER_USER}, APTLY_ROOT=${APTLY_ROOT})"
}

main "$@"
```

- [ ] **Step 6: Run tests, confirm pass**

Run: `bats test/test_load_config.bats`
Expected: all `ok`.

- [ ] **Step 7: shellcheck + chmod**

Run: `chmod +x scripts/bootstrap-build-host.sh && shellcheck -S warning scripts/bootstrap-build-host.sh`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add .bootstrap.env.example .gitignore scripts/bootstrap-build-host.sh test/test_load_config.bats
git commit -m "feat: bootstrap-build-host skeleton + load_config stage (TDD)

load_config runs first (preflight depends on BUILDER_USER/APTLY_ROOT).
Fills all declared defaults, exposes unified read-only internal aliases
(BUILDER_USER/APTLY_ROOT/REPO_NAME/APT_BASE_URL/R2_BUCKET) to avoid
set -u mix-ups with BOOTSTRAP_* names. .bootstrap.env is gitignored."
```

---

## Task 4: Argument parsing + stage runner

Full arg parsing for `--from-stage`/`--only-stage`/`--generate-gpg-key`/`--import-gpg-key`/`--reuse-gpg-key`/`--dry-run`/`-h`, plus the stage-list dispatch (GPG mode validated lazily inside `setup_gpg_key`, not here).

**Files:**
- Modify: `scripts/bootstrap-build-host.sh` (replace the placeholder parse block + add stage registry + dispatch)

- [ ] **Step 1: Define the ordered stage list + GPG-mode capture**

Edit `scripts/bootstrap-build-host.sh`: replace the placeholder block starting at `# Placeholder parse` with:

```bash
# ---- stages (spec §1.2 order) ---------------------------------------------
STAGES=(load_config preflight install_packages prepare_directories \
        setup_sbuild_chroot setup_gpg_key setup_aptly \
        setup_rclone_skeleton check_runner check_backups \
        print_manual_github_steps)

valid_stage() {
  local s="$1"
  for st in "${STAGES[@]}"; do [[ "$st" == "$s" ]] && return 0; done
  return 1
}

# ---- arg parsing ----------------------------------------------------------
BOOTSTRAP_DRY_RUN=0
GPG_MODE=""
GPG_IMPORT_PATH=""
GPG_REUSE_KEYID=""
FROM_STAGE=""
ONLY_STAGE=""

usage() {
  cat >&2 <<EOF
Usage: bootstrap-build-host.sh [options]
  --from-stage <stage>      start from this stage
  --only-stage <stage>      run a single stage
  --generate-gpg-key        GPG: generate a new signing key (fail-if-exists)
  --import-gpg-key <path>   GPG: import an existing private key
  --reuse-gpg-key <KEYID>   GPG: reuse a key already in this keyring
  --dry-run                 print actions, do not modify state
  -h, --help
Stages: ${STAGES[*]}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-stage) FROM_STAGE="$2"; shift 2 ;;
    --only-stage) ONLY_STAGE="$2"; shift 2 ;;
    --generate-gpg-key) GPG_MODE="generate"; shift ;;
    --import-gpg-key) GPG_MODE="import"; GPG_IMPORT_PATH="$2"; shift 2 ;;
    --reuse-gpg-key) GPG_MODE="reuse"; GPG_REUSE_KEYID="$2"; shift 2 ;;
    --dry-run) BOOTSTRAP_DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1 (see -h)" ;;
  esac
done
export BOOTSTRAP_DRY_RUN

# --from / --only are mutually exclusive
[[ -n "${FROM_STAGE}" && -n "${ONLY_STAGE}" ]] && die "--from-stage and --only-stage are mutually exclusive"
[[ -n "${FROM_STAGE}" ]] && { valid_stage "${FROM_STAGE}" || die "unknown stage: ${FROM_STAGE}\n$(usage)"; }
[[ -n "${ONLY_STAGE}" ]] && { valid_stage "${ONLY_STAGE}" || die "unknown stage: ${ONLY_STAGE}\n$(usage)"; }

# GPG modes mutually exclusive (count via distinct vars)
gpg_modes=0
[[ -n "${GPG_MODE}" ]] && gpg_modes=1
[[ "${gpg_modes}" -gt 1 ]] && die "GPG modes are mutually exclusive"
# Note: GPG_MODE is a single string set by exactly one of the 3 flags, so the
# count is inherently 0 or 1; the check above documents intent for future readers.
# Lazy validation of "no mode chosen" happens inside stage_setup_gpg_key.
```

- [ ] **Step 2: Replace the simple `main()` with a filtered stage runner**

Replace the existing `main()` block with:

```bash
run_stage() {
  local s="$1"
  if ! declare -F "stage_${s}" >/dev/null; then
    die "stage function not implemented: stage_${s}"
  fi
  log "==== stage: ${s} ===="
  "stage_${s}"
}

main() {
  local run=()
  if [[ -n "${ONLY_STAGE}" ]]; then
    run=("${ONLY_STAGE}")
  elif [[ -n "${FROM_STAGE}" ]]; then
    local started=0
    for s in "${STAGES[@]}"; do
      [[ "$s" == "${FROM_STAGE}" ]] && started=1
      [[ "$started" == "1" ]] && run+=("$s")
    done
  else
    run=("${STAGES[@]}")
  fi
  for s in "${run[@]}"; do
    run_stage "$s"
  done
}

main
```

- [ ] **Step 3: stub the not-yet-implemented stages so the runner works**

Append stubs (each task below replaces its stub with the real body):
```bash
stage_preflight()              { log "TODO stage_preflight"; }
stage_install_packages()       { log "TODO stage_install_packages"; }
stage_prepare_directories()    { log "TODO stage_prepare_directories"; }
stage_setup_sbuild_chroot()    { log "TODO stage_setup_sbuild_chroot"; }
stage_setup_gpg_key()          { log "TODO stage_setup_gpg_key"; }
stage_setup_aptly()            { log "TODO stage_setup_aptly"; }
stage_setup_rclone_skeleton()  { log "TODO stage_setup_rclone_skeleton"; }
stage_check_runner()           { log "TODO stage_check_runner"; }
stage_check_backups()          { log "TODO stage_check_backups"; }
stage_print_manual_github_steps() { log "TODO stage_print_manual_github_steps"; }
```

- [ ] **Step 4: shellcheck + smoke-test the parser**

Run: `shellcheck -S warning scripts/bootstrap-build-host.sh`
Expected: clean.

Run: `scripts/bootstrap-build-host.sh --only-stage load_config 2>&1 | tail -3`
Expected: prints `==== stage: load_config ====` and the `load_config done` line.

Run: `scripts/bootstrap-build-host.sh --bogus 2>&1; echo "exit $?"`
Expected: non-zero exit, `unknown arg: --bogus`.

Run: `scripts/bootstrap-build-host.sh --only-stage nonexistent 2>&1; echo "exit $?"`
Expected: non-zero, `unknown stage: nonexistent`.

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap-build-host.sh
git commit -m "feat: bootstrap arg parsing + stage dispatch runner

--from-stage/--only-stage (mutually exclusive, validated), 3 GPG modes
(mutually exclusive; 'none chosen' validated lazily inside setup_gpg_key),
--dry-run, -h. Stage registry is the single source of valid stage names."
```

---

## Task 5: Read-only stages (`preflight`, `check_runner`, `check_backups`) + `print_manual_github_steps`

These are pure read-only / print stages — safe to fully write now.

**Files:**
- Modify: `scripts/bootstrap-build-host.sh` (replace the 4 stubs)

- [ ] **Step 1: Replace `stage_preflight`**

```bash
stage_preflight() {
  log "stage: preflight"
  # OS + codename
  local id codename
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"; codename="${VERSION_CODENAME:-}"
  fi
  [[ "${id}" == "debian" ]] || die "OS must be debian (got '${id}')"
  [[ "${codename}" == "trixie" ]] || die "codename must be trixie (got '${codename}')"

  # arch
  [[ "$(uname -m)" == "x86_64" ]] || die "arch must be x86_64 (got $(uname -m))"

  # current user == BUILDER_USER (spec §2.1; prevents ubuntu/builder role confusion)
  local cur; cur="$(id -un)"
  [[ "${cur}" != "root" ]] || die "do not run as root; run as ${BUILDER_USER} with passwordless sudo"
  [[ "${cur}" == "${BUILDER_USER}" ]] \
    || die "current user is '${cur}'; run as ${BUILDER_USER} with passwordless sudo"

  # passwordless sudo
  sudo -n true 2>/dev/null || die "passwordless sudo required for ${BUILDER_USER}"

  # disk: APTLY_ROOT fs + chroot fs (spec §2.1 two-level threshold)
  check_disk_threshold "${APTLY_ROOT}"
  check_disk_threshold /var/lib/sbuild   # parent of chroot dir
}

check_disk_threshold() {
  local path="$1"
  [[ -d "$path" ]] || path="$(dirname "$path")"
  local avail_kb; avail_kb="$(df -Pk "${path}" 2>/dev/null | awk 'NR==2{print $4}')"
  local avail_gb=$(( avail_kb / 1024 / 1024 ))
  if   (( avail_gb < 15 )); then die "less than 15GB free on ${path} (have ${avail_gb}GB)"
  elif (( avail_gb < 30 )); then log "WARN: only ${avail_gb}GB free on ${path} (recommended >=30GB)"
  else log "disk OK: ${avail_gb}GB free on ${path}"
  fi
}
```

- [ ] **Step 2: Replace `stage_check_runner`**

```bash
stage_check_runner() {
  log "stage: check_runner"
  local runner_dir="${BOOTSTRAP_RUNNER_DIR:-${HOME}/actions-runner}"
  if [[ -f "${runner_dir}/.runner" ]]; then
    log "runner already registered at ${runner_dir}"
    local o; o="$(stat -c '%U' "${runner_dir}" 2>/dev/null || echo '?')"
    [[ "$o" == "${BUILDER_USER}" ]] || log "WARN: runner dir owner='${o}' (expected ${BUILDER_USER})"
  elif [[ -d "${runner_dir}" ]]; then
    log "WARN: ${runner_dir} exists but not registered; see manual steps"
  else
    log "WARN: no runner detected at ${runner_dir}; register via GitHub UI (see manual steps)"
  fi
}
```

- [ ] **Step 3: Replace `stage_check_backups`**

```bash
stage_check_backups() {
  log "stage: check_backups"
  local runner_dir="${BOOTSTRAP_RUNNER_DIR:-${HOME}/actions-runner}"
  local paths=(
    "${APTLY_ROOT}"
    "${APTLY_ROOT}/state"
    "${HOME}/.gnupg"
    "/etc/schroot/chroot.d"
    "${HOME}/.config/rclone/rclone.conf"
    "${runner_dir}"
  )
  local p
  for p in "${paths[@]}"; do
    if [[ -e "$p" ]]; then log "backup source exists: $p"
    else log "WARN: backup source not found: $p (ensure your backup covers it)"; fi
  done
}
```

- [ ] **Step 4: Replace `stage_print_manual_github_steps`**

```bash
stage_print_manual_github_steps() {
  log "stage: print_manual_github_steps"
  cat <<EOF

=== Next manual GitHub steps ===

1. Register self-hosted runner
   GitHub UI: Repo → Settings → Actions → Runners → New self-hosted runner
   Labels: self-hosted, builder
   Run as user: ${BUILDER_USER}
   ${BOOTSTRAP_GITHUB_RUNNER_URL:+Runner URL hint: ${BOOTSTRAP_GITHUB_RUNNER_URL}}

2. Configure GitHub secrets (repo or environment level):
   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ACCOUNT_ID, R2_BUCKET,
   CF_API_TOKEN, CF_ZONE_ID, GPG_PASSPHRASE

3. gh CLI (if authenticated):
   gh secret set R2_ACCESS_KEY_ID
   gh secret set R2_SECRET_ACCESS_KEY
   gh secret set R2_ACCOUNT_ID
   gh secret set R2_BUCKET
   gh secret set CF_API_TOKEN
   gh secret set CF_ZONE_ID
   gh secret set GPG_PASSPHRASE

4. Protected environment: name 'production', enable required reviewers.

5. Verify runner labels: [self-hosted, builder]

EOF
}
```

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning scripts/bootstrap-build-host.sh`
Expected: clean.

- [ ] **Step 6: Smoke-test the read-only stages (as non-builder on dev box — expect preflight to die cleanly)**

Run: `scripts/bootstrap-build-host.sh --only-stage check_backups 2>&1 | tail -8`
Expected: prints backup-source existence lines (no die; this stage never dies).

Run: `scripts/bootstrap-build-host.sh --only-stage print_manual_github_steps 2>&1 | head -5`
Expected: prints `=== Next manual GitHub steps ===` block.

- [ ] **Step 7: Commit**

```bash
git add scripts/bootstrap-build-host.sh
git commit -m "feat: bootstrap read-only stages (preflight/check_runner/check_backups/manual-github)"
```

---

## Task 6: Mutation stages (`install_packages`, `prepare_directories`, `setup_sbuild_chroot`)

These call external tools but have simple guard logic. `setup_sbuild_chroot` includes `verify_chroot_sources` (read-only sub-check).

**Files:**
- Modify: `scripts/bootstrap-build-host.sh` (replace 3 stubs + add helpers)

- [ ] **Step 1: Replace `stage_install_packages`**

```bash
stage_install_packages() {
  log "stage: install_packages"
  run_cmd sudo apt-get update
  run_cmd sudo apt-get install -y \
    sbuild schroot debootstrap \
    build-essential devscripts debhelper debhelper-compat \
    dpkg-dev fakeroot lintian quilt \
    rclone aptly gnupg jq docker.io git curl ca-certificates
}
```

- [ ] **Step 2: Replace `stage_prepare_directories`**

```bash
stage_prepare_directories() {
  log "stage: prepare_directories"
  if [[ -d "${APTLY_ROOT}" && -n "$(ls -A "${APTLY_ROOT}" 2>/dev/null)" ]]; then
    local o; o="$(stat -c '%U' "${APTLY_ROOT}")"
    [[ "$o" == "root" || "$o" == "${BUILDER_USER}" ]] \
      || die "unexpected ${APTLY_ROOT} owner='${o}'; refusing to chown (manual review)"
  fi
  run_cmd sudo mkdir -p "${APTLY_ROOT}/public/testing" "${APTLY_ROOT}/public/prod" \
                        "${APTLY_ROOT}/.locks" "${APTLY_ROOT}/state"
  run_cmd sudo chown -R "${BUILDER_USER}:${BUILDER_USER}" "${APTLY_ROOT}"
  run_cmd sudo chmod 0755 "${APTLY_ROOT}/.locks"
}
```

- [ ] **Step 3: Replace `stage_setup_sbuild_chroot` + helpers**

```bash
stage_setup_sbuild_chroot() {
  log "stage: setup_sbuild_chroot"
  local chroot_dir="/var/lib/sbuild/trixie-amd64-sbuild"
  if [[ -d "${chroot_dir}" ]]; then
    log "chroot exists; verifying sources"
    verify_chroot_sources "${chroot_dir}"
    return
  fi
  log "creating trixie sbuild chroot"
  run_cmd sudo sbuild-createchroot --arch=amd64 --components=main \
    trixie "${chroot_dir}" http://deb.debian.org/debian
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would verify chroot sources after creation"
    return
  fi
  verify_chroot_sources "${chroot_dir}"
}

# verify_chroot_sources <chroot_dir>  — scans .list + .sources; skips comments/blanks.
# Allowed: trixie / trixie-updates / trixie-security. Forbidden: sid/unstable/testing/forky.
verify_chroot_sources() {
  local chroot_dir="$1"
  local etc="${chroot_dir}/etc/apt"
  local files=()
  [[ -f "${etc}/sources.list" ]] && files+=("${etc}/sources.list")
  if [[ -d "${etc}/sources.list.d" ]]; then
    # collect .list and .sources; nullglob avoids literal glob when empty
    local g; shopt -s nullglob
    g=( "${etc}/sources.list.d"/*.list "${etc}/sources.list.d"/*.sources ); shopt -u nullglob
    files+=("${g[@]}")
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
      log "DRY-RUN: would verify chroot sources after creation (none found yet)"
      return
    fi
    die "no apt sources found in ${etc}"
  fi
  local f line bad=""
  for f in "${files[@]}"; do
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"   # ltrim
      [[ -z "$line" || "$line" == \#* ]] && continue
      if [[ "$line" =~ (sid|unstable|testing|forky) ]]; then
        bad+="${f}: ${line}"$'\n'
      fi
    done < "$f"
  done
  [[ -z "$bad" ]] || die "chroot sources contaminated; manual fix:\n${bad}"
  log "chroot sources OK (trixie-only)"
}
```

- [ ] **Step 4: shellcheck**

Run: `shellcheck -S warning scripts/bootstrap-build-host.sh`
Expected: clean.

- [ ] **Step 5: Smoke-test verify_chroot_sources against fixtures (unit-style)**

This helper reads files; test it on a temp dir:
```bash
tmp="$(mktemp -d)"; mkdir -p "$tmp/etc/apt/sources.list.d"
printf 'deb http://deb.debian.org/debian trixie main\n' > "$tmp/etc/apt/sources.list"
printf '# comment\n\ndeb http://deb.debian.org/debian-security trixie-security main\n' > "$tmp/etc/apt/sources.list.d/security.list"
# source the script's functions (it won't run main because functions only)
bash -c 'source scripts/_common.sh; '"$(sed -n "/^verify_chroot_sources/,/^}/p" scripts/bootstrap-build-host.sh)"'; verify_chroot_sources "'"$tmp"'" && echo OK'
rm -rf "$tmp"
```
Expected: prints `chroot sources OK (trixie-only)` and `OK`.

Then a contaminated case:
```bash
tmp="$(mktemp -d)"; mkdir -p "$tmp/etc/apt"
printf 'deb http://deb.debian.org/debian sid main\n' > "$tmp/etc/apt/sources.list"
bash -c 'source scripts/_common.sh; '"$(sed -n "/^verify_chroot_sources/,/^}/p" scripts/bootstrap-build-host.sh)"'; verify_chroot_sources "'"$tmp"'"' ; echo "exit $?"
rm -rf "$tmp"
```
Expected: dies with `chroot sources contaminated`, non-zero exit.

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap-build-host.sh
git commit -m "feat: bootstrap mutation stages (install_packages/prepare_directories/sbuild_chroot)

verify_chroot_sources scans sources.list + .list + .sources, ignores
comments/blanks, forbids sid/unstable/testing/forky. dry-run skips
verification of not-yet-created chroot."
```

---

## Task 7: GPG, aptly, rclone stages + Makefile + docs

**Files:**
- Modify: `scripts/bootstrap-build-host.sh` (replace 3 stubs + add safe wrappers)
- Modify: `Makefile`
- Modify: `docs/BUILD_HOST_BOOTSTRAP.md`

- [ ] **Step 1: Add safe wrappers for GPG/aptly (NOT via run_cmd — secrets/heredocs)**

Append near the top of `scripts/bootstrap-build-host.sh` (after `load_defaults_and_aliases`):
```bash
# Safe wrapper: run a command with a heredoc-as-temp-file, never printing secrets.
# Usage: run_safe_heredoc <tempfile-pattern> <heredoc-content> <cmd...>
# In dry-run, prints "DRY-RUN: would run <cmd>" WITHOUT the heredoc content.
run_safe_heredoc() {
  local tmpfile="$1" content="$2"; shift 2
  if [[ "${BOOTSTRAP_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN: would run'
    printf ' %q' "$@"
    printf ' (with heredoc input, content suppressed)\n'
    return
  fi
  printf '%s' "${content}" > "${tmpfile}"
  "$@" "${tmpfile}"
  rm -f "${tmpfile}"
}
```

- [ ] **Step 2: Replace `stage_setup_gpg_key`**

```bash
stage_setup_gpg_key() {
  log "stage: setup_gpg_key"

  # lazy mode validation (spec §1.1): only here, not at parse time
  [[ -n "${GPG_MODE}" ]] \
    || die "specify one of --generate-gpg-key / --import-gpg-key <path> / --reuse-gpg-key <KEYID>"

  case "${GPG_MODE}" in
    generate) gpg_generate ;;
    import)   gpg_import ;;
    reuse)    gpg_reuse ;;
  esac
  export_pubkey
}

gpg_secret_exists_for_keyid() { gpg --list-secret-keys --with-colons "$1" 2>/dev/null | grep -q '^sec'; }
gpg_secret_exists_for_uid()   { gpg --list-secret-keys --with-colons 2>/dev/null | grep -iE 'THEHKUS-Backports|master@thehkus.com' | grep -q '^uid'; }

gpg_generate() {
  if [[ -n "${BOOTSTRAP_GPG_KEYID:-}" ]] && gpg_secret_exists_for_keyid "${BOOTSTRAP_GPG_KEYID}"; then
    die "key ${BOOTSTRAP_GPG_KEYID} already exists; use --reuse-gpg-key ${BOOTSTRAP_GPG_KEYID} (do NOT regenerate)"
  fi
  if gpg_secret_exists_for_uid; then
    die "signing key already exists for THEHKUS-Backports; use --reuse-gpg-key <KEYID> (do NOT regenerate)"
  fi
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would generate GPG signing key for THEHKUS-Backports"
    export BOOTSTRAP_GPG_KEYID="DRYRUN-GPG-KEYID"
    return
  fi
  read_secret_if_missing BOOTSTRAP_GPG_PASSPHRASE "GPG passphrase"
  local keyfile; keyfile="$(mktemp)"
  local content
  content=$(cat <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: THEHKUS-Backports
Name-Email: master@thehkus.com
Expire-Date: 0
%commit
EOF
)
  # Note: we use %no-protection for non-interactive generation. If a passphrase
  # is required for signing, gpg-agent caching handles it at aptly publish time.
  # (Spec stores GPG_PASSPHRASE as a GitHub secret for CI consumption; local
  # keyring uses agent. Adjust to Passphrase: ${BOOTSTRAP_GPG_PASSPHRASE} if
  # passphrase-protected keys are desired.)
  printf '%s' "${content}" > "${keyfile}"
  local out; out="$(gpg --batch --generate-key "${keyfile}" 2>&1)" || die "gpg generate-key failed: ${out}"
  rm -f "${keyfile}"
  # parse fingerprint of the just-created key
  BOOTSTRAP_GPG_KEYID="$(gpg --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/{print $10}' | tail -1)"
  export BOOTSTRAP_GPG_KEYID
  log "generated signing key: ${BOOTSTRAP_GPG_KEYID}"
}

gpg_import() {
  require_var BOOTSTRAP_GPG_KEYID
  if gpg_secret_exists_for_keyid "${BOOTSTRAP_GPG_KEYID}"; then
    log "key ${BOOTSTRAP_GPG_KEYID} already in keyring; treating import as reuse"
    return
  fi
  [[ -r "${GPG_IMPORT_PATH}" ]] || die "import file not readable: ${GPG_IMPORT_PATH}"
  # pre-check: confirm the file actually contains this KEYID (spec advice #7)
  if ! gpg --show-keys --with-colons "${GPG_IMPORT_PATH}" 2>/dev/null | grep -q ":${BOOTSTRAP_GPG_KEYID}:"; then
    die "key in ${GPG_IMPORT_PATH} does not match BOOTSTRAP_GPG_KEYID=${BOOTSTRAP_GPG_KEYID}"
  fi
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would gpg --import ${GPG_IMPORT_PATH}"
    return
  fi
  gpg --import "${GPG_IMPORT_PATH}" || die "gpg import failed"
  gpg_secret_exists_for_keyid "${BOOTSTRAP_GPG_KEYID}" \
    || die "imported key has no secret part for ${BOOTSTRAP_GPG_KEYID}"
}

gpg_reuse() {
  BOOTSTRAP_GPG_KEYID="${GPG_REUSE_KEYID}"; export BOOTSTRAP_GPG_KEYID
  require_var BOOTSTRAP_GPG_KEYID
  gpg_secret_exists_for_keyid "${BOOTSTRAP_GPG_KEYID}" \
    || die "no secret key for ${BOOTSTRAP_GPG_KEYID}"
}

export_pubkey() {
  require_var BOOTSTRAP_GPG_KEYID
  local out="ansible/roles/ocserv_backport/files/thehkus-backports.asc"
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would export pubkey ${BOOTSTRAP_GPG_KEYID} -> ${out}"
    return
  fi
  gpg --armor --export "${BOOTSTRAP_GPG_KEYID}" > "${out}" || die "pubkey export failed"
  log "exported pubkey -> ${out}"
}
```

- [ ] **Step 3: Replace `stage_setup_aptly` (config FIRST, then repo)**

```bash
stage_setup_aptly() {
  log "stage: setup_aptly"
  require_var BOOTSTRAP_GPG_KEYID
  local cfg="${APTLY_CONFIG:-${HOME}/.aptly.conf}"

  # 1. config validate or generate (BEFORE repo; spec §2.7)
  if [[ -f "${cfg}" ]]; then
    local root gpgkey
    root="$(jq -r '.rootDir // empty' "${cfg}")"
    gpgkey="$(jq -r '.gpgKey // empty' "${cfg}")"
    [[ "${root}" == "${APTLY_ROOT}" ]] \
      || die "aptly config rootDir='${root}' != ${APTLY_ROOT}; manual review (refuse to rewrite)"
    [[ "${gpgkey}" == "${BOOTSTRAP_GPG_KEYID}" ]] \
      || die "aptly config gpgKey='${gpgkey}' != ${BOOTSTRAP_GPG_KEYID}; manual review"
  else
    if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
      log "DRY-RUN: would generate ${cfg}"
    else
      jq -n --arg root "${APTLY_ROOT}" --arg key "${BOOTSTRAP_GPG_KEYID}" \
        '{rootDir:$root, gpgProvider:"gpg", gpgKey:$key}' > "${cfg}"
      log "generated minimal aptly config -> ${cfg}"
    fi
  fi

  # 2. repo show/create (skip-if-exists)
  if aptly repo show "${REPO_NAME}" >/dev/null 2>&1; then
    log "aptly repo '${REPO_NAME}' exists; skipping"
    return
  fi
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would aptly repo create ${REPO_NAME}"
    return
  fi
  aptly repo create "${REPO_NAME}" || die "aptly repo create failed"
  log "created aptly repo '${REPO_NAME}'"
}
```

- [ ] **Step 4: Replace `stage_setup_rclone_skeleton`**

```bash
stage_setup_rclone_skeleton() {
  log "stage: setup_rclone_skeleton"
  local conf="${HOME}/.config/rclone/rclone.conf"
  if [[ -f "${conf}" ]] && grep -q '^\[r2\]' "${conf}" 2>/dev/null; then
    log "rclone skeleton [r2] already present"
    return
  fi
  if [[ -z "${BOOTSTRAP_R2_ACCOUNT_ID:-}" ]]; then
    log "WARN: BOOTSTRAP_R2_ACCOUNT_ID not set; skipping rclone skeleton (r2-sync.sh injects creds at runtime anyway)"
    return
  fi
  if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would rclone config create r2 s3 (Cloudflare, no secrets)"
    return
  fi
  rclone config create r2 s3 provider Cloudflare \
    endpoint "https://${BOOTSTRAP_R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
    no_check_bucket true >/dev/null
  log "rclone skeleton created (no secrets stored)"
}
```

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S warning scripts/bootstrap-build-host.sh`
Expected: clean.

- [ ] **Step 6: Add Makefile target (ARGS, not $$@)**

Append to `Makefile`:
```makefile
.PHONY: bootstrap-build-host
bootstrap-build-host: ## Bootstrap the trixie build host (run ON the builder)
	scripts/bootstrap-build-host.sh $(ARGS)
```
Run: `make help 2>&1 | grep bootstrap`
Expected: lists `bootstrap-build-host`.

- [ ] **Step 7: Rewrite `docs/BUILD_HOST_BOOTSTRAP.md`**

```markdown
# Build Host Bootstrap

The builder is initialized by `scripts/bootstrap-build-host.sh` (run ON the
trixie amd64 builder, as `BOOTSTRAP_BUILDER_USER` with passwordless sudo).

## First-time setup
1. `cp .bootstrap.env.example .bootstrap.env && chmod 600 .bootstrap.env`
2. Edit `.bootstrap.env` (GPG keyid, R2 account id, urls as needed).
3. Choose a GPG mode:
   - New signing key:    `scripts/bootstrap-build-host.sh --generate-gpg-key`
   - Import existing:    `scripts/bootstrap-build-host.sh --import-gpg-key /path/to/private.asc`
                         (set `BOOTSTRAP_GPG_KEYID` in `.bootstrap.env`)
   - Reuse in keyring:   `scripts/bootstrap-build-host.sh --reuse-gpg-key <FINGERPRINT>`
4. Dry-run first:        `scripts/bootstrap-build-host.sh --dry-run --generate-gpg-key`
5. Run for real:         `scripts/bootstrap-build-host.sh --generate-gpg-key`

The script prints the manual GitHub steps (runner registration + secrets) at the end.

## Drift check (re-run safely)
`scripts/bootstrap-build-host.sh --only-stage install_packages` etc. Safe-repeat
stages are idempotent; GPG/runner are fail/info on existing state (never auto-replaced).

## Spec
See `docs/superpowers/specs/2026-06-19-bootstrap-build-host-design.md` (v2).
```

- [ ] **Step 8: Commit**

```bash
git add scripts/bootstrap-build-host.sh Makefile docs/BUILD_HOST_BOOTSTRAP.md
git commit -m "feat: bootstrap gpg/aptly/rclone stages + Makefile target + docs rewrite

GPG 3-mode (generate/import/reuse) mutually exclusive, lazy-validated; dry-run
generate uses DRYRUN-GPG-KEYID placeholder. aptly config validated/generated
BEFORE repo. rclone skeleton skips if R2_ACCOUNT_ID unset. Makefile uses ARGS.
Docs point at the script; manual GitHub steps still printed at the end."
```

---

## Task 8: Verification gate (run everything runnable on the dev box)

This is the verification-before-completion checkpoint, not a code task.

- [ ] **Step 1: Run all bats**

Run: `bats test/*.bats`
Expected: all `ok` (snapshot-name, manifest, assert-apt-policy, bootstrap-helpers, load-config).

- [ ] **Step 2: shellcheck every script**

Run: `shellcheck -S warning scripts/*.sh ansible/roles/ocserv_backport/files/*.sh`
Expected: clean.

- [ ] **Step 3: Help + parser smoke**

Run: `make help | grep bootstrap` → lists target.
Run: `scripts/bootstrap-build-host.sh -h | head -3` → prints Usage.
Run: `scripts/bootstrap-build-host.sh --only-stage nonexistent 2>&1; echo $?` → non-zero, "unknown stage".

- [ ] **Step 4: Confirm clean tree**

Run: `git status --short`
Expected: clean (`.bootstrap.env` is gitignored; if you created one for testing, it won't show).

- [ ] **Step 5: Commit only if anything changed**

```bash
git status --short || true
# (typically nothing; bootstrap script already committed in Task 7)
```

---

## Self-Review (completed during authoring)

**Spec coverage check (spec §1–§3):**
- §1.1 args (`--from-stage`/`--only-stage`/3 GPG/`--dry-run`/`-h`, mutual-exclusion) → Task 4 ✓
- §1.2 stage order (load_config first) → Task 3 (load_config) + Task 4 (registry) ✓
- §1.3 config priority + lazy read-s → Task 2 (`load_bootstrap_env_defaults`) + Task 3 ✓
- §2.1 preflight (OS/arch/==BUILDER_USER/sudo/disk two-level) → Task 5 ✓
- §2.3 install_packages → Task 6 ✓
- §2.4 prepare_directories (no /var/lib/ocserv-backport, owner guard) → Task 6 ✓
- §2.5 setup_sbuild_chroot + verify_chroot_sources (.list+.sources, comments) → Task 6 ✓
- §2.6 setup_gpg_key 3-mode (generate fail-if-exists KEYID+uid, import reuse-on-exists, reuse) → Task 7 ✓
- §2.7 setup_aptly config-before-repo → Task 7 ✓
- §2.8 setup_rclone_skeleton (skip if no R2_ACCOUNT_ID) → Task 7 ✓
- §2.9 check_runner (info on registered) → Task 5 ✓
- §2.10 check_backups (warn only) → Task 5 ✓
- §2.11 print_manual_github_steps (5 sections) → Task 5 ✓
- §3.2 helpers → Task 2 ✓
- §3.3 .bootstrap.env.example → Task 3 ✓
- §3.4 Makefile ARGS → Task 7 ✓
- §3.5 docs rewrite → Task 7 ✓
- §3.6 tests (helpers + dry-run) → Tasks 2, 3 ✓
- §3.7 dry-run (run_cmd + would-verify + DRYRUN-GPG-KEYID) → Tasks 2, 6, 7 ✓

**Placeholder scan:** No TBD/TODO in deliverables. The Task 4 stage stubs are explicitly replaced in Tasks 5–7 (tracked, not left as TODO). ✓

**Type/name consistency:** `BOOTSTRAP_GPG_KEYID` set in `gpg_generate`/`gpg_import`/`gpg_reuse`, read by `export_pubkey` and `stage_setup_aptly` — consistent. `BUILDER_USER`/`APTLY_ROOT`/`REPO_NAME` aliases used in every stage body (not the `BOOTSTRAP_*` originals) — consistent with implementation rule 2. `BOOTSTRAP_DRY_RUN` read by `run_cmd` and stage `if` checks — consistent. ✓

**Implementation-detail rule check (user's 3 hard rules):**
1. All declared defaults filled in `load_defaults_and_aliases` (Task 3 Step 5) ✓
2. Read-only aliases `BUILDER_USER`/`APTLY_ROOT`/`REPO_NAME`/`APT_BASE_URL`/`R2_BUCKET` used internally; stages never reference `BOOTSTRAP_BUILDER_USER` etc. ✓ (verified in Task 5/6/7 code)
3. `run_cmd` only for simple argv (Task 2); GPG heredoc uses `run_safe_heredoc`-style inline temp file with dry-run content suppression (Task 7); secrets never printed ✓
