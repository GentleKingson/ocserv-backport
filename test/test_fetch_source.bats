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

# ---- validate_dsc_metadata (spec §3.4b) ----

@test "validate_dsc_metadata: accepts Source=ocserv Version=1.5.0-1" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
Format: 3.0 (quilt)
Source: ocserv
Version: 1.5.0-1
DSC
  call_func "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rm -rf "$tmpd"; [ "$status" -eq 0 ]
}

@test "validate_dsc_metadata: rejects wrong Source" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
Source: otherpkg
Version: 1.5.0-1
DSC
  call_func "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "validate_dsc_metadata: rejects wrong Version" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
Source: ocserv
Version: 1.4.0-1
DSC
  call_func "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

# ---- parse_dsc_artifacts (spec §3.4c) ----
# Prints two lines: line 1 = F, line 2 = S. Each is space-separated basenames,
# ORDER PRESERVED, DUPLICATES KEPT. Caller normalizes (sort -u) only AFTER
# dup/basename validation in Task 4, so a duplicated filename is detectable.

@test "parse_dsc_artifacts: equal F/S for well-formed .dsc" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
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
  call_func "parse_dsc_artifacts '$tmpd/x.dsc'"
  if [ "$status" -ne 0 ]; then rm -rf "$tmpd"; fail "parse failed"; fi
  f_norm="$(printf '%s\n' "${lines[0]}" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  s_norm="$(printf '%s\n' "${lines[1]}" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  rm -rf "$tmpd"
  [ "$f_norm" == "$s_norm" ]
}

@test "parse_dsc_artifacts: dies when Checksums-Sha256 stanza absent" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
Source: ocserv
Version: 1.5.0-1
Files:
 1234 ocserv_1.5.0.orig.tar.xz
DSC
  call_func "parse_dsc_artifacts '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "parse_dsc_artifacts: unequal F/S when SHA256 partial (case 9)" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
Files:
 1234 ocserv_1.5.0.orig.tar.xz
 5678 ocserv_1.5.0-1.debian.tar.xz
Checksums-Sha256:
 abcd ocserv_1.5.0.orig.tar.xz
DSC
  call_func "parse_dsc_artifacts '$tmpd/x.dsc'"
  if [ "$status" -ne 0 ]; then rm -rf "$tmpd"; fail "parse should succeed (unequal sets detected by caller)"; fi
  f_norm="$(printf '%s\n' "${lines[0]}" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  s_norm="$(printf '%s\n' "${lines[1]}" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  rm -rf "$tmpd"
  [ "$f_norm" != "$s_norm" ]
}

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
# Uses a temp dir as fake cache. $tmpd set in bats, passed into call_func's
# bash -c via single-quote expansion (bats expands it before bash sees it).

@test "verify_cache_artifacts: passes when all files present" {
  tmpd="$(mktemp -d)"
  touch "$tmpd/ocserv_1.5.0.orig.tar.xz" "$tmpd/ocserv_1.5.0-1.debian.tar.xz"
  call_func "verify_cache_artifacts '$tmpd' 'ocserv_1.5.0.orig.tar.xz ocserv_1.5.0-1.debian.tar.xz'"
  rm -rf "$tmpd"; [ "$status" -eq 0 ]
}

