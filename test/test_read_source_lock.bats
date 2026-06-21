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
