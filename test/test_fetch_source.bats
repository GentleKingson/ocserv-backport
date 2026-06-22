#!/usr/bin/env bats
load helpers/bats-helper.bash

setup_fetch_repo() {
  FETCH_REPO="$(mktemp -d)"
  mkdir -p "${FETCH_REPO}/scripts" "${FETCH_REPO}/source-lock/ocserv" "${FETCH_REPO}/fixtures"
  for file in _common.sh _dsc.sh _lock_tsv.sh read-source-lock.py verify-source-lock.sh fetch-source.sh; do
    cp "${REPO_ROOT}/scripts/${file}" "${FETCH_REPO}/scripts/${file}"
  done
}

teardown_fetch_repo() {
  [[ -n "${FETCH_REPO:-}" ]] && rm -rf "${FETCH_REPO}"
  [[ -n "${FAKEBIN:-}" ]] && rm -rf "${FAKEBIN}"
  FETCH_REPO=""
  FAKEBIN=""
}

sha256_of_file() {
  sha256sum "$1" | awk '{print $1}'
}

write_fixture_dsc() {
  local source="${1:-ocserv}" version="${2:-1.5.0-1}" artifact="${3:-ocserv_1.5.0.orig.tar.xz}"
  local artifact_size="${4:-3}" artifact_sha="${5:-ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad}"
  cat > "${FETCH_REPO}/fixtures/ocserv_1.5.0-1.dsc" <<DSC
Format: 3.0 (quilt)
Source: ${source}
Version: ${version}
Files:
 1111 ${artifact_size} ${artifact}
Checksums-Sha256:
 ${artifact_sha} ${artifact_size} ${artifact}
DSC
}

write_lock_from_fixtures() {
  local artifact="${1:-ocserv_1.5.0.orig.tar.xz}" artifact_size="${2:-3}" artifact_sha="${3:-ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad}"
  local dsc_size="${4:-}" dsc_sha="${5:-}"
  [[ -n "${dsc_size}" ]] || dsc_size="$(wc -c < "${FETCH_REPO}/fixtures/ocserv_1.5.0-1.dsc" | tr -d ' ')"
  [[ -n "${dsc_sha}" ]] || dsc_sha="$(sha256_of_file "${FETCH_REPO}/fixtures/ocserv_1.5.0-1.dsc")"
  cat > "${FETCH_REPO}/source-lock/ocserv/1.5.0-1.yaml" <<YAML
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
pool_path: "main/o/ocserv"
dsc:
  name: ocserv_1.5.0-1.dsc
  size: ${dsc_size}
  sha256: "${dsc_sha}"
artifacts:
  - name: ${artifact}
    size: ${artifact_size}
    sha256: "${artifact_sha}"
YAML
  cat > "${FETCH_REPO}/source-lock/ocserv/1.5.0-1.lock.tsv" <<TSV
META	ocserv	1.5.0-1	main/o/ocserv	ocserv_1.5.0-1.dsc	${dsc_size}	${dsc_sha}
ARTIFACT	${artifact}	${artifact_size}	${artifact_sha}
TSV
}

make_success_fixtures() {
  printf 'abc' > "${FETCH_REPO}/fixtures/ocserv_1.5.0.orig.tar.xz"
  write_fixture_dsc
  write_lock_from_fixtures
}

install_fake_fetch_commands() {
  local mode="${1:-success}"
  FAKEBIN="$(mktemp -d)"
  cat > "${FAKEBIN}/curl" <<SH
#!/usr/bin/env bash
set -euo pipefail
dest=""
url=""
prev=""
for arg in "\$@"; do
  if [[ "\${prev}" == "--output" ]]; then dest="\${arg}"; fi
  url="\${arg}"
  prev="\${arg}"
done
echo "\${url}" >> "${FETCH_REPO}/curl-urls"
case "${mode}:\${url}" in
  artifact-download-fail:*ocserv_1.5.0.orig.tar.xz)
    echo "simulated artifact download failure" >&2
    exit 22
    ;;
