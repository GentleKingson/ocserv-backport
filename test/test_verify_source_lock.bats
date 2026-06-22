#!/usr/bin/env bats
load helpers/bats-helper.bash

EXPECTED_TSV=$'META\tocserv\t1.5.0-1\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t2761\t20b758de26a7a372707556ec2e3bb1f847257efaa0d04b40783c20d91a82d9dc\nARTIFACT\tocserv_1.5.0.orig.tar.xz\t547428\t42ced08958b9576ab134fcb7bdc7f8df5e13214fd147855f99021fedcf0eedbe\nARTIFACT\tocserv_1.5.0.orig.tar.xz.asc\t667\t2e8d560879f84643260cc61d1723bd49219042ea9967eb52d99af32a498673c7\nARTIFACT\tocserv_1.5.0-1.debian.tar.xz\t26864\t36f1701707453c83ea97e0de2f776f3d9ed3ad6c7943c443bbb3a91fe36f0c4c'

setup_verify_repo() {
  VERIFY_REPO="$(mktemp -d)"
  mkdir -p "${VERIFY_REPO}/scripts" "${VERIFY_REPO}/source-lock/ocserv"
  cp "${REPO_ROOT}/scripts/read-source-lock.py" "${VERIFY_REPO}/scripts/read-source-lock.py"
  if [[ -f "${REPO_ROOT}/scripts/verify-source-lock.sh" ]]; then
    cp "${REPO_ROOT}/scripts/verify-source-lock.sh" "${VERIFY_REPO}/scripts/verify-source-lock.sh"
  fi
  write_valid_yaml "${VERIFY_REPO}/source-lock/ocserv/1.5.0-1.yaml"
  printf '%s\n' "${EXPECTED_TSV}" > "${VERIFY_REPO}/source-lock/ocserv/1.5.0-1.lock.tsv"
}

teardown_verify_repo() {
  [[ -n "${VERIFY_REPO:-}" ]] && rm -rf "${VERIFY_REPO}"
  VERIFY_REPO=""
}

write_valid_yaml() {
  cat > "$1" <<'YAML'
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

run_verify() {
  run bash -c "cd '${VERIFY_REPO}' && PATH='${FAKEBIN:-}:${PATH}' bash scripts/verify-source-lock.sh"
}

@test "verify-source-lock succeeds when all projections match" {
  setup_verify_repo
  run_verify
  teardown_verify_repo
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"source locks verified"* ]]
}

@test "verify-source-lock fails with unified diff on TSV drift" {
  setup_verify_repo
  printf '%s\n' "${EXPECTED_TSV/2761/2762}" > "${VERIFY_REPO}/source-lock/ocserv/1.5.0-1.lock.tsv"
  run_verify
  teardown_verify_repo
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"lock.tsv drift"* ]]
  [[ "${output}" == *"---"* ]]
  [[ "${output}" == *"+++"* ]]
}

@test "verify-source-lock fails when TSV is missing" {
  setup_verify_repo
  rm -f "${VERIFY_REPO}/source-lock/ocserv/1.5.0-1.lock.tsv"
  run_verify
  teardown_verify_repo
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"missing lock.tsv"* ]]
}

@test "verify-source-lock fails on orphan TSV" {
  setup_verify_repo
  printf '%s\n' "${EXPECTED_TSV}" > "${VERIFY_REPO}/source-lock/ocserv/orphan.lock.tsv"
  run_verify
  teardown_verify_repo
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"orphan lock.tsv"* ]]
}

@test "verify-source-lock fails on invalid YAML" {
  setup_verify_repo
  printf 'schema_version: 1\nsource: ocserv\nsource: other\n' > "${VERIFY_REPO}/source-lock/ocserv/1.5.0-1.yaml"
  run_verify
  teardown_verify_repo
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"parser failed"* ]]
}

@test "verify-source-lock cleans its temporary directory" {
  setup_verify_repo
  tmpbase="${VERIFY_REPO}/tmp"
  mkdir -p "${tmpbase}"
  run bash -c "cd '${VERIFY_REPO}' && TMPDIR='${tmpbase}' bash scripts/verify-source-lock.sh"
  [ "${status}" -eq 0 ]
  found="$(find "${tmpbase}" -mindepth 1 -maxdepth 1 -name 'verify-lock.*' -print -quit)"
  teardown_verify_repo
  [ -z "${found}" ]
}

@test "verify-source-lock does not access network" {
  setup_verify_repo
  FAKEBIN="${VERIFY_REPO}/fakebin"
  mkdir -p "${FAKEBIN}"
  cat > "${FAKEBIN}/curl" <<'SH'
#!/usr/bin/env bash
echo "curl must not be called" >&2
exit 99
SH
  cat > "${FAKEBIN}/wget" <<'SH'
#!/usr/bin/env bash
echo "wget must not be called" >&2
exit 99
SH
  chmod +x "${FAKEBIN}/curl" "${FAKEBIN}/wget"
  run_verify
  teardown_verify_repo
  [ "${status}" -eq 0 ]
}
