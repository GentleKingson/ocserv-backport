#!/usr/bin/env bats
load helpers/bats-helper.bash

READ_LOCK="python3 ${REPO_ROOT}/scripts/read-source-lock.py"

@test "valid lock: emits META + ARTIFACT records with correct fields" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/ocserv_1.5.0-1.yaml" <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources:
  - pool
  - snapshot
snapshot_timestamp: "20260101T000000Z"
pool_path: "main/o/ocserv"
dsc:
  name: ocserv_1.5.0-1.dsc
  size: 2234
  sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
artifacts:
  - name: ocserv_1.5.0.orig.tar.xz
    size: 100
    sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
YAML
  run $READ_LOCK --lock "$tmpd/ocserv_1.5.0-1.yaml"
  [ "$status" -eq 0 ]
  # META line: rectype source version allowed snapshot_ts pool_path dsc_name dsc_size dsc_sha256
  [ "${lines[0]}" == $'META\tocserv\t1.5.0-1\tpool,snapshot\t20260101T000000Z\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t2234\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]
  [ "${lines[1]}" == $'ARTIFACT\tocserv_1.5.0.orig.tar.xz\t100\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]
  rm -rf "$tmpd"
}

# make_lock <content> → writes content to a fresh tmpd/lock.yaml; sets globals
# MAKE_LOCK_DIR (the temp dir, for cleanup) and echoes the lock path.
# NOTE: command substitution ($()) runs in a subshell, so we cannot rely on a
# side-effect-set tmpd in the caller. Use MAKE_LOCK_DIR + cleanup_make_lock instead.
make_lock() {
  MAKE_LOCK_DIR="$(mktemp -d)"
  printf '%s' "$1" > "$MAKE_LOCK_DIR/lock.yaml"
  echo "$MAKE_LOCK_DIR/lock.yaml"
}
cleanup_make_lock() { [[ -n "${MAKE_LOCK_DIR:-}" ]] && rm -rf "$MAKE_LOCK_DIR"; MAKE_LOCK_DIR=""; return 0; }

@test "rejects: --source without --debian-version (arg error)" {
  run $READ_LOCK --source ocserv
  [ "$status" -eq 2 ]
}

@test "rejects: --lock and --source both given (arg error)" {
  run $READ_LOCK --lock /tmp/x.yaml --source ocserv --debian-version 1.5.0-1
  [ "$status" -eq 2 ]
}

@test "rejects: duplicate YAML key" {
  body='source: ocserv
source: other'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_make_lock
  [ "$status" -eq 1 ]
}

@test "rejects: unknown top-level field" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/o/ocserv"
dsc: {name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
bogus: 1'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_make_lock
  [ "$status" -eq 1 ]
}

@test "rejects: epoch in debian_version" {
  body='debian_version: "1:1.5.0-1"'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_make_lock
  [ "$status" -eq 1 ]
}

@test "rejects: snapshot allowed but no timestamp" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [snapshot]
dsc: {name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_make_lock
  [ "$status" -eq 1 ]
}

@test "rejects: pool_path with ../ segment" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/../etc"
dsc: {name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_make_lock
  [ "$status" -eq 1 ]
}

@test "rejects: pool_path as full URL" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "https://evil.invalid/x"
dsc: {name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_make_lock
  [ "$status" -eq 1 ]
}

@test "rejects: artifact name == dsc.name" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/o/ocserv"
dsc: {name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_make_lock
  [ "$status" -eq 1 ]
}

@test "rejects: dsc.name not ending .dsc" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/o/ocserv"
dsc: {name: o.txt, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_make_lock
  [ "$status" -eq 1 ]
}

@test "rejects: YAML bool as size" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/o/ocserv"
dsc: {name: o.dsc, size: true, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_make_lock
  [ "$status" -eq 1 ]
}

@test "rejects: uppercase sha256" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/o/ocserv"
dsc: {name: o.dsc, size: 1, sha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_make_lock
  [ "$status" -eq 1 ]
}
