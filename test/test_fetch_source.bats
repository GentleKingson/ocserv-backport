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
  rc=$?; rm -rf "$tmpd"; [ "$rc" -eq 0 ]
}

@test "validate_dsc_metadata: rejects wrong Source" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
Source: otherpkg
Version: 1.5.0-1
DSC
  call_func "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rc=$?; rm -rf "$tmpd"; [ "$rc" -ne 0 ]
}

@test "validate_dsc_metadata: rejects wrong Version" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/x.dsc" <<'DSC'
Source: ocserv
Version: 1.4.0-1
DSC
  call_func "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rc=$?; rm -rf "$tmpd"; [ "$rc" -ne 0 ]
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
  rc=$?
  if [ "$rc" -ne 0 ]; then rm -rf "$tmpd"; fail "parse failed"; fi
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
  rc=$?; rm -rf "$tmpd"; [ "$rc" -ne 0 ]
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
  rc=$?
  if [ "$rc" -ne 0 ]; then rm -rf "$tmpd"; fail "parse should succeed (unequal sets detected by caller)"; fi
  f_norm="$(printf '%s\n' "${lines[0]}" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  s_norm="$(printf '%s\n' "${lines[1]}" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
  rm -rf "$tmpd"
  [ "$f_norm" != "$s_norm" ]
}
