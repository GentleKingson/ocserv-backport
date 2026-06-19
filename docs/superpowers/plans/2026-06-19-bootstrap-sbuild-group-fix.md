# bootstrap sbuild-group fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two defects in `scripts/bootstrap-build-host.sh` exposed when `sbuild-createchroot` succeeds but the builder user can't read the resulting chroot sources: (1) `install_packages` installs sbuild but never runs `sbuild-adduser` to put the builder in the `sbuild` group; (2) `verify_chroot_sources` reports a vague "no apt sources found" instead of diagnosing the permission problem.

**Root cause (from a real run):** `sbuild-createchroot` printed `I: Run "sbuild-adduser" to add new sbuild users.` but the script never did; the chroot files are owned root:sbuild mode 0640, so the builder user (not in `sbuild`) couldn't read `/etc/apt/sources.list*`, and `verify_chroot_sources` died with "no apt sources found in /var/lib/sbuild/trixie-amd64-sbuild/etc/apt" — a misleading message hiding the real (group-membership) problem.

**Scope (locked, A only):**
- DO: add `sbuild-adduser` to `install_packages` with membership check + re-login warning; make `verify_chroot_sources`'s no-files branch distinguish "root-visible but user-unreadable" from "truly absent".
- DO NOT: touch docker group, broader runtime-group audit, new bats tests, GPG/aptly/rclone, or `sudo cat` workarounds to bypass the permission check (the fix is to fix the group, not to paper over it with sudo).

**Tech Stack:** Bash (`set -euo pipefail`), existing `_common.sh` helpers (`log`/`die`/`run_cmd`), `id`/`sudo`/`test`/`find`. Verified by shellcheck + `--dry-run` (dev box) + real `setup_sbuild_chroot` on the trixie builder.

**Verification model (same as the rest of the bootstrap script):**
- Dev box (macOS): shellcheck + `--dry-run` paths + parser smoke. The membership check and `sbuild-adduser` cannot run here (no sudo/trixie), so dry-run must print the intended action without executing.
- Trixie builder: real `install_packages` then `setup_sbuild_chroot`; after `sbuild-adduser` + a fresh login, `chroot sources OK (trixie-only)` must appear.

**Acceptance criteria:**
1. When builder is NOT in the sbuild group, `install_packages` executes (or, in dry-run, prints) `sudo sbuild-adduser <BUILDER_USER>` and warns that a re-login / `newgrp sbuild` is required.
2. When builder is already in the sbuild group, `install_packages` logs "already in sbuild group" and does NOT re-run `sbuild-adduser` (idempotent).
3. When chroot sources are root-visible but unreadable by the current user, `verify_chroot_sources` dies with a message naming the sbuild group + re-login step (NOT the generic "no apt sources found").
4. When chroot sources are genuinely absent (even via sudo), `verify_chroot_sources` still dies with "no apt sources found in <etc>; chroot may be incomplete".
5. After builder is in sbuild group and re-logged-in, `setup_sbuild_chroot` prints `chroot sources OK (trixie-only)`.
6. No new bats tests; docker/group-audit/GPG/aptly/rclone untouched; no `sudo cat` to bypass verification.

**Conventions:** `#!/usr/bin/env bash` + `set -euo pipefail` (already in the file); internal aliases `BUILDER_USER`/`APTLY_ROOT` etc. already in scope; Conventional Commits.

---

## File Structure

```
scripts/bootstrap-build-host.sh   # MODIFY: add ensure_sbuild_group_membership + call it;
                                  #        rewrite verify_chroot_sources no-files branch
```

Single file, two localized edits. No new files. `ensure_sbuild_group_membership` is a small named function (clearer than inlining the group check twice and easier to read than a one-liner).

---

## Task 1: Create fix branch

**Files:** (git only)

- [ ] **Step 1: Branch off main**

Run:
```bash
git checkout main && git pull --ff-only 2>/dev/null || true
git checkout -b fix/bootstrap-sbuild-group
git branch --show-current
```
Expected: `fix/bootstrap-sbuild-group`.