@test "verify_cache_artifacts: dies naming missing files" {
  tmpd="$(mktemp -d)"
  touch "$tmpd/ocserv_1.5.0.orig.tar.xz"
  call_func "verify_cache_artifacts '$tmpd' 'ocserv_1.5.0.orig.tar.xz ocserv_1.5.0-1.debian.tar.xz'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

# ---- main() orchestrator tests (cases 1, 2, 3, 8) with stubs ----
# We stub dget/dpkg-source by prepending a fake bin dir to PATH.
# Helper: write a minimal valid cached .dsc + its two artifacts into a cache dir.
# NOTE: uses printf (not a heredoc) because bats' test-body line rewriting
# breaks multi-line heredocs inside helper functions (verified: cachedir existed
# but the cat<<DSC heredoc failed under bats). Heredocs in test BODIES work fine.
write_fixture_cache() {
  local cachedir="$1"
  mkdir -p "$cachedir"
  # Real ocserv 1.5.0-1 .dsc references 4 files incl. the .asc signature
  # (verified on the trixie builder during Task 8). Keep the fixture realistic
  # so the dsc-driven artifact list exercises the .asc path.
  printf '%s\n' \
    'Format: 3.0 (quilt)' \
    'Source: ocserv' \
    'Version: 1.5.0-1' \
    'Files:' \
    ' 0000 ocserv_1.5.0.orig.tar.xz' \
    ' 0000 ocserv_1.5.0.orig.tar.xz.asc' \
    ' 0000 ocserv_1.5.0-1.debian.tar.xz' \
    'Checksums-Sha256:' \
    ' 0000 ocserv_1.5.0.orig.tar.xz' \
    ' 0000 ocserv_1.5.0.orig.tar.xz.asc' \
    ' 0000 ocserv_1.5.0-1.debian.tar.xz' \
    > "$cachedir/ocserv_1.5.0-1.dsc"
  touch "$cachedir/ocserv_1.5.0.orig.tar.xz" "$cachedir/ocserv_1.5.0.orig.tar.xz.asc" "$cachedir/ocserv_1.5.0-1.debian.tar.xz"
}

@test "main: dget success → publishes source tree (case 1)" {
  tmprepo="$(mktemp -d)"; fakebin="$(mktemp -d)"
  cat > "$fakebin/dget" <<'SH'
#!/usr/bin/env bash
mkdir -p "$(pwd)/ocserv-1.5.0"
echo "fake-source" > "$(pwd)/ocserv-1.5.0/configure.ac"
echo "stub dget ok"
SH
  chmod +x "$fakebin/dget"
  ( cd "$tmprepo" && mkdir -p build && \
    PATH="$fakebin:$PATH" DEBIAN_SNAPSHOT_TIMESTAMP=20260101T000000Z \
      bash "${REPO_ROOT}/scripts/fetch-source.sh" 2>/dev/null ) || true
  [ -f "$tmprepo/build/source/ocserv-1.5.0/configure.ac" ]
  rm -rf "$tmprepo" "$fakebin"
}

@test "main: non-509 dget failure → dies, no cache use (case 3)" {
  tmprepo="$(mktemp -d)"; fakebin="$(mktemp -d)"
  cat > "$fakebin/dget" <<'SH'
#!/usr/bin/env bash
echo "curl: (22) The requested URL returned error: 404" >&2
false
SH
  chmod +x "$fakebin/dget"
  # No cache seeded. Non-509 must die WITHOUT attempting cache fallback.
  # Assert: script exits non-zero AND build/source/ was never published
  # (proves the cache path was never reached).
  rc=0
  ( cd "$tmprepo" && mkdir -p build && \
    PATH="$fakebin:$PATH" DEBIAN_SNAPSHOT_TIMESTAMP=20260101T000000Z \
      bash "${REPO_ROOT}/scripts/fetch-source.sh" ) >"$tmprepo/out.log" 2>&1 || rc=$?
  published=$([ -d "$tmprepo/build/source/ocserv-1.5.0" ] && echo yes || echo no)
  rm -rf "$tmprepo" "$fakebin"
  [ "$rc" -ne 0 ]
  [ "$published" == "no" ]
}

@test "main: 509 + complete cache → fallback succeeds (case 2)" {
  tmprepo="$(mktemp -d)"; fakebin="$(mktemp -d)"
  # fake dget: drops a PARTIAL artifact in staging, emits 509, fails.
  cat > "$fakebin/dget" <<'SH'
#!/usr/bin/env bash
: > ocserv_1.5.0.orig.tar.xz.partial
echo "curl: (22) The requested URL returned error: 509" >&2
false
SH
  # fake dpkg-source: must run from CACHE_STAGE (no .partial there), creates tree.
  cat > "$fakebin/dpkg-source" <<'SH'
#!/usr/bin/env bash
outdir="$4"
if ls *.partial >/dev/null 2>&1; then
  echo "CONTAMINATION: .partial visible to dpkg-source" >&2
  exit 99
fi
mkdir -p "$outdir"; echo "from-cache" > "$outdir/MARKER"
SH
  chmod +x "$fakebin/dget" "$fakebin/dpkg-source"
  write_fixture_cache "$tmprepo/build/source-cache"
  ( cd "$tmprepo" && mkdir -p build && \
    PATH="$fakebin:$PATH" DEBIAN_SNAPSHOT_TIMESTAMP=20260101T000000Z \
      bash "${REPO_ROOT}/scripts/fetch-source.sh" 2>/dev/null ) || true
  # Source tree published AND carries the cache marker (not snapshot partial).
  [ -f "$tmprepo/build/source/ocserv-1.5.0/MARKER" ]
  [ "$(cat "$tmprepo/build/source/ocserv-1.5.0/MARKER")" == "from-cache" ]
  # No staging leak (case 8): trap removed TMP_ROOT.
  [ -z "$(ls -d "$tmprepo"/build/.fetch-tmp.* 2>/dev/null)" ]
  rm -rf "$tmprepo" "$fakebin"
}

@test "main: 509 + partial snapshot output does not contaminate cache path (case 8)" {
  tmprepo="$(mktemp -d)"; fakebin="$(mktemp -d)"
  cat > "$fakebin/dget" <<'SH'
#!/usr/bin/env bash
: > ocserv_1.5.0.orig.tar.xz.partial
mkdir -p ocserv-1.5.0-partial-junk
echo "HTTP/2 509" >&2
false
SH
  cat > "$fakebin/dpkg-source" <<'SH'
#!/usr/bin/env bash
outdir="$4"
if ls *.partial >/dev/null 2>&1 || ls -d *partial-junk >/dev/null 2>&1; then
  echo "CONTAMINATION detected" >&2
  exit 99
fi
mkdir -p "$outdir"; echo "ok" > "$outdir/MARKER"
SH
  chmod +x "$fakebin/dget" "$fakebin/dpkg-source"
  write_fixture_cache "$tmprepo/build/source-cache"
  ( cd "$tmprepo" && mkdir -p build && \
    PATH="$fakebin:$PATH" DEBIAN_SNAPSHOT_TIMESTAMP=20260101T000000Z \
      bash "${REPO_ROOT}/scripts/fetch-source.sh" ) >"$tmprepo/out.log" 2>&1 || true
  # Published tree exists (dpkg-source did not hit contamination exit 99).
  [ -f "$tmprepo/build/source/ocserv-1.5.0/MARKER" ]
  rm -rf "$tmprepo" "$fakebin"
}
