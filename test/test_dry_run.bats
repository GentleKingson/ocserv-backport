#!/usr/bin/env bats
load helpers/bats-helper.bash

setup_dry_repo() {
  DRY_REPO="$(mktemp -d)"
  mkdir -p "${DRY_REPO}/scripts"
  cp "${REPO_ROOT}/scripts/_common.sh" "${DRY_REPO}/scripts/_common.sh"
  cp "${REPO_ROOT}/scripts/dry-run.sh" "${DRY_REPO}/scripts/dry-run.sh"
  FAKEBIN="$(mktemp -d)"
}

teardown_dry_repo() {
  [[ -n "${DRY_REPO:-}" ]] && rm -rf "${DRY_REPO}"
  [[ -n "${FAKEBIN:-}" ]] && rm -rf "${FAKEBIN}"
  DRY_REPO=""
  FAKEBIN=""
}

install_fake_make() {
  local fail_target="${1:-}"
  cat > "${FAKEBIN}/make" <<SH
#!/usr/bin/env bash
set -euo pipefail
target="\${1:-}"
echo "\${target}" >> "${DRY_REPO}/make-calls"
if [[ "\${target}" == "${fail_target}" ]]; then
  echo "fake failure for \${target}" >&2
  exit 42
fi
SH
  chmod +x "${FAKEBIN}/make"
}

run_dry() {
  run bash -c "cd '${DRY_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/dry-run.sh"
}

@test "dry-run executes exactly the seven validation stages in order" {
  setup_dry_repo
  install_fake_make
  run_dry
  calls="$(cat "${DRY_REPO}/make-calls")"
  teardown_dry_repo
  [ "${status}" -eq 0 ]
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg\nbinary\nlint\nsmoke-basic' ]
}

@test "dry-run stops immediately and reports the failing stage" {
  setup_dry_repo
  install_fake_make binary
  run_dry
  calls="$(cat "${DRY_REPO}/make-calls")"
  teardown_dry_repo
  [ "${status}" -eq 1 ]
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg\nbinary' ]
  [[ "${output}" == *"DRY-RUN FAILED at: binary"* ]]
}

@test "dry-run calls no targets outside the seven-stage validation chain" {
  setup_dry_repo
  install_fake_make
  run_dry
  calls="$(cat "${DRY_REPO}/make-calls")"
  teardown_dry_repo
  [ "${status}" -eq 0 ]
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg\nbinary\nlint\nsmoke-basic' ]
}
