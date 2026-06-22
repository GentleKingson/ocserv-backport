#!/usr/bin/env bats
load helpers/bats-helper.bash

call_tsv() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/_lock_tsv.sh'; $*"
}

VALID_TSV=$'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t2761\t20b758de26a7a372707556ec2e3bb1f847257efaa0d04b40783c20d91a82d9dc\nARTIFACT\tocserv_1.5.0.orig.tar.xz\t547428\t42ced08958b9576ab134fcb7bdc7f8df5e13214fd147855f99021fedcf0eedbe\nARTIFACT\tocserv_1.5.0.orig.tar.xz.asc\t667\t2e8d560879f84643260cc61d1723bd49219042ea9967eb52d99af32a498673c7\nARTIFACT\tocserv_1.5.0-1.debian.tar.xz\t26864\t36f1701707453c83ea97e0de2f776f3d9ed3ad6c7943c443bbb3a91fe36f0c4c'

with_tsv() {
  TSV_FILE="$(mktemp)"
  printf '%s\n' "$1" > "${TSV_FILE}"
}

cleanup_tsv() {
  [[ -n "${TSV_FILE:-}" ]] && rm -f "${TSV_FILE}"
  TSV_FILE=""
}

@test "read_lock_tsv: valid narrowed TSV fills globals and artifacts" {
  with_tsv "${VALID_TSV}"
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1; echo SRC=\$META_SOURCE VER=\$META_DEBIAN_VERSION POOL=\$META_POOL_PATH DSC=\$META_DSC_NAME COUNT=\${#ARTIFACT_NAME[@]}"
  cleanup_tsv
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"SRC=ocserv VER=1.5.0-1 POOL=main/o/ocserv DSC=ocserv_1.5.0-1.dsc COUNT=3"* ]]
}

@test "read_lock_tsv: rejects CRLF" {
  TSV_FILE="$(mktemp)"
  printf '%s\r\n' "${VALID_TSV}" > "${TSV_FILE}"
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"
  cleanup_tsv
  [ "${status}" -ne 0 ]
}

@test "read_lock_tsv: rejects META not first, multiple META, missing META, and zero artifacts" {
  with_tsv $'ARTIFACT\tx\t1\t0000000000000000000000000000000000000000000000000000000000000000\nMETA\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv "${VALID_TSV}"$'\nMETA\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv $'ARTIFACT\ta.tar\t1\t0000000000000000000000000000000000000000000000000000000000000000'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]
}

@test "read_lock_tsv: rejects extra and missing fields" {
  with_tsv $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\textra\nARTIFACT\ta.tar\t1\t1111111111111111111111111111111111111111111111111111111111111111'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t1\nARTIFACT\ta.tar\t1\t1111111111111111111111111111111111111111111111111111111111111111'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\nARTIFACT\ta.tar\t1'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\nARTIFACT\ta.tar\t1\t1111111111111111111111111111111111111111111111111111111111111111\textra'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]
}

@test "read_lock_tsv: rejects duplicate artifact and artifact equal to dsc" {
  with_tsv $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\nARTIFACT\ta.tar\t1\t1111111111111111111111111111111111111111111111111111111111111111\nARTIFACT\ta.tar\t2\t2222222222222222222222222222222222222222222222222222222222222222'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\nARTIFACT\tocserv_1.5.0-1.dsc\t1\t1111111111111111111111111111111111111111111111111111111111111111'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]
}

@test "read_lock_tsv: rejects unsafe pool_path and names" {
  for pool_path in "/main/o/ocserv" "main/../etc" "https://evil.invalid/x" "main/o/ocserv?x=1" "main/o/ocserv#frag" "main/o/oc serv"; do
    with_tsv $'META\tocserv\t1.5.0-1\t'"${pool_path}"$'\tocserv_1.5.0-1.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\nARTIFACT\ta.tar\t1\t1111111111111111111111111111111111111111111111111111111111111111'
    call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]
  done

  with_tsv $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tsub/dir/x.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\nARTIFACT\ta.tar\t1\t1111111111111111111111111111111111111111111111111111111111111111'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.txt\t1\t0000000000000000000000000000000000000000000000000000000000000000\nARTIFACT\ta.tar\t1\t1111111111111111111111111111111111111111111111111111111111111111'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv $'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\nARTIFACT\t-bad.tar\t1\t1111111111111111111111111111111111111111111111111111111111111111'
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]
}

@test "read_lock_tsv: rejects source/version mismatch and bad scalar formats" {
  with_tsv "${VALID_TSV/META	ocserv/META	otherpkg}"
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv "${VALID_TSV}"
  call_tsv "read_lock_tsv '${TSV_FILE}' 9.9.9-9"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv "${VALID_TSV/2761/abc}"
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]

  with_tsv "${VALID_TSV/20b758de26a7a372707556ec2e3bb1f847257efaa0d04b40783c20d91a82d9dc/20B758DE26A7A372707556EC2E3BB1F847257EFAA0D04B40783C20D91A82D9DC}"
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"; cleanup_tsv; [ "${status}" -ne 0 ]
}

@test "read_lock_tsv: rejects old snapshot/cache TSV schema" {
  old_schema=$'META\tocserv\t1.5.0-1\tpool,snapshot\t20260101T000000Z\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t2761\t20b758de26a7a372707556ec2e3bb1f847257efaa0d04b40783c20d91a82d9dc\nARTIFACT\tocserv_1.5.0.orig.tar.xz\t547428\t42ced08958b9576ab134fcb7bdc7f8df5e13214fd147855f99021fedcf0eedbe'
  with_tsv "${old_schema}"
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1"
  cleanup_tsv
  [ "${status}" -ne 0 ]
}

@test "write_expected_sha256sums: dsc first, artifacts in lock order" {
  with_tsv "${VALID_TSV}"
  out="$(mktemp)"
  call_tsv "read_lock_tsv '${TSV_FILE}' 1.5.0-1 && write_expected_sha256sums '${out}'; cat '${out}'"
  rm -f "${out}"
  cleanup_tsv
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" == "20b758de26a7a372707556ec2e3bb1f847257efaa0d04b40783c20d91a82d9dc  ocserv_1.5.0-1.dsc" ]
  [ "${lines[1]}" == "42ced08958b9576ab134fcb7bdc7f8df5e13214fd147855f99021fedcf0eedbe  ocserv_1.5.0.orig.tar.xz" ]
  [ "${lines[2]}" == "2e8d560879f84643260cc61d1723bd49219042ea9967eb52d99af32a498673c7  ocserv_1.5.0.orig.tar.xz.asc" ]
  [ "${lines[3]}" == "36f1701707453c83ea97e0de2f776f3d9ed3ad6c7943c443bbb3a91fe36f0c4c  ocserv_1.5.0-1.debian.tar.xz" ]
}
