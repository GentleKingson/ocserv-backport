# Build Pipeline Dependency Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `require_cmds()` helper to `_common.sh` and call it at the entry of 6 build-pipeline scripts so missing external commands fail fast with a precise command+package+fix message instead of an opaque `command not found`.

**Architecture:** A single shared helper in `_common.sh` (alongside the existing `die`/`log`/`cmd_exists` helpers) checks all `command:package` specs in one pass and reports every missing command at once. Each build-pipeline script calls it right after sourcing helpers, before any side effects.

**Tech Stack:** Bash, bats (testing). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-06-21-build-pipeline-dependency-check-design.md`

---

## File Structure

- **Modify** `scripts/_common.sh` — add `require_cmds()` helper after the existing `cmd_exists`/`is_set` block.
- **Modify** `scripts/fetch-source.sh` — insert `require_cmds` call after all `. _*.sh` sources (after line 16).
- **Modify** `scripts/prefetch-source.sh` — insert `require_cmds` call after all `. _*.sh` sources (after line 15).
- **Modify** `scripts/build-source-package.sh` — insert `require_cmds` call after `source _common.sh` (after line 3).
- **Modify** `scripts/build-binary.sh` — insert `require_cmds` call after `source _common.sh` (after line 3).
- **Modify** `scripts/lint-package.sh` — insert `require_cmds` call after `source _common.sh` (after line 3).
- **Modify** `scripts/rewrap-changelog.sh` — insert `require_cmds` call after `source _common.sh` (after line 3).
- **Create** `test/test_require_cmds.bats` — unit tests for the helper.

---

### Task 1: Add `require_cmds()` helper with failing tests (TDD)

**Files:**
- Create: `test/test_require_cmds.bats`
- Modify: `scripts/_common.sh` (after line 29, the `require_var` function)

- [ ] **Step 1: Write the failing tests**

Create `test/test_require_cmds.bats`:

```bash
#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() { cd "${REPO_ROOT}"; }

# Source _common.sh into a subshell and invoke require_cmds via a wrapper,
# since require_cmds is a function (not a standalone script). die() exits the
# subshell with status 1.
run_require() {
  run bash -c "set -euo pipefail; source '${REPO_ROOT}/scripts/_common.sh'; require_cmds \"\$@\"" _ "$@"
}

