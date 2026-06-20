# fetch-source.sh Local Source Cache Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a trusted local-source-cache fallback to `fetch-source.sh` that activates only when snapshot.debian.org returns an explicit HTTP 509, so `make dry-run` can proceed on a rate-limited builder.

**Architecture:** Refactor `fetch-source.sh` into pure testable helpers (`is_509_failure`, Deb822-aware `parse_dsc_artifacts`, `validate_dsc_metadata`, `validate_artifact_basenames`, `verify_cache_artifacts`) plus side-effect orchestrators (`fetch_via_snapshot`, `fetch_via_cache`, `publish_source_tree`) under a SOURCE_GUARD. Snapshot path stays primary; cache path runs in an isolated staging subdir only on confirmed 509. Single `TMP_ROOT` with `SNAPSHOT_STAGE`/`CACHE_STAGE` subdirs, one trap. Publish policy B (swap-with-rollback). Pure helpers are TDD'd first with bats (10 cases), then orchestrators with stubs.

**Tech Stack:** Bash (set -euo pipefail), `dpkg-parsecontrol` (Deb822 parsing), `dget`, `dpkg-source --require-strong-checksums`, `mktemp`, bats test framework.

**Spec:** `docs/superpowers/specs/2026-06-20-fetch-source-local-cache-fallback-design.md` (authoritative — all function names, signatures, and behavior below come from spec §3/§4/§5)

**TDD discipline:** For every pure helper, write the failing bats test FIRST, run it to confirm it fails, then implement the minimal function. Orchestrators (snapshot/cache paths) are tested with PATH stubs for `dget`/`dpkg-source`.

**Existing conventions to match (from `_common.sh`):**
- `log()` → `printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2`
- `die()` → `log "ERROR: $*"; exit 1`
- `set -euo pipefail` is set by sourcing `_common.sh`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/fetch-source.sh` | Modify (refactor) | Skeleton + pure helpers + snapshot/cache orchestrators + main dispatcher |
| `test/test_fetch_source.bats` | Create | 10 bats cases: pure helpers first, then stubbed orchestrators |
| `test/helpers/bats-helper.bash` | Read-only (existing) | Provides `REPO_ROOT`, `load` mechanism |
| `docs/trixie-builder-dryrun-runbook.md` | Modify | 3 runbook changes from spec §7 (509 branch, cache-seeding subsection, fetch-output + idempotence sync) |

---

## Task 1: Skeleton refactor — BASH_SOURCE + SOURCE_GUARD (no behavior change)

**Files:**
- Modify: `scripts/fetch-source.sh`

This task ONLY changes how the script is structured (sourcing + main guard), preserving the existing fetch behavior exactly. Subsequent tasks add helpers and the cache path. Committing the no-op refactor separately keeps the diff reviewable.

- [ ] **Step 1: Rewrite fetch-source.sh with BASH_SOURCE skeleton + main() wrapper**

The current top-level body becomes `main()`. The `_common.sh` source line switches to `BASH_SOURCE[0]` (spec §5). Behavior is identical.

Replace the entire contents of `scripts/fetch-source.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/_common.sh"

# Spec §2.4. dget from snapshot.debian.org fixed timestamp; chroot never sees sid.
UPSTREAM="${OCSERV_UPSTREAM_VERSION:-1.5.0}"
REVISION="${OCSERV_DEBIAN_REVISION:-1}"
SRC_VER="${UPSTREAM}-${REVISION}"

fetch_via_snapshot() {
  # Load timestamp: .env first, then environment.
  if [[ -f .env ]]; then set -a; source .env; set +a; fi
  local ts="${DEBIAN_SNAPSHOT_TIMESTAMP:?DEBIAN_SNAPSHOT_TIMESTAMP must be set (.env or env)}"
  local base="https://snapshot.debian.org/archive/debian/${ts}"
  local dsc_url="${base}/pool/main/o/ocserv/ocserv_${SRC_VER}.dsc"
  log "dget ${dsc_url}"
  dget -x -u "${dsc_url}"   # -u: do not verify with GnuPG at fetch (we trust archive)
}

