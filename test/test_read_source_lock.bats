#!/usr/bin/env bats
load helpers/bats-helper.bash

READ_LOCK="python3 ${REPO_ROOT}/scripts/read-source-lock.py"

make_lock_tree() {
  LOCK_TREE="$(mktemp -d)"
  mkdir -p "${LOCK_TREE}/ocserv"
  LOCK_PATH="${LOCK_TREE}/ocserv/1.5.0-1.yaml"
}

cleanup_lock_tree() {
  [[ -n "${LOCK_TREE:-}" ]] && rm -rf "${LOCK_TREE}"
  LOCK_TREE=""
  LOCK_PATH=""
}

write_valid_lock() {
  cat > "${LOCK_PATH}" <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc:
  name: ocserv_1.5.0-1.dsc
  size: 2761
  sha256: "20b758de26a7a372707556ec2e3bb1f847257efaa0d04b40783c20d91a82d9dc"
artifacts:
  - name: ocserv_1.5.0.orig.tar.xz
    size: 547428
    sha256: "42ced08958b9576ab134fcb7bdc7f8df5e13214fd147855f99021fedcf0eedbe"
  - name: ocserv_1.5.0.orig.tar.xz.asc
    size: 667
    sha256: "2e8d560879f84643260cc61d1723bd49219042ea9967eb52d99af32a498673c7"
  - name: ocserv_1.5.0-1.debian.tar.xz
    size: 26864
    sha256: "36f1701707453c83ea97e0de2f776f3d9ed3ad6c7943c443bbb3a91fe36f0c4c"
YAML
}

write_lock_body() {
  make_lock_tree
  cat > "${LOCK_PATH}"
}

assert_invalid_lock_body() {
  write_lock_body
  run ${READ_LOCK} --lock "${LOCK_PATH}"
  cleanup_lock_tree
  [ "${status}" -eq 1 ]
}

@test "valid pool-only lock emits narrowed deterministic TSV" {
  make_lock_tree
  write_valid_lock
  run ${READ_LOCK} --lock "${LOCK_PATH}"
  cleanup_lock_tree
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" == $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t2761\t20b758de26a7a372707556ec2e3bb1f847257efaa0d04b40783c20d91a82d9dc' ]
  [ "${lines[1]}" == $'ARTIFACT\tocserv_1.5.0.orig.tar.xz\t547428\t42ced08958b9576ab134fcb7bdc7f8df5e13214fd147855f99021fedcf0eedbe' ]
  [ "${lines[2]}" == $'ARTIFACT\tocserv_1.5.0.orig.tar.xz.asc\t667\t2e8d560879f84643260cc61d1723bd49219042ea9967eb52d99af32a498673c7' ]
  [ "${lines[3]}" == $'ARTIFACT\tocserv_1.5.0-1.debian.tar.xz\t26864\t36f1701707453c83ea97e0de2f776f3d9ed3ad6c7943c443bbb3a91fe36f0c4c' ]
}

@test "rejects --source without --debian-version" {
  run ${READ_LOCK} --source ocserv
  [ "${status}" -eq 2 ]
}

@test "rejects --lock and --source both given" {
  run ${READ_LOCK} --lock /tmp/x.yaml --source ocserv --debian-version 1.5.0-1
  [ "${status}" -eq 2 ]
}

@test "rejects top-level duplicate key" {
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
source: other
YAML
}

@test "rejects nested duplicate key" {
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc:
  name: ocserv_1.5.0-1.dsc
  name: other.dsc
  size: 1
  sha256: "0000000000000000000000000000000000000000000000000000000000000000"
artifacts:
  - name: a.tar
    size: 1
    sha256: "0000000000000000000000000000000000000000000000000000000000000000"
YAML
}

@test "rejects unknown top-level field" {
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
bogus: 1
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
}

@test "rejects removed acquisition fields" {
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
snapshot_timestamp: "20260101T000000Z"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
}

@test "rejects cache/source manifest fields by unknown-field policy" {
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
cache_meta: true
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
}

@test "rejects missing pool_path" {
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
}

@test "rejects unsafe pool_path forms" {
  for pool_path in "/main/o/ocserv" "main/../etc" "https://evil.invalid/x" "main/o/ocserv?x=1" "main/o/ocserv#frag" "main/o/oc serv"; do
    make_lock_tree
    cat > "${LOCK_PATH}" <<YAML
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "${pool_path}"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
    run ${READ_LOCK} --lock "${LOCK_PATH}"
    cleanup_lock_tree
    [ "${status}" -eq 1 ]
  done
}

@test "rejects pool_path with control character" {
  make_lock_tree
  printf 'schema_version: 1\nsource: ocserv\ndebian_version: "1.5.0-1"\npool_path: "main/o/ocserv\a"\ndsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}\nartifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]\n' > "${LOCK_PATH}"
  run ${READ_LOCK} --lock "${LOCK_PATH}"
  cleanup_lock_tree
  [ "${status}" -eq 1 ]
}

@test "rejects invalid source and debian_version" {
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: BadSource
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1:1.5.0-1"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
}

@test "rejects invalid sizes and sha256" {
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: true, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: -1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "nothex"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
YAML
}

@test "rejects invalid artifact sets and names" {
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: []
YAML
  for name in "ocserv_1.5.0-1.dsc" "../x.tar" "-x.tar"; do
    make_lock_tree
    cat > "${LOCK_PATH}" <<YAML
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts:
  - name: ${name}
    size: 1
    sha256: "0000000000000000000000000000000000000000000000000000000000000000"
YAML
    run ${READ_LOCK} --lock "${LOCK_PATH}"
    cleanup_lock_tree
    [ "${status}" -eq 1 ]
  done
  assert_invalid_lock_body <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts:
  - {name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
  - {name: a.tar, size: 2, sha256: "1111111111111111111111111111111111111111111111111111111111111111"}
YAML
}

@test "rejects lock path source/version mismatch" {
  make_lock_tree
  write_valid_lock
  mkdir -p "${LOCK_TREE}/other"
  mv "${LOCK_PATH}" "${LOCK_TREE}/other/1.5.0-1.yaml"
  run ${READ_LOCK} --lock "${LOCK_TREE}/other/1.5.0-1.yaml"
  cleanup_lock_tree
  [ "${status}" -eq 1 ]

  make_lock_tree
  write_valid_lock
  mv "${LOCK_PATH}" "${LOCK_TREE}/ocserv/9.9.9-9.yaml"
  run ${READ_LOCK} --lock "${LOCK_TREE}/ocserv/9.9.9-9.yaml"
  cleanup_lock_tree
  [ "${status}" -eq 1 ]
}