esac
case "\${url}" in
  *ocserv_1.5.0-1.dsc) cp "${FETCH_REPO}/fixtures/ocserv_1.5.0-1.dsc" "\${dest}" ;;
  *ocserv_1.5.0.orig.tar.xz) cp "${FETCH_REPO}/fixtures/ocserv_1.5.0.orig.tar.xz" "\${dest}" ;;
  *) echo "unexpected url: \${url}" >&2; exit 23 ;;
esac
SH
  cat > "${FAKEBIN}/dscverify" <<SH
#!/usr/bin/env bash
case "${mode}" in
  dscverify-fail) echo "simulated dscverify failure" >&2; exit 8 ;;
  *) exit 0 ;;
esac
SH
  cat > "${FAKEBIN}/dpkg-source" <<SH
#!/usr/bin/env bash
set -euo pipefail
case "${mode}" in
  dpkg-source-fail) echo "simulated dpkg-source failure" >&2; exit 9 ;;
esac
out="\${@: -1: 1}"
mkdir -p "\${out}"
printf 'unpacked source\n' > "\${out}/README"
SH
  chmod +x "${FAKEBIN}/curl" "${FAKEBIN}/dscverify" "${FAKEBIN}/dpkg-source"
}

run_fetch() {
  run bash -c "cd '${FETCH_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/fetch-source.sh"
}

@test "fetch constructs Debian pool URLs and downloads dsc before artifacts" {
  setup_fetch_repo
  make_success_fixtures
  install_fake_fetch_commands success
  run_fetch
  urls="$(cat "${FETCH_REPO}/curl-urls")"
  teardown_fetch_repo
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${urls}" | sed -n '1p')" = "https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.dsc" ]
  [ "$(printf '%s\n' "${urls}" | sed -n '2p')" = "https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0.orig.tar.xz" ]
}

@test "fetch fails on dsc size mismatch before installing source tree" {
  setup_fetch_repo
  printf 'abc' > "${FETCH_REPO}/fixtures/ocserv_1.5.0.orig.tar.xz"
  write_fixture_dsc
  write_lock_from_fixtures ocserv_1.5.0.orig.tar.xz 3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 9999
  install_fake_fetch_commands success
  run_fetch
  installed="$([ -d "${FETCH_REPO}/build/source/ocserv-1.5.0" ] && echo yes || echo no)"
  teardown_fetch_repo
  [ "${status}" -ne 0 ]
  [ "${installed}" = "no" ]
}

@test "fetch fails on dsc sha mismatch" {
  setup_fetch_repo
  printf 'abc' > "${FETCH_REPO}/fixtures/ocserv_1.5.0.orig.tar.xz"
  write_fixture_dsc
  actual_size="$(wc -c < "${FETCH_REPO}/fixtures/ocserv_1.5.0-1.dsc" | tr -d ' ')"
  write_lock_from_fixtures ocserv_1.5.0.orig.tar.xz 3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "${actual_size}" ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
  install_fake_fetch_commands success
  run_fetch
  teardown_fetch_repo
  [ "${status}" -ne 0 ]
}

@test "fetch fails on dsc Source and Version mismatch" {
  setup_fetch_repo
  printf 'abc' > "${FETCH_REPO}/fixtures/ocserv_1.5.0.orig.tar.xz"
  write_fixture_dsc otherpkg 1.5.0-1
  write_lock_from_fixtures
  install_fake_fetch_commands success
  run_fetch
  teardown_fetch_repo
  [ "${status}" -ne 0 ]

  setup_fetch_repo
  printf 'abc' > "${FETCH_REPO}/fixtures/ocserv_1.5.0.orig.tar.xz"
  write_fixture_dsc ocserv 1.4.0-1
  write_lock_from_fixtures
  install_fake_fetch_commands success
  run_fetch
  teardown_fetch_repo
  [ "${status}" -ne 0 ]
}

