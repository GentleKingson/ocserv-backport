#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  CI_REPO="$(mktemp -d)"
  FAKEBIN="$(mktemp -d)"
  mkdir -p "${CI_REPO}/scripts"
  local file
  for file in _common.sh _pipeline.sh _versions.sh _target_arch.sh _target_paths.sh noble-env.sh noble-source-package-ci.sh; do
    cp "${REPO_ROOT}/scripts/${file}" "${CI_REPO}/scripts/${file}"
  done
  cat > "${FAKEBIN}/dpkg" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == --print-architecture ]] && { echo amd64; exit 0; }
exit 99
SH
  cat > "${FAKEBIN}/make" <<SH
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\${NOBLE_SKIP_FETCH_VERIFY_LOCK:-}" >> "${CI_REPO}/make-calls"
[[ "\$1" != "\${FAKE_MAKE_FAIL:-}" ]]
SH
  chmod +x "${FAKEBIN}/dpkg" "${FAKEBIN}/make"
}

teardown() {
  rm -rf "${CI_REPO}" "${FAKEBIN}"
}

run_source_ci() {
  run env "PATH=${FAKEBIN}:${PATH}" "$@" bash -c "cd / && bash '${CI_REPO}/scripts/noble-source-package-ci.sh'"
}

@test "noble source CI runs only source stages in order and skips duplicate lock checks" {
  mkdir -p "${CI_REPO}/build/ubuntu/noble/amd64/source" "${CI_REPO}/build/ubuntu/noble/amd64/binary"
  run_source_ci
  [ "${status}" -eq 0 ]
  [ "$(cat "${CI_REPO}/make-calls")" = $'noble-verify-locks\t\nnoble-fetch-node-undici\t1\nnoble-rewrap-node-undici\t\nnoble-src-pkg-node-undici\t\nnoble-fetch-ocserv\t1\nnoble-rewrap-ocserv\t\nnoble-src-pkg-ocserv\t' ]
  [ ! -d "${CI_REPO}/build/ubuntu/noble/amd64/source" ]
  [ -d "${CI_REPO}/build/ubuntu/noble/amd64/binary" ]
  [[ "${output}" == *"NOBLE SOURCE-CI PASSED"* ]]
}

@test "noble source CI stops at and reports the failing stage" {
  run_source_ci FAKE_MAKE_FAIL=noble-rewrap-ocserv
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"NOBLE SOURCE-CI FAILED at: noble-rewrap-ocserv"* ]]
  [ "$(tail -n 1 "${CI_REPO}/make-calls" | cut -f1)" = "noble-rewrap-ocserv" ]
}