- [ ] **Step 2: Confirm clean tree**

Run: `git status --short`
Expected: no output.

---

## Task 2: `install_packages` — add sbuild group membership

Add a named helper `ensure_sbuild_group_membership` and call it at the end of `stage_install_packages`. Idempotent: skips if already in the group.

**Files:** Modify `scripts/bootstrap-build-host.sh` (add helper near other stage helpers; add call in `stage_install_packages`)

- [ ] **Step 1: Add the helper function**

Insert this function immediately AFTER `stage_install_packages` (before `stage_prepare_directories`), so it sits with the stage it serves:

```bash
# Ensure BUILDER_USER is in the sbuild group so non-sudo sbuild can read the
# chroot (chroot files are root:sbuild, mode 0640). Idempotent.
ensure_sbuild_group_membership() {
  if id -nG "${BUILDER_USER}" | tr ' ' '\n' | grep -qx sbuild; then
    log "${BUILDER_USER} already in sbuild group"
    return
  fi
  run_cmd sudo sbuild-adduser "${BUILDER_USER}"
  log "WARN: ${BUILDER_USER} was added to sbuild group; log out and back in, or run 'newgrp sbuild', before using sbuild without sudo"
}
```

- [ ] **Step 2: Call it at the end of `stage_install_packages`**

In `stage_install_packages`, append the call after the `apt-get install` line:

```bash
stage_install_packages() {
  log "stage: install_packages"
  run_cmd sudo apt-get update
  run_cmd sudo apt-get install -y \
    sbuild schroot debootstrap \
    build-essential devscripts debhelper debhelper-compat \
    dpkg-dev fakeroot lintian quilt \
    rclone aptly gnupg jq docker.io git curl ca-certificates
  ensure_sbuild_group_membership
}
```

- [ ] **Step 3: shellcheck**

