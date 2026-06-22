#!/usr/bin/env bats
load helpers/bats-helper.bash

call_dsc() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/_dsc.sh'; $*"
}

@test "validate_dsc_metadata: accepts correct Source/Version" {
  tmpd="$(mktemp -d)"
  printf '%s\n' 'Format: 3.0 (quilt)' 'Source: ocserv' 'Version: 1.5.0-1' > "$tmpd/x.dsc"
  call_dsc "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rm -rf "$tmpd"; [ "$status" -eq 0 ]
}

@test "validate_dsc_metadata: rejects wrong Version" {
  tmpd="$(mktemp -d)"
  printf '%s\n' 'Source: ocserv' 'Version: 1.4.0-1' > "$tmpd/x.dsc"
  call_dsc "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "parse_dsc_full: emits name<TAB>size<TAB>sha256 per artifact, Files==Checksums" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Format: 3.0 (quilt)' 'Source: ocserv' 'Version: 1.5.0-1' \
    'Files:' \
    ' 1111 2222 ocserv_1.5.0.orig.tar.xz' \
    ' 3333 4444 ocserv_1.5.0-1.debian.tar.xz' \
    'Checksums-Sha256:' \
    ' aaaa 2222 ocserv_1.5.0.orig.tar.xz' \
    ' bbbb 4444 ocserv_1.5.0-1.debian.tar.xz' > "$tmpd/x.dsc"
  call_dsc "parse_dsc_full '$tmpd/x.dsc'"
  rm -rf "$tmpd"
  [ "$status" -eq 0 ]
  # Each line: name<TAB>size<TAB>sha256, order preserved
  [ "${lines[0]}" == $'ocserv_1.5.0.orig.tar.xz\t2222\taaaa' ]
  [ "${lines[1]}" == $'ocserv_1.5.0-1.debian.tar.xz\t4444\tbbbb' ]
}

@test "dsc_artifacts_match_lock: passes when dsc == lock mapping" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Files:' ' 1 100 a.tar' \
    'Checksums-Sha256:' ' sha1 100 a.tar' > "$tmpd/x.dsc"
  # ARTIFACT_NAME / ARTIFACT_SIZE / ARTIFACT_SHA256 arrays set by caller
  call_dsc "ARTIFACT_NAME=(a.tar); ARTIFACT_SIZE=(100); ARTIFACT_SHA256=(sha1); dsc_artifacts_match_lock '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -eq 0 ]
}

@test "dsc_artifacts_match_lock: dies when sha256 differs" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Files:' ' 1 100 a.tar' \
    'Checksums-Sha256:' ' evil 100 a.tar' > "$tmpd/x.dsc"
  call_dsc "ARTIFACT_NAME=(a.tar); ARTIFACT_SIZE=(100); ARTIFACT_SHA256=(sha1); dsc_artifacts_match_lock '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "validate_artifact_basenames: rejects path traversal" {
  call_dsc "validate_artifact_basenames 'a.tar ../../etc/passwd'"
  [ "$status" -ne 0 ]
}

@test "validate_artifact_basenames: rejects dash-prefixed names" {
  call_dsc "validate_artifact_basenames 'a.tar -evil.tar'"
  [ "$status" -ne 0 ]
}

# ---- parse_dsc_full strict cross-check (review fix #2) ----

@test "parse_dsc_full: dies when Checksums-Sha256 has a file NOT in Files" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Files:' ' 1 100 a.tar' \
    'Checksums-Sha256:' ' sha1 100 a.tar' ' sha2 200 b.tar' > "$tmpd/x.dsc"
  call_dsc "parse_dsc_full '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "parse_dsc_full: dies when Files has a file NOT in Checksums-Sha256" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Files:' ' 1 100 a.tar' ' 2 200 b.tar' \
    'Checksums-Sha256:' ' sha1 100 a.tar' > "$tmpd/x.dsc"
  call_dsc "parse_dsc_full '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "parse_dsc_full: dies on duplicate filename in Files" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Files:' ' 1 100 a.tar' ' 2 100 a.tar' \
    'Checksums-Sha256:' ' sha1 100 a.tar' > "$tmpd/x.dsc"
  call_dsc "parse_dsc_full '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "parse_dsc_full: dies on duplicate filename in Checksums-Sha256" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Files:' ' 1 100 a.tar' \
    'Checksums-Sha256:' ' sha1 100 a.tar' ' sha2 100 a.tar' > "$tmpd/x.dsc"
  call_dsc "parse_dsc_full '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "parse_dsc_full: dies on malformed Files row (not 3 fields)" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Files:' ' onlyonefield' \
    'Checksums-Sha256:' ' sha1 100 a.tar' > "$tmpd/x.dsc"
  call_dsc "parse_dsc_full '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "parse_dsc_full: dies on unsafe basename" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Files:' ' 1 100 -bad.tar' \
    'Checksums-Sha256:' ' sha1 100 -bad.tar' > "$tmpd/x.dsc"
  call_dsc "parse_dsc_full '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}