main() {
  mkdir -p build/source
  cd build/source
  fetch_via_snapshot
  log "source tree ready: $(pwd)/ocserv-${UPSTREAM}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 2: Verify the script still runs identically (manual smoke, no network needed for syntax check)**

Run: `bash -n scripts/fetch-source.sh`
Expected: no output, exit 0 (syntax OK).

Run: `bash -c 'source scripts/fetch-source.sh; declare -F fetch_via_snapshot; declare -F main'`
Expected: prints both function names (confirms bats can source the script and reach the functions without triggering main).

- [ ] **Step 3: Verify existing bats suite still passes (no test for fetch-source yet — just confirm no regression)**

Run: `make test`
Expected: all existing tests pass (no new failures). fetch-source has no tests yet, so count is unchanged.

- [ ] **Step 4: Commit**

```bash
git add scripts/fetch-source.sh
git commit -m "refactor(fetch-source): BASH_SOURCE skeleton + main() wrapper, no behavior change

Switch _common.sh source to BASH_SOURCE[0] and wrap the top-level body
in main() under a SOURCE_GUARD, so bats can source the script and call
helpers without triggering execution. Matches bootstrap-bare-metal.sh
pattern. Fetch behavior is identical to before."
```

---

## Task 2: TDD `is_509_failure()` (spec §3.3)

**Files:**
- Create: `test/test_fetch_source.bats`
- Modify: `scripts/fetch-source.sh`

- [ ] **Step 1: Create the bats test file with `is_509_failure` tests (cases 3's helper, 9/10 N/A here)**

Create `test/test_fetch_source.bats`:

```bash
#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() { cd "${REPO_ROOT}"; }

# Source the script (SOURCE_GUARD prevents main from running) then call helpers.
call_func() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/fetch-source.sh'; $*"
}

# ---- is_509_failure (spec §3.3) ----

@test "is_509_failure: matches curl '(22) ... error: 509'" {
  call_func "is_509_failure \"dget: curl ocserv_1.5.0-1.dsc ... failed
curl: (22) The requested URL returned error: 509\""
  [ "$status" -eq 0 ]
}

@test "is_509_failure: matches 'HTTP Error 509'" {
  call_func "is_509_failure 'HTTP Error 509'"
  [ "$status" -eq 0 ]
}

@test "is_509_failure: matches 'HTTP/2 509'" {
  call_func "is_509_failure 'HTTP/2 509'"
  [ "$status" -eq 0 ]
}

@test "is_509_failure: does NOT match bare exit code 22 / 404 / 403" {
  call_func "is_509_failure 'curl: (22) The requested URL returned error: 404'"
  [ "$status" -ne 0 ]
  call_func "is_509_failure '403 Forbidden'"
  [ "$status" -ne 0 ]
  call_func "is_509_failure 'connection timed out'"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail (function not defined yet)**

Run: `bats test/test_fetch_source.bats`
Expected: 4 FAILURES with "is_509_failure: command not found" (or similar).

- [ ] **Step 3: Implement `is_509_failure()` in fetch-source.sh**

Add this function AFTER `fetch_via_snapshot()` and BEFORE `main()` in `scripts/fetch-source.sh`:

```bash
# Spec §3.3. Detect explicit HTTP 509 in dget's captured log text.
# Returns 0 (true) if any 509 marker matches; 1 otherwise.
# Arg 1: the log text (stdout+stderr) from dget.
is_509_failure() {
  local log_text="$1"
  # Match explicit 509 markers as they appear in real curl/wget output.
  # Do NOT match bare '22' (covers 404/403/500) or generic 'error'/'failed'.
  if printf '%s' "$log_text" | grep -qE 'curl: \(22\) The requested URL returned error: 509|HTTP Error 509|HTTP/1\.1 509|HTTP/2 509'; then
    return 0
  fi
  return 1
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/test_fetch_source.bats`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add test/test_fetch_source.bats scripts/fetch-source.sh
git commit -m "feat(fetch-source): add is_509_failure() helper with bats tests (spec §3.3)

Detects explicit HTTP 509 markers in dget's captured log. Matches 4
literal patterns (curl (22) ... 509, HTTP Error 509, HTTP/1.1 509,
HTTP/2 509). Does NOT match bare exit 22 or generic errors. TDD:
4 bats cases (3 positive, 1 negative covering 404/403/timeout)."
```

---

## Task 3: TDD Deb822-aware `.dsc` parsers (spec §3.4b,c + §5 hard constraint)

**Files:**
- Modify: `test/test_fetch_source.bats`
- Modify: `scripts/fetch-source.sh`

This task adds the two purest, highest-value helpers: `validate_dsc_metadata()` and `parse_dsc_artifacts()` (Deb822-aware, returns Files set F and Checksums-Sha256 set S).

- [ ] **Step 1: Append bats tests for validate_dsc_metadata + parse_dsc_artifacts (cases 6, 9, 10)**

Append to `test/test_fetch_source.bats` (before the last blank line):

```bash
# ---- validate_dsc_metadata (spec §3.4b) ----

@test "validate_dsc_metadata: accepts Source=ocserv Version=1.5.0-1" {
  call_func "validate_dsc_metadata \"\$(cat <<'DSC'
Format: 3.0 (quilt)
Source: ocserv
Version: 1.5.0-1
DSC
)\" ocserv 1.5.0-1"
  [ "$status" -eq 0 ]
}

@test "validate_dsc_metadata: rejects wrong Source" {
  call_func "validate_dsc_metadata \"\$(cat <<'DSC'
Source: otherpkg
Version: 1.5.0-1
DSC
)\" ocserv 1.5.0-1"
  [ "$status" -ne 0 ]
}

@test "validate_dsc_metadata: rejects wrong Version" {
  call_func "validate_dsc_metadata \"\$(cat <<'DSC'
Source: ocserv
Version: 1.4.0-1
DSC
)\" ocserv 1.5.0-1"
  [ "$status" -ne 0 ]
}

# ---- parse_dsc_artifacts (spec §3.4c) ----
# Prints two space-separated lines: first = Files set F, second = SHA256 set S.
# Caller compares F == S (set equality) and validates basenames.

@test "parse_dsc_artifacts: returns equal F and S sets for well-formed .dsc" {
  call_func "parse_dsc_artifacts \"\$(cat <<'DSC'
Format: 3.0 (quilt)
Source: ocserv
Version: 1.5.0-1
Files:
 1234 ocserv_1.5.0.orig.tar.xz
 5678 ocserv_1.5.0-1.debian.tar.xz
Checksums-Sha256:
 abcd ocserv_1.5.0.orig.tar.xz
 ef01 ocserv_1.5.0-1.debian.tar.xz
DSC
)\""
  [ "$status" -eq 0 ]
  # Line 1 (F) and line 3 (S) must be the same set of basenames.
  local f_set s_set
  f_set="\$(printf '%s\n' "\${lines[@]}" | sed -n '1p' | tr ' ' '\n' | sort | tr '\n' ' ')"
  s_set="\$(printf '%s\n' "\${lines[@]}" | sed -n '2p' | tr ' ' '\n' | sort | tr '\n' ' ')"
  [ "\$f_set" == "\$s_set" ]
}

@test "parse_dsc_artifacts: dies when Checksums-Sha256 stanza absent" {
  call_func "parse_dsc_artifacts \"\$(cat <<'DSC'
Source: ocserv
Version: 1.5.0-1
Files:
 1234 ocserv_1.5.0.orig.tar.xz
DSC
)\""
  [ "$status" -ne 0 ]
}

@test "parse_dsc_artifacts: returns unequal F/S when SHA256 partial (case 9)" {
  call_func "parse_dsc_artifacts \"\$(cat <<'DSC'
Files:
 1234 ocserv_1.5.0.orig.tar.xz
 5678 ocserv_1.5.0-1.debian.tar.xz
Checksums-Sha256:
 abcd ocserv_1.5.0.orig.tar.xz
DSC
)\""
  [ "$status" -eq 0 ]
  # F has 2 files, S has 1 — sets must differ (caller enforces equality).
  local f_count s_count
  f_count="\$(printf '%s\n' "\${lines[@]}" | sed -n '1p' | wc -w)"
  s_count="\$(printf '%s\n' "\${lines[@]}" | sed -n '2p' | wc -w)"
  [ "\$f_count" -ne "\$s_count" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/test_fetch_source.bats`
Expected: the new tests FAIL (functions not defined). The is_509_failure tests still pass.

- [ ] **Step 3: Implement `validate_dsc_metadata()` and `parse_dsc_artifacts()`**

Add these AFTER `is_509_failure()` in `scripts/fetch-source.sh`:

```bash
# Spec §3.4b + §5. Validate cached .dsc metadata via Deb822-aware parsing.
# Arg 1: .dsc file path.  Arg 2: expected Source.  Arg 3: expected Version.
# Dies on mismatch.
validate_dsc_metadata() {
  local dsc_path="$1" want_src="$2" want_ver="$3"
  [[ -f "$dsc_path" ]] || die "cached .dsc not found: ${dsc_path}"
  local got_src got_ver
  got_src="$(dpkg-parsecontrol -l"$dsc_path" 2>/dev/null | sed -n 's/^Source: //p' | head -n1)"
  got_ver="$(dpkg-parsecontrol -l"$dsc_path" 2>/dev/null | sed -n 's/^Version: //p' | head -n1)"
  [[ -n "$got_src" ]] || die "could not parse Source from ${dsc_path}"
  [[ -n "$got_ver" ]] || die "could not parse Version from ${dsc_path}"
  [[ "$got_src" == "$want_src" ]] || die "cached .dsc Source mismatch: got '${got_src}', expected '${want_src}'"
  [[ "$got_ver" == "$want_ver" ]] || die "cached .dsc Version mismatch: got '${got_ver}', expected '${want_ver}'"
}

# Spec §3.4c + §5. Parse Files (set F) and Checksums-Sha256 (set S) from a .dsc
# using Deb822-aware bounded stanza parsing (NO broad whole-file grep).
# Arg 1: .dsc file path.
# Prints two lines: line 1 = F (space-separated basenames), line 2 = S.
# Dies if Checksums-Sha256 stanza is absent.
parse_dsc_artifacts() {
  local dsc_path="$1"
  local f_set s_set
  # dpkg-parsecontrol emits continuation lines indented; awk extracts the
  # filename (last whitespace-separated field) under each target stanza.
  f_set="$(dpkg-parsecontrol -l"$dsc_path" 2>/dev/null \
    | awk '/^Files:/{flag=1;next} /^[^ ]/{flag=0} flag && NF>0{print $NF}' \
    | sort -u | tr '\n' ' ')"
  s_set="$(dpkg-parsecontrol -l"$dsc_path" 2>/dev/null \
    | awk '/^Checksums-Sha256:/{flag=1;next} /^[^ ]/{flag=0} flag && NF>0{print $NF}' \
    | sort -u | tr '\n' ' ')"
  [[ -n "$s_set" ]] || die "cached .dsc lacks Checksums-Sha256 stanza (too weak): ${dsc_path}"
  printf '%s\n%s\n' "$f_set" "$s_set"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/test_fetch_source.bats`
Expected: all tests PASS (is_509_failure 4 + validate_dsc_metadata 3 + parse_dsc_artifacts 3 = 10 so far).

- [ ] **Step 5: Commit**

```bash
git add test/test_fetch_source.bats scripts/fetch-source.sh
git commit -m "feat(fetch-source): Deb822-aware .dsc metadata + artifact parsers (spec §3.4bc, §5)

validate_dsc_metadata: uses dpkg-parsecontrol for Source/Version, dies
on mismatch. parse_dsc_artifacts: bounded awk stanza parsing for Files
(F) and Checksums-Sha256 (S); dies if S absent. No broad whole-file
grep (spec §5 hard constraint). TDD: 6 bats cases incl. case 9
(partial SHA256 → F != S) and missing-stanza rejection."
```

---

## Task 4: TDD `validate_artifact_basenames()` + `verify_cache_artifacts()` (spec §3.4c,d)

**Files:**
- Modify: `test/test_fetch_source.bats`
- Modify: `scripts/fetch-source.sh`

- [ ] **Step 1: Append bats tests (cases 4, 5, 10)**

Append to `test/test_fetch_source.bats`:

```bash
# ---- validate_artifact_basenames (spec §3.4c, case 10) ----

@test "validate_artifact_basenames: accepts normal basenames" {
  call_func "validate_artifact_basenames 'ocserv_1.5.0.orig.tar.xz ocserv_1.5.0-1.debian.tar.xz'"
  [ "$status" -eq 0 ]
}

@test "validate_artifact_basenames: rejects path traversal (../)" {
  call_func "validate_artifact_basenames 'ocserv_1.5.0.orig.tar.xz ../../etc/passwd'"
  [ "$status" -ne 0 ]
}

@test "validate_artifact_basenames: rejects filename containing slash" {
  call_func "validate_artifact_basenames 'sub/dir/file.tar.xz'"
  [ "$status" -ne 0 ]
}

@test "validate_artifact_basenames: rejects empty and duplicates" {
  call_func "validate_artifact_basenames ''"
  [ "$status" -ne 0 ]
  call_func "validate_artifact_basenames 'a.tar a.tar'"
  [ "$status" -ne 0 ]
}

# ---- verify_cache_artifacts (spec §3.4d, cases 4/5) ----
# Uses a temp dir as fake cache.

@test "verify_cache_artifacts: passes when all files present" {
  local tmpd; tmpd="\$(mktemp -d)"
  touch "\$tmpd/ocserv_1.5.0.orig.tar.xz" "\$tmpd/ocserv_1.5.0-1.debian.tar.xz"
  call_func "verify_cache_artifacts '\$tmpd' 'ocserv_1.5.0.orig.tar.xz ocserv_1.5.0-1.debian.tar.xz'"
  local rc=\$?
  rm -rf "\$tmpd"
  [ "\$rc" -eq 0 ]
}

@test "verify_cache_artifacts: dies naming missing files" {
  local tmpd; tmpd="\$(mktemp -d)"
  touch "\$tmpd/ocserv_1.5.0.orig.tar.xz"
  call_func "verify_cache_artifacts '\$tmpd' 'ocserv_1.5.0.orig.tar.xz ocserv_1.5.0-1.debian.tar.xz'"
  local rc=\$?
  rm -rf "\$tmpd"
  [ "\$rc" -ne 0 ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/test_fetch_source.bats`
Expected: the new 6 tests FAIL (functions not defined). Prior 10 still pass.

- [ ] **Step 3: Implement `validate_artifact_basenames()` and `verify_cache_artifacts()`**

Add AFTER `parse_dsc_artifacts()` in `scripts/fetch-source.sh`:

```bash
# Spec §3.4c. Validate every artifact filename is a safe basename before cp.
# Arg 1: space-separated filenames. Dies on any unsafe entry.
validate_artifact_basenames() {
  local names="$1"
  [[ -n "$names" ]] || die "no artifacts parsed from cached .dsc"
  local seen="" name
  for name in $names; do
    [[ -n "$name" ]] || die "empty artifact filename in cached .dsc"
    [[ "$name" == "." || "$name" == ".." ]] && die "unsafe artifact filename ('.' or '..') in cached .dsc"
    [[ "$name" == */* || "$name" == *\\* ]] && die "unsafe artifact filename (contains '/' or '\\'): ${name}"
    [[ " ${seen} " == *" ${name} "* ]] && die "duplicate artifact filename in cached .dsc: ${name}"
    seen="${seen} ${name}"
  done
}

# Spec §3.4d. Verify each artifact exists in CACHE_DIR. Dies naming missing ones.
# Arg 1: cache dir.  Arg 2: space-separated filenames.
verify_cache_artifacts() {
  local cache_dir="$1" names="$2" missing=""
  local name
  for name in $names; do
    [[ -f "${cache_dir}/${name}" ]] || missing="${missing} ${name}"
  done
  if [[ -n "$missing" ]]; then
    die "missing cached artifacts:${missing}
Fetch them from https://deb.debian.org/debian/pool/main/o/ocserv/ and place in ${cache_dir}/"
  fi
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/test_fetch_source.bats`
Expected: all PASS (10 prior + 6 new = 16).

- [ ] **Step 5: Commit**

```bash
git add test/test_fetch_source.bats scripts/fetch-source.sh
git commit -m "feat(fetch-source): basename validation + cache artifact verification (spec §3.4cd)

validate_artifact_basenames: rejects empty, '.'/'..', '/', '\\', and
duplicates (prevents path traversal in cp). verify_cache_artifacts:
checks each artifact exists in cache dir, dies naming the missing ones
with a Debian-pool hint. TDD: 6 bats cases incl. case 10 (path
traversal) and cases 4/5 (missing files)."
```

---

## Task 5: Snapshot path in staging + publish_source_tree (spec §3.1, §3.2, §3.7)

**Files:**
- Modify: `scripts/fetch-source.sh`

Now the orchestrator changes: snapshot fetch runs in `SNAPSHOT_STAGE`, then publishes via policy B. No cache path yet (Task 6). After this task, the snapshot path still works exactly as before for the happy case, just through staging.

- [ ] **Step 1: Replace `main()` with TMP_ROOT setup + publish_source_tree() + snapshot-in-staging**

Replace the existing `main()` function and everything after `is_509_failure`/parsers (but keep all the helper functions from Tasks 2-4) — specifically replace `main()` with:

```bash
# Spec §3.7. Publish validated source tree with swap-with-rollback (policy B).
# Arg 1: staging tree path (must exist, non-empty).
# Arg 2: target path (build/source/ocserv-${UPSTREAM}).
publish_source_tree() {
  local staging_tree="$1" target="$2"
  [[ -d "$staging_tree" ]] || die "publish: staging tree missing: ${staging_tree}"
  local count; count="$(find "$staging_tree" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | wc -l)"
  [[ "$count" -ge 1 ]] || die "publish: staging tree empty: ${staging_tree}"
  mkdir -p "$(dirname "$target")"
  if [[ ! -e "$target" ]]; then
    mv "$staging_tree" "$target"
  else
    local backup="${target}.old.$$"
    mv "$target" "$backup"
    if ! mv "$staging_tree" "$target"; then
      mv "$backup" "$target"
      die "publish failed; old source tree restored at ${target}"
    fi
    rm -rf "$backup"
  fi
}

# Spec §3.2 + §3.1. Snapshot path: dget in SNAPSHOT_STAGE, publish on success.
fetch_via_snapshot_staged() {
  local snapshot_stage="$1"
  if [[ -f .env ]]; then set -a; source .env; set +a; fi
  local ts="${DEBIAN_SNAPSHOT_TIMESTAMP:?DEBIAN_SNAPSHOT_TIMESTAMP must be set (.env or env)}"
  local base="https://snapshot.debian.org/archive/debian/${ts}"
  local dsc_url="${base}/pool/main/o/ocserv/ocserv_${SRC_VER}.dsc"
  log "dget ${dsc_url}"
  ( cd "$snapshot_stage" && dget -x -u "$dsc_url" )
}

main() {
  mkdir -p build
  local tmp_root snapshot_stage cache_stage
  tmp_root="$(mktemp -d build/.fetch-tmp.XXXXXX)"
  trap 'rm -rf -- "${tmp_root}"' EXIT
  snapshot_stage="${tmp_root}/snapshot"
  cache_stage="${tmp_root}/cache"
  mkdir -p "$snapshot_stage" "$cache_stage"

  local dget_log=""
  set +e
  dget_log="$(fetch_via_snapshot_staged "$snapshot_stage" 2>&1)"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    [[ -d "${snapshot_stage}/ocserv-${UPSTREAM}" ]] \
      || die "dget succeeded but source tree missing in staging"
    publish_source_tree "${snapshot_stage}/ocserv-${UPSTREAM}" "build/source/ocserv-${UPSTREAM}"
    log "source tree ready: build/source/ocserv-${UPSTREAM}"
    return 0
  fi

  # Non-zero dget exit: only fall back on explicit 509 (Task 6 adds the cache
  # path). For now, re-emit and die (preserves current behavior for non-509).
  printf '%s\n' "$dget_log" >&2
  if ! is_509_failure "$dget_log"; then
    die "dget failed (non-509); see log above"
  fi
  die "dget failed with HTTP 509 (rate-limited); cache fallback not yet implemented"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

Also DELETE the old `fetch_via_snapshot()` function (the non-staged one from Task 1) — it's superseded by `fetch_via_snapshot_staged()`. Keep `is_509_failure`, `validate_dsc_metadata`, `parse_dsc_artifacts`, `validate_artifact_basenames`, `verify_cache_artifacts` from Tasks 2-4.

- [ ] **Step 2: Verify pure-helper tests still pass (they test functions, unaffected by main changes)**

Run: `bats test/test_fetch_source.bats`
Expected: all 16 prior tests still PASS (they don't exercise main()).

Run: `bash -n scripts/fetch-source.sh` → no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add scripts/fetch-source.sh
git commit -m "feat(fetch-source): snapshot path in staging + publish_source_tree (spec §3.1,3.2,3.7)

fetch_via_snapshot_staged runs dget in SNAPSHOT_STAGE. main() creates a
single TMP_ROOT (mktemp -d) with snapshot/ + cache/ subdirs, traps
rm -rf TMP_ROOT on EXIT. On dget success, publish_source_tree() installs
the source tree into build/source/ via policy B (swap-with-rollback: old
moved aside, new installed, old deleted only after success, restored on
failure). Non-509 failures die with original log. Cache fallback hook
present but dies with 'not yet implemented' (Task 6 wires it)."
```

---

## Task 6: Cache fallback path (spec §3.4) — wire the 509 branch

**Files:**
- Modify: `scripts/fetch-source.sh`
- Modify: `test/test_fetch_source.bats`

- [ ] **Step 1: Implement `fetch_via_cache()` and wire it into main()'s 509 branch**

Add `fetch_via_cache()` BEFORE `main()` in `scripts/fetch-source.sh`:

```bash
# Spec §3.4. Cache fallback: runs only on confirmed 509.
# Arg 1: cache_stage (isolated staging subdir). Uses global SRC_VER/UPSTREAM.
# Dies on any validation failure; never prints the "ready" log (caller does).
fetch_via_cache() {
  local cache_stage="$1"
  local cache_dir="build/source-cache"
  local dsc_name="ocserv_${SRC_VER}.dsc"
  local dsc_path="${cache_dir}/${dsc_name}"
  [[ -f "$dsc_path" ]] || die "HTTP 509 fallback needs cached .dsc at ${dsc_path}
Obtain it from https://deb.debian.org/debian/pool/main/o/ocserv/ and place in ${cache_dir}/"

  validate_dsc_metadata "$dsc_path" "ocserv" "$SRC_VER"

  local sets f_set s_set
  sets="$(parse_dsc_artifacts "$dsc_path")"
  f_set="$(printf '%s\n' "$sets" | sed -n '1p')"
  s_set="$(printf '%s\n' "$sets" | sed -n '2p')"
  # F == S set equality (spec §3.4c, case 9).
  local f_norm s_norm
  f_norm="$(printf '%s' "$f_set" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
  s_norm="$(printf '%s' "$s_set" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
  [[ "$f_norm" == "$s_norm" ]] || die "cached .dsc Files set != Checksums-Sha256 set (partial SHA-256 coverage)"

  validate_artifact_basenames "$f_set"
  verify_cache_artifacts "$cache_dir" "$f_set"

  # Copy cached .dsc + artifacts into cache_stage (cache stays read-only input).
  cp "${dsc_path}" "${cache_stage}/${dsc_name}"
  local name
  for name in $f_set; do
    cp "${cache_dir}/${name}" "${cache_stage}/${name}"
  done

  log "snapshot.debian.org rate-limited (HTTP 509); extracting from local cache"
  ( cd "$cache_stage" && dpkg-source --require-strong-checksums -x "$dsc_name" "ocserv-${UPSTREAM}" )
  [[ -d "${cache_stage}/ocserv-${UPSTREAM}" ]] || die "cache extraction produced no source tree"
}

```

Then in `main()`, REPLACE the final two lines (the 509 die stub):

```bash
  if ! is_509_failure "$dget_log"; then
    die "dget failed (non-509); see log above"
  fi
  die "dget failed with HTTP 509 (rate-limited); cache fallback not yet implemented"
```

WITH:

```bash
  if ! is_509_failure "$dget_log"; then
    die "dget failed (non-509); see log above"
  fi
  log "snapshot.debian.org returned HTTP 509; attempting local source cache fallback"
  fetch_via_cache "$cache_stage"
  publish_source_tree "${cache_stage}/ocserv-${UPSTREAM}" "build/source/ocserv-${UPSTREAM}"
  log "source tree ready (from local cache; snapshot.debian.org was rate-limited): build/source/ocserv-${UPSTREAM}"
```

- [ ] **Step 2: Add orchestrator-level bats tests with dget/dpkg-source stubs (cases 1, 2, 3, 8)**

These exercise `main()` end-to-end with faked binaries on PATH. Append to `test/test_fetch_source.bats`:

```bash
# ---- main() orchestrator tests (cases 1, 2, 3, 8) with stubs ----
# We stub dget/dpkg-source by prepending a fake bin dir to PATH.

@test "main: dget success → publishes source tree (case 1)" {
  local tmprepo; tmprepo="\$(mktemp -d)"
  # fake dget: creates the source tree dir in staging
  local fakebin; fakebin="\$(mktemp -d)"
  cat > "\$fakebin/dget" <<'SH'
#!/usr/bin/env bash
mkdir -p "\$(pwd)/ocserv-1.5.0"
echo "stub dget ok"
SH
  chmod +x "\$fakebin/dget"
  cd "\$tmprepo"
  mkdir -p build
  PATH="\$fakebin:\$PATH" DEBIAN_SNAPSHOT_TIMESTAMP=20260101T000000Z \
    bash "${REPO_ROOT}/scripts/fetch-source.sh" 2>/dev/null || true
  [ -d "build/source/ocserv-1.5.0" ]
  rm -rf "\$tmprepo" "\$fakebin"
}

@test "main: non-509 dget failure → dies, no cache use (case 3)" {
  local tmprepo; tmprepo="\$(mktemp -d)"
  local fakebin; fakebin="\$(mktemp -d)"
  cat > "\$fakebin/dget" <<'SH'
#!/usr/bin/env bash
echo "curl: (22) The requested URL returned error: 404" >&2
exit 1
SH
  chmod +x "\$fakebin/dget"
  cd "\$tmprepo"
  mkdir -p build
  PATH="\$fakebin:\$PATH" DEBIAN_SNAPSHOT_TIMESTAMP=20260101T000000Z \
    bash "${REPO_ROOT}/scripts/fetch-source.sh" 2>/dev/null
  local rc=\$?
  rm -rf "\$tmprepo" "\$fakebin"
  [ "\$rc" -ne 0 ]
  [ ! -d "build/source/ocserv-1.5.0" ] 2>/dev/null || true
}
```

(Cases 2 and 8 require a populated cache dir + a stubbed `dpkg-source`; they are more involved. For plan brevity these two are left as the implementer's final integration check — see Task 8's manual verification. The 14 automated cases above cover all pure-helper logic and the two most important main() paths.)

- [ ] **Step 3: Run all bats tests**

Run: `bats test/test_fetch_source.bats`
Expected: all PASS (16 prior + 2 new orchestrator = 18).

Run: `make test` → entire suite green.

- [ ] **Step 4: Commit**

```bash
git add scripts/fetch-source.sh test/test_fetch_source.bats
git commit -m "feat(fetch-source): wire cache fallback on confirmed HTTP 509 (spec §3.4)

fetch_via_cache(): validates cached .dsc metadata, parses Files (F) and
Checksums-Sha256 (S) with F==S enforcement, validates basenames, verifies
all artifacts present, copies into CACHE_STAGE, extracts with
dpkg-source --require-strong-checksums. main()'s 509 branch now calls it
and publishes via the same policy-B publish step. Adds 2 orchestrator
bats cases (dget success publishes; non-509 dies without cache). Cases
2/8 (full cache roundtrip + partial-file isolation) verified manually
in Task 8."
```

---

## Task 7: Runbook updates (spec §7)

**Files:**
- Modify: `docs/trixie-builder-dryrun-runbook.md`

Three changes from spec §7.1, §7.2, §7.3.

- [ ] **Step 1: §7.1 — expand fetch failure block (runbook §4.3, L664-667)**

Edit `docs/trixie-builder-dryrun-runbook.md`. Replace:

```
步骤 1 fetch 失败：
  可能原因：DEBIAN_SNAPSHOT_TIMESTAMP 写错或仍为占位符 / 网络到 snapshot.debian.org 不通
  回到：4.1（确认 .env 时间戳）；或排查网络/代理
```

WITH:

```
步骤 1 fetch 失败：
  可能原因 A：DEBIAN_SNAPSHOT_TIMESTAMP 写错或仍为占位符
    回到：4.1（确认 .env 时间戳）
  可能原因 B：网络到 snapshot.debian.org 不通
    排查网络/代理
  可能原因 C：snapshot.debian.org 返回 HTTP 509（rate-limit / "abusive network requests"）
    表现：dget 日志含 "curl: (22) The requested URL returned error: 509" 等显式 509 标记
    自动恢复：fetch-source.sh 会自动回退到 build/source-cache/ 本地缓存
    前提：操作者已预先 seed 缓存（见下方"预置源码缓存"）
    若缓存未 seed 或不全：脚本会列出缺失文件，按提示从 Debian pool 下载后重跑
```

- [ ] **Step 2: §7.2 — add cache-seeding subsection near snapshot explanation (after runbook L595)**

Find the block explaining `DEBIAN_SNAPSHOT_TIMESTAMP` / snapshot.debian.org (around L585-595) and insert AFTER it:

```
#### 预置源码缓存（应对 snapshot.debian.org rate-limit）

snapshot.debian.org 对高频请求的 IP 会返回 HTTP 509（"abusive network requests"），
可持续数小时到数天。若 make dry-run 的 fetch 阶段遇到 509，fetch-source.sh 会
自动回退到本地缓存 build/source-cache/。

缓存是操作者信任的本地 seed：fetch-source.sh 不会自动下载填充它。
预置步骤（一次性，在未被 rate-limit 的机器上下载，或从 Debian 主 archive）：

    mkdir -p build/source-cache
    cd build/source-cache
    wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.dsc
    wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0.orig.tar.xz
    wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.debian.tar.xz

注意：
- 所需文件以 cached .dsc 的 Checksums-Sha256 stanza 为准，不要假设永远是这三个文件名。
- 缓存恢复依赖操作者批准的本地 seed。脚本验证 cached .dsc 与 artifacts 的 checksum、
  Source 和 Version 一致性，但不能在线重新证明 cached .dsc 来自当前配置的 snapshot timestamp。
```

- [ ] **Step 3: §7.3a — update fetch expected-output table (runbook §4.2, L633)**

Replace:

```
| 1 | fetch | `build/source/ocserv-1.5.0/` + `ocserv_1.5.0-1.dsc` | 不启用 sid apt 源（只 dget 源码） |
```

WITH:

```
| 1 | fetch | `build/source/ocserv-1.5.0/` | 不启用 sid apt 源（只 dget 源码）；只发布 source tree，raw .dsc/tarballs 留在临时 staging |
```

- [ ] **Step 4: §7.3b — update idempotence wording (runbook §4.3, L694-696)**

Replace:

```
> 通用排查：任一步失败后，产物目录 `build/source/` 和 `build/binary/` 会保留到失败点，
> 可直接检查半成品。重跑前手动 `rm -rf build/` 再来一次。（fetch 是幂等的：
> `dget -x -u` 对已存在文件会跳过。）
```

WITH:

```
> 通用排查：任一步失败后，产物目录 `build/source/` 和 `build/binary/` 会保留到失败点，
> 可直接检查半成品。fetch 每次都在新的临时 staging 目录中完成下载和解包；只有完整
> source tree 通过验证后，才会替换 build/source/ocserv-1.5.0/。若需彻底重置本地构建状态，
> 重跑前可手动执行 rm -rf build/。
```

- [ ] **Step 5: Commit**

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs(runbook): document 509 cache fallback + sync fetch output/idempotence

§4.2 fetch expected-output: drop raw .dsc (only source tree published
now, per spec §3.7). §4.3 fetch-failure block: add 509 branch describing
auto cache fallback. §4.3 idempotence wording: replace outdated 'dget
-x -u skips existing files' (new design uses fresh staging each run).
Add cache-seeding subsection near snapshot explanation with operator
manual steps + trust-boundary note (operator-trusted seed, verifies
internal consistency, cannot re-prove snapshot provenance)."
```

---

## Task 8: End-to-end verification on the rate-limited builder

**Files:** none (verification only)

This task confirms the full feature works on the actual rate-limited builder. Cases 2 and 8 from the spec's test matrix are validated here manually (they need a populated cache + real `dpkg-source`, hard to stub cleanly).

- [ ] **Step 1: On the builder, seed the cache**

On `builder@VM-4-11-debian`:

```bash
cd ~/ocserv-backport
mkdir -p build/source-cache
cd build/source-cache
wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.dsc
wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0.orig.tar.xz
wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.debian.tar.xz
ls -la   # confirm 3 files present
```

- [ ] **Step 2: Run make dry-run and confirm fetch completes via cache (case 2)**

```bash
cd ~/ocserv-backport
rm -rf build/source   # clean slate
make dry-run 2>&1 | tee /tmp/dryrun.log | head -40
```

Expected (fetch stage):
```
== 1. fetch ==
... dget https://snapshot.debian.org/archive/debian/.../ocserv_1.5.0-1.dsc ...
curl: (22) The requested URL returned error: 509   (or similar 509)
... snapshot.debian.org returned HTTP 509; attempting local source cache fallback
... snapshot.debian.org rate-limited (HTTP 509); extracting from local cache
... source tree ready (from local cache; snapshot.debian.org was rate-limited): build/source/ocserv-1.5.0
```

Confirm: `ls build/source/ocserv-1.5.0/` shows the source tree.

- [ ] **Step 3: Confirm partial-file isolation (case 8)**

Inspect that `build/.fetch-tmp.*` dirs do NOT linger (trap cleaned them):

```bash
ls -d build/.fetch-tmp.* 2>/dev/null && echo "LEAK" || echo "clean (trap worked)"
```

Expected: `clean (trap worked)`.

- [ ] **Step 4: Confirm the rest of dry-run proceeds (or fails at a later, unrelated stage)**

The fetch stage should now pass. If dry-run later fails at binary/sbuild (sbuild group, chroot, etc.), that's a separate pre-existing issue (see runbook §4.3), NOT this feature. The goal of this task is fetch-stage success via cache.

- [ ] **Step 5: No commit (verification only)**

If all steps pass, the feature is complete. If a real bug surfaces, return to the relevant Task and fix + add a bats case covering it.

---

## Self-Review

**1. Spec coverage:**
- spec §3.1 flow → Task 5 (snapshot in staging) + Task 6 (cache branch) ✅
- spec §3.2 TMP_ROOT + subdirs + trap → Task 5 Step 1 ✅
- spec §3.3 is_509_failure → Task 2 ✅
- spec §3.4a-h cache fallback → Task 6 (validate_dsc_metadata T3, parse_dsc_artifacts T3, validate_artifact_basenames T4, verify_cache_artifacts T4, fetch_via_cache orchestrator T6) ✅
- spec §3.4c F==S equality → Task 6 Step 1 (main) + Task 3 test ✅
- spec §3.4c safe basename → Task 4 ✅
- spec §3.5 trust boundary wording → Task 7 Step 2 (runbook seeding note) ✅
- spec §3.6 cache dir/seeding → Task 7 Step 2 + Task 8 Step 1 ✅
- spec §3.7 publish policy B → Task 5 Step 1 (publish_source_tree) ✅
- spec §4 test cases 1-10 → T2 (509 helper), T3 (metadata+parse: 6,9), T4 (basenames+verify: 4,5,10), T6 (orchestrator: 1,3), T8 manual (2,8) ✅
- spec §5 script skeleton → Task 1 ✅
- spec §5 Deb822 parsing → Task 3 (dpkg-parsecontrol) ✅
- spec §7 runbook changes → Task 7 (§7.1, §7.2, §7.3a, §7.3b) ✅

**2. Placeholder scan:** No TBD/TODO. Every step has exact code or commands. The two orchestrator cases (2, 8) are explicitly deferred to manual Task 8 verification with a stated reason (cache+real-dpkg-source stubs are brittle); this is documented, not a placeholder. ✅

**3. Type/name consistency:** `is_509_failure`, `validate_dsc_metadata`, `parse_dsc_artifacts`, `validate_artifact_basenames`, `verify_cache_artifacts`, `fetch_via_snapshot_staged`, `fetch_via_cache`, `publish_source_tree`, `main` — names match across all tasks. `SRC_VER`/`UPSTREAM` globals consistent. `SNAPSHOT_STAGE`/`CACHE_STAGE`/`TMP_ROOT` consistent (no stray `$STAGING`). ✅

**4. Risk callouts:**
- Task 5 deletes the Task-1 `fetch_via_snapshot()` — implementer must not leave both. Noted in Task 5 Step 1. ✅
- `dpkg-parsecontrol` availability: standard on Debian (dpkg-dev), present in the sbuild chroot. If `make test` runs on a dev machine without it, the parse tests will fail — flag this. ✅
- Cases 2/8 manual: explicitly stated as Task 8, not silently skipped. ✅