Run: `shellcheck -S warning scripts/bootstrap-build-host.sh`
Expected: clean. (Note: `run_cmd sudo sbuild-adduser ...` is a simple argv → run_cmd is the correct wrapper per the script's rule-3 convention. `id -nG ... | tr | grep` has no shellcheck issues.)

- [ ] **Step 4: Dry-run smoke (dev box — membership check runs; sbuild-adduser prints, doesn't execute)**

Run:
```bash
# Simulate builder NOT in sbuild group (the realistic pre-fix state).
scripts/bootstrap-build-host.sh --dry-run --only-stage install_packages 2>&1 | tail -4
```
Expected: a `DRY-RUN: sudo sbuild-adduser <user>` line (because the dev-box user is not in `sbuild`) followed by the re-login WARN. `run_cmd` guarantees `sbuild-adduser` is NOT actually executed.

> Note: on the dev box `id -nG $USER` won't contain `sbuild`, so the "already in group" branch is not exercised locally — that's fine; it's exercised on the trixie builder on a second run (Task 4 acceptance #2).

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap-build-host.sh
git commit -m "fix: ensure builder is in sbuild group in install_packages

sbuild-createchroot creates chroot files root:sbuild mode 0640; the builder
user could not read /etc/apt/sources.list*, breaking verify_chroot_sources.
Add ensure_sbuild_group_membership: idempotent sbuild-adduser + re-login WARN."
```

---

## Task 3: `verify_chroot_sources` — distinguish permission vs absence

Rewrite the no-files branch to probe with `sudo` and give a precise error when sources exist but are unreadable.

**Files:** Modify `scripts/bootstrap-build-host.sh` (`verify_chroot_sources` no-files branch, currently a single `die "no apt sources found in ${etc}"`)

- [ ] **Step 1: Replace the no-files branch**

The current block (lines ~294-300) is:
```bash
  if [[ ${#files[@]} -eq 0 ]]; then
    if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
      log "DRY-RUN: would verify chroot sources after creation (none found yet)"
      return
    fi
    die "no apt sources found in ${etc}"
  fi
```

Replace the `die "no apt sources found in ${etc}"` line with a sudo-probe + branching message. New block:
```bash
  if [[ ${#files[@]} -eq 0 ]]; then
    if [[ "${BOOTSTRAP_DRY_RUN}" == "1" ]]; then
      log "DRY-RUN: would verify chroot sources after creation (none found yet)"
      return
    fi
    # Sources not visible to the current user. Distinguish "exist but unreadable"
    # (group membership problem) from "genuinely absent" (incomplete chroot).
    # Do NOT sudo-cat to bypass verification — the fix is to fix the group.
    if sudo test -f "${etc}/sources.list" 2>/dev/null \
       || { sudo test -d "${etc}/sources.list.d" 2>/dev/null \
            && sudo find "${etc}/sources.list.d" -maxdepth 1 \
                 \( -name '*.list' -o -name '*.sources' \) -type f -print 2>/dev/null \
               | grep -q .; }; then
      die "apt sources exist under ${etc} but current user cannot read them. \
Ensure ${BUILDER_USER} is in the sbuild group and start a new login session: \
'sudo sbuild-adduser ${BUILDER_USER}', then log out/in or run 'newgrp sbuild'."
    fi
    die "no apt sources found in ${etc}; chroot may be incomplete"
  fi
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck -S warning scripts/bootstrap-build-host.sh`
Expected: clean.

- [ ] **Step 3: Unit-style smoke — clean trixie sources still pass**

Run:
```bash
tmp="$(mktemp -d)"; mkdir -p "$tmp/etc/apt/sources.list.d"
printf 'deb http://deb.debian.org/debian trixie main\n' > "$tmp/etc/apt/sources.list"
printf '# comment\n\ndeb http://deb.debian.org/debian-security trixie-security main\n' > "$tmp/etc/apt/sources.list.d/security.list"
BOOTSTRAP_DRY_RUN=0 bash -c 'set -euo pipefail; source scripts/bootstrap-build-host.sh; verify_chroot_sources "'"$tmp"'" && echo RESULT_OK' 2>&1 | tail -2
rm -rf "$tmp"
```
Expected: `chroot sources OK (trixie-only)` then `RESULT_OK`.

- [ ] **Step 4: Unit-style smoke — contaminated sources still die with the bad line**

Run:
```bash
tmp="$(mktemp -d)"; mkdir -p "$tmp/etc/apt"
printf 'deb http://deb.debian.org/debian sid main\n' > "$tmp/etc/apt/sources.list"
BOOTSTRAP_DRY_RUN=0 bash -c 'set -euo pipefail; source scripts/bootstrap-build-host.sh; verify_chroot_sources "'"$tmp"'"' 2>&1 | tail -2; echo "exit=${PIPESTATUS[0]}"
rm -rf "$tmp"
```
Expected: dies, exit non-zero, message names the `sid` line.

- [ ] **Step 5: Unit-style smoke — genuinely-absent sources die with the incomplete message**

Run:
```bash
tmp="$(mktemp -d)"; mkdir -p "$tmp/etc/apt"   # no sources.list, no sources.list.d
BOOTSTRAP_DRY_RUN=0 bash -c 'set -euo pipefail; source scripts/bootstrap-build-host.sh; verify_chroot_sources "'"$tmp"'"' 2>&1 | tail -1; echo "exit=${PIPESTATUS[0]}"
rm -rf "$tmp"
```
Expected: dies, exit non-zero, `no apt sources found in <etc>; chroot may be incomplete`. (On the dev box the sudo probe returns false because the files truly don't exist, so the permission branch is skipped.)

> The "root-visible but user-unreadable" branch (acceptance #3) cannot be unit-tested on the dev box without root-owned unreadable fixtures; it is verified on the trixie builder (Task 4).

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap-build-host.sh
git commit -m "fix: distinguish permission vs absence in verify_chroot_sources

When the builder can't see chroot sources, probe with sudo: if root can see
them but the current user can't, die with a precise sbuild-group / re-login
message instead of the misleading 'no apt sources found'. Only report
'incomplete chroot' when sources are genuinely absent. No sudo-cat bypass —
the fix is the group, not working around it."
```

---

## Task 4: Verification gate

This is the verification-before-completion checkpoint, not a code task. Splits dev-box (static) from trixie-builder (real) verification.

- [ ] **Step 1: Dev-box — shellcheck all scripts**

Run: `shellcheck -S warning scripts/*.sh ansible/roles/ocserv_backport/files/*.sh`
Expected: clean.

- [ ] **Step 2: Dev-box — full bats still green**

Run: `bats test/*.bats`
Expected: all `ok` (no new tests; existing suite must not regress).

- [ ] **Step 3: Dev-box — dry-run end-to-end (no side effects)**

Run:
```bash
scripts/bootstrap-build-host.sh --dry-run --from-stage install_packages 2>&1 \
  | grep -E 'DRY-RUN|sbuild|chroot' | head
```
Expected (on dev box, current user not in sbuild):
- `DRY-RUN: sudo apt-get ...` lines
- `DRY-RUN: sudo sbuild-adduser <user>`
- the re-login WARN
- (preflight runs first but may die on dev box as non-trixie — that's expected; the `--from-stage install_packages` still runs load_config first via the always-first logic, then install_packages, then prepare_directories, etc. If preflight isn't skipped, run `--only-stage install_packages` to see just that stage.)

If the above is noisy due to preflight dying on macOS, confirm with:
```bash
scripts/bootstrap-build-host.sh --dry-run --only-stage install_packages 2>&1 | tail -5
```
Expected: `DRY-RUN: sudo sbuild-adduser <user>` + re-login WARN visible.

- [ ] **Step 4: Trixie-builder — real verification (acceptance #1, #3, #4, #5)**

Run on the trixie builder as `${BUILDER_USER}` (NOT yet in sbuild group — i.e. reproduce the bug state first):
```bash
scripts/bootstrap-build-host.sh --only-stage install_packages
```
Expected: `sbuild-adduser` runs, WARN printed. Then, in the SAME shell (group not yet effective), run:
```bash
scripts/bootstrap-build-host.sh --only-stage setup_sbuild_chroot
```
Expected: dies with the new precise message — `apt sources exist under ... but current user cannot read them ... sbuild-adduser ... newgrp sbuild`. (This is acceptance #3, reproduced and now diagnosed correctly.)

Then start a NEW login shell (so sbuild group is effective):
```bash
exit   # leave the old shell
# log back in as builder
scripts/bootstrap-build-host.sh --only-stage setup_sbuild_chroot
```
Expected: `chroot exists; verifying sources` then `chroot sources OK (trixie-only)`. (Acceptance #5.)

Then a second `install_packages` run (now in group):
```bash
scripts/bootstrap-build-host.sh --only-stage install_packages
```
Expected: `<builder> already in sbuild group` (acceptance #2, idempotent).

- [ ] **Step 5: Final commit if anything changed**

Run: `git status --short`
Expected: clean (Tasks 2 & 3 already committed). If a doc tweak landed, commit it; otherwise nothing to do.

---

## Self-Review (completed during authoring)

**Scope check:** Only the two named defects. No docker group, no group-audit sweep, no bats additions, no `sudo cat` bypass, no GPG/aptly/rclone changes. ✓

**Placeholder scan:** No TBD/TODO. Acceptance criteria are concrete. The trixie-only steps (Task 4 Step 4) are explicit about being target-host verification, not gaps. ✓

**Consistency:** `BUILDER_USER` alias used (not `BOOTSTRAP_BUILDER_USER`); `run_cmd` used for the `sbuild-adduser` mutation (dry-run-safe); the `id -nG | tr | grep -qx sbuild` membership test is the exact form the user specified. The new no-files branch keeps the existing dry-run early-return and only adds the sudo probe + two die messages. ✓

**Acceptance mapping:** #1→Task2 Step1-2, #2→Task4 Step4 (second run), #3→Task3 Step1, #4→Task3 Step1+Step5, #5→Task4 Step4, #6→scope statement. ✓