@test "require_cmds: all present -> exit 0, no output" {
  # ls (coreutils) and bash itself are guaranteed present on any test host.
  run_require ls:coreutils bash:bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "require_cmds: missing command -> die with package + fix guidance" {
  # zzz-not-a-real-cmd-xyz is guaranteed absent.
  run_require zzz-not-a-real-cmd-xyz:fakepkg ls:coreutils
  [ "$status" -ne 0 ]
  # multi-line message mentions the command, the package, and the fix.
  echo "$output" | grep -q "zzz-not-a-real-cmd-xyz"
  echo "$output" | grep -q "fakepkg"
  echo "$output" | grep -q "apt-get install"
  echo "$output" | grep -q "bootstrap-build-host"
}

@test "require_cmds: reports ALL missing commands at once, not just the first" {
  run_require zzz-missing-one:pkg-one zzz-missing-two:pkg-two ls:coreutils
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "zzz-missing-one"
  echo "$output" | grep -q "zzz-missing-two"
  echo "$output" | grep -q "pkg-one"
  echo "$output" | grep -q "pkg-two"
}

@test "require_cmds: no args -> exit 0 (defensive no-op)" {
  run_require
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail (helper not yet defined)**

Run: `bats test/test_require_cmds.bats`
Expected: FAIL — `require_cmds: command not found` (the function does not exist yet in `_common.sh`).

- [ ] **Step 3: Implement `require_cmds()` in `scripts/_common.sh`**

Insert this block immediately after the `require_var()` function (after line 29 of `scripts/_common.sh`, i.e. after the closing `}` of `require_var`):

```bash
# require_cmds <cmd:pkg> <cmd:pkg> ...  — die (reporting ALL missing) if any absent.
# Each arg is "command:debian-package". Reports every missing command in one
# message so the operator installs all gaps in a single pass (no fix-rerun loop).
# Usage: require_cmds dscverify:devscripts dpkg-source:dpkg-dev
require_cmds() {
  local missing=() pkgs=() c p
  for spec in "$@"; do
    c="${spec%%:*}"; p="${spec#*:}"
    command -v "$c" >/dev/null 2>&1 || { missing+=("$c"); pkgs+=("$p"); }
  done
  if (( ${#missing[@]} )); then
    die "missing commands: ${missing[*]}
  packages: ${pkgs[*]}
  fix: run 'make bootstrap-build-host' on the builder, or: sudo apt-get install -y ${pkgs[*]}"
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_require_cmds.bats`
Expected: PASS — all 4 tests green.

- [ ] **Step 5: Run full suite to confirm no regression**

Run: `bats test/`
Expected: PASS — all pre-existing tests still green.

- [ ] **Step 6: Commit**

```bash
git add scripts/_common.sh test/test_require_cmds.bats
git commit -m "feat(scripts): add require_cmds() dependency-check helper

Shared helper in _common.sh checks all command:package specs in one pass
and reports every missing command with package name + fix guidance. Replaces
opaque 'command not found' errors with precise, actionable output."
```

---

### Task 2: Wire `require_cmds` into `fetch-source.sh`

**Files:**
- Modify: `scripts/fetch-source.sh` (after line 16 — after the last `. _*.sh` source)

- [ ] **Step 1: Add the call**

In `scripts/fetch-source.sh`, immediately after line 16 (the `. "$SCRIPT_DIR/_cache_meta.sh"` line) and before line 18 (`REPO_ROOT=...`), insert:

```bash

# Fail fast if the builder is missing required commands (e.g. dscverify from
# devscripts when bootstrap-build-host.sh was not fully run). Spec
# docs/superpowers/specs/2026-06-21-build-pipeline-dependency-check-design.md
require_cmds \
  dscverify:devscripts \
  dpkg-source:dpkg-dev \
  curl:curl \
  sha256sum:coreutils \
  gpg:gnupg \
  quilt:quilt
```

- [ ] **Step 2: Verify existing fetch tests still pass**

Run: `bats test/test_fetch_source.bats`
Expected: PASS — `require_cmds` is a no-op on a host that already has these commands; the existing tests source the script and call internal functions, which now run the check harmlessly.

- [ ] **Step 3: Commit**

```bash
git add scripts/fetch-source.sh
git commit -m "feat(fetch-source): fail fast on missing build commands

Add require_cmds check for dscverify/dpkg-source/curl/sha256sum/gpg/quilt
at script entry, replacing opaque 'command not found' with package+fix."
```

---

### Task 3: Wire `require_cmds` into `prefetch-source.sh`

**Files:**
- Modify: `scripts/prefetch-source.sh` (after line 15 — after the last `. _*.sh` source)

- [ ] **Step 1: Add the call**

In `scripts/prefetch-source.sh`, immediately after line 15 (the `. "${SCRIPT_DIR}/_cache_meta.sh"` line) and before line 17 (`REPO_ROOT=...`), insert:

```bash

# Fail fast if the prefetch node is missing required commands.
require_cmds \
  dscverify:devscripts \
  dpkg-source:dpkg-dev \
  curl:curl \
  sha256sum:coreutils \
  gpg:gnupg
```

- [ ] **Step 2: Verify existing prefetch tests still pass**

Run: `bats test/test_prefetch_source.bats`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add scripts/prefetch-source.sh
git commit -m "feat(prefetch-source): fail fast on missing build commands

Add require_cmds check for dscverify/dpkg-source/curl/sha256sum/gpg."
```

---

### Task 4: Wire `require_cmds` into `build-source-package.sh`

**Files:**
- Modify: `scripts/build-source-package.sh` (after line 3)

- [ ] **Step 1: Add the call**

In `scripts/build-source-package.sh`, immediately after line 3 (`source "$(dirname "$0")/_common.sh"`) and before line 5 (the comment `# Spec §2.6...`), insert:

```bash

# Fail fast if the builder is missing required commands.
require_cmds \
  dpkg-buildpackage:dpkg-dev \
  sbuild:sbuild
```

- [ ] **Step 2: Verify no test directly exercises this script**

There is no dedicated `test_build_source_package.bats`. The check is exercised indirectly by CI. Confirm syntax loads cleanly:

Run: `bash -n scripts/build-source-package.sh`
Expected: no output (exit 0).

- [ ] **Step 3: Commit**

```bash
git add scripts/build-source-package.sh
git commit -m "feat(build-source-package): fail fast on missing build commands

Add require_cmds check for dpkg-buildpackage/sbuild."
```

---

### Task 5: Wire `require_cmds` into `build-binary.sh`

**Files:**
- Modify: `scripts/build-binary.sh` (after line 3)

- [ ] **Step 1: Add the call**

In `scripts/build-binary.sh`, immediately after line 3 (`source "$(dirname "$0")/_common.sh"`) and before line 5 (the comment `# Spec §2.7...`), insert:

```bash

# Fail fast if the builder is missing required commands.
require_cmds \
  sbuild:sbuild \
  lintian:lintian \
  schroot:schroot
```

- [ ] **Step 2: Verify syntax loads cleanly**

Run: `bash -n scripts/build-binary.sh`
Expected: no output (exit 0).

- [ ] **Step 3: Commit**

```bash
git add scripts/build-binary.sh
git commit -m "feat(build-binary): fail fast on missing build commands

Add require_cmds check for sbuild/lintian/schroot."
```

---

### Task 6: Wire `require_cmds` into `lint-package.sh`

**Files:**
- Modify: `scripts/lint-package.sh` (after line 3)

- [ ] **Step 1: Add the call**

In `scripts/lint-package.sh`, immediately after line 3 (`source "$(dirname "$0")/_common.sh"`) and before line 5 (the comment `# Spec §6.3...`), insert:

```bash

# Fail fast if the builder is missing required commands.
require_cmds lintian:lintian
```

- [ ] **Step 2: Verify syntax loads cleanly**

Run: `bash -n scripts/lint-package.sh`
Expected: no output (exit 0).

- [ ] **Step 3: Commit**

```bash
git add scripts/lint-package.sh
git commit -m "feat(lint-package): fail fast on missing lintian"
```

---

### Task 7: Wire `require_cmds` into `rewrap-changelog.sh`

**Files:**
- Modify: `scripts/rewrap-changelog.sh` (after line 3)

- [ ] **Step 1: Add the call**

In `scripts/rewrap-changelog.sh`, immediately after line 3 (`source "$(dirname "$0")/_common.sh"`) and before line 5 (the comment `# Spec §2.5...`), insert:

```bash

# Fail fast if the builder is missing required commands (dch from devscripts).
require_cmds dch:devscripts
```

- [ ] **Step 2: Verify syntax loads cleanly**

Run: `bash -n scripts/rewrap-changelog.sh`
Expected: no output (exit 0).

- [ ] **Step 3: Commit**

```bash
git add scripts/rewrap-changelog.sh
git commit -m "feat(rewrap-changelog): fail fast on missing dch (devscripts)"
```

---

### Task 8: End-to-end verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `bats test/`
Expected: ALL tests pass, including the 4 new `test_require_cmds.bats` cases.

- [ ] **Step 2: Simulate the original failure to confirm the new error is precise**

Run (in a subshell that strips `dscverify` by giving a fake PATH — dscverify absent, but bash/curl present so the check runs far enough):

```bash
# Demonstrate the error format without needing a real missing-package host:
# call require_cmds with a guaranteed-absent command directly.
bash -c "set -euo pipefail; source scripts/_common.sh; require_cmds zzz-fake-cmd:devscripts ls:coreutils"
echo "exit=$?"
```

Expected output (multi-line, on stderr prefixed with timestamp):
```
[HH:MM:SS] ERROR: missing commands: zzz-fake-cmd
  packages: devscripts
  fix: run 'make bootstrap-build-host' on the builder, or: sudo apt-get install -y devscripts
```
Expected exit code: `1`

- [ ] **Step 3: Confirm success path is a clean no-op**

Run:
```bash
bash -c "set -euo pipefail; source scripts/_common.sh; require_cmds ls:coreutils bash:bash; echo OK"
```
Expected output: `OK` (exit 0, no other output).

- [ ] **Step 4: Final commit if any verification surfaced issues (otherwise skip)**

If steps 1-3 are all clean, no additional commit is needed. The implementation tasks (1-7) each committed independently.

---

## Notes for the implementing engineer

- **Insertion-point line numbers** reference the file state at the time this plan was written. If a prior task changed a file's line count, match by the described anchor text (e.g. "after the last `. _*.sh` source") rather than raw line number.
- **`set -euo pipefail`** is already active in `_common.sh` and all target scripts, so `require_cmds` runs under strict mode. The helper is written to be safe under it (no unbound vars, `command -v` does not trip `set -e`).
- **Do not** add `require_cmds` to `bootstrap-build-host.sh` — it is the package installer itself (chicken-and-egg). Do **not** add it to publish scripts (`aptly-*.sh`, `r2-sync.sh`, `cf-purge.sh`) — out of scope per spec.
- Each task is independently committable; if executing inline, you may batch Tasks 2-7 into a single commit if preferred, but keep Task 1 (the helper + tests) as its own commit since later tasks depend on it.