@test "fetch fails when dsc artifact mapping differs from lock" {
  setup_fetch_repo
  printf 'abc' > "${FETCH_REPO}/fixtures/ocserv_1.5.0.orig.tar.xz"
  write_fixture_dsc ocserv 1.5.0-1 unexpected.tar.xz 3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  write_lock_from_fixtures ocserv_1.5.0.orig.tar.xz 3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  install_fake_fetch_commands success
  run_fetch
  teardown_fetch_repo
  [ "${status}" -ne 0 ]
}

@test "fetch reports artifact download failures" {
  setup_fetch_repo
  make_success_fixtures
  install_fake_fetch_commands artifact-download-fail
  run_fetch
  teardown_fetch_repo
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ocserv_1.5.0.orig.tar.xz"* ]]
}

@test "fetch fails on artifact size and sha mismatch" {
  setup_fetch_repo
  printf 'abc' > "${FETCH_REPO}/fixtures/ocserv_1.5.0.orig.tar.xz"
  write_fixture_dsc ocserv 1.5.0-1 ocserv_1.5.0.orig.tar.xz 4 88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589
  write_lock_from_fixtures ocserv_1.5.0.orig.tar.xz 4 88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589
  install_fake_fetch_commands success
  run_fetch
  teardown_fetch_repo
  [ "${status}" -ne 0 ]

  setup_fetch_repo
  printf 'abc' > "${FETCH_REPO}/fixtures/ocserv_1.5.0.orig.tar.xz"
  write_fixture_dsc ocserv 1.5.0-1 ocserv_1.5.0.orig.tar.xz 3 ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
  write_lock_from_fixtures ocserv_1.5.0.orig.tar.xz 3 ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
  install_fake_fetch_commands success
  run_fetch
  teardown_fetch_repo
  [ "${status}" -ne 0 ]
}

@test "fetch fails on dscverify and dpkg-source failures without installing source tree" {
  setup_fetch_repo
  make_success_fixtures
  install_fake_fetch_commands dscverify-fail
  run_fetch
  installed="$([ -d "${FETCH_REPO}/build/source/ocserv-1.5.0" ] && echo yes || echo no)"
  teardown_fetch_repo
  [ "${status}" -ne 0 ]
  [ "${installed}" = "no" ]

  setup_fetch_repo
  make_success_fixtures
  install_fake_fetch_commands dpkg-source-fail
  run_fetch
  installed="$([ -d "${FETCH_REPO}/build/source/ocserv-1.5.0" ] && echo yes || echo no)"
  teardown_fetch_repo
  [ "${status}" -ne 0 ]
  [ "${installed}" = "no" ]
}

@test "fetch succeeds by installing source tree and preserving old tree on later failure" {
  setup_fetch_repo
  make_success_fixtures
  install_fake_fetch_commands success
  run_fetch
  [ "${status}" -eq 0 ]
  [ -f "${FETCH_REPO}/build/source/ocserv-1.5.0/README" ]
  [ -f "${FETCH_REPO}/build/source/ocserv_1.5.0.orig.tar.xz" ]

  printf 'old valid tree\n' > "${FETCH_REPO}/build/source/ocserv-1.5.0/README"
  install_fake_fetch_commands dpkg-source-fail
  run_fetch
  preserved="$(cat "${FETCH_REPO}/build/source/ocserv-1.5.0/README")"
  teardown_fetch_repo
  [ "${status}" -ne 0 ]
  [ "${preserved}" = "old valid tree" ]
}

@test "fetch rejects legacy source mode environment and script has no removed dispatch" {
  setup_fetch_repo
  make_success_fixtures
  install_fake_fetch_commands success
  legacy_var="FETCH""_SOURCE"
  run bash -c "cd '${FETCH_REPO}' && ${legacy_var}=cache PATH='${FAKEBIN}:${PATH}' bash scripts/fetch-source.sh"
  [ "${status}" -ne 0 ]
  ! grep -Eq 'fetch_via_''cache|read_''cache_meta|source-''cache|cache\.''meta' "${FETCH_REPO}/scripts/fetch-source.sh"
  teardown_fetch_repo
}
