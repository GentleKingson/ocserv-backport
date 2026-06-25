#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}"
  DRY_REPO="$(mktemp -d)"
  FAKEBIN="$(mktemp -d)"
  mkdir -p "${DRY_REPO}/scripts"
  cp "${REPO_ROOT}/scripts/dry-run.sh" "${DRY_REPO}/scripts/dry-run.sh"
}

teardown() {
  [[ -n "${DRY_REPO:-}" ]] && rm -rf "${DRY_REPO}"
  [[ -n "${FAKEBIN:-}" ]] && rm -rf "${FAKEBIN}"
}

install_forwarding_build_stub() {
  cat > "${DRY_REPO}/scripts/build.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$#" > build-argc
printf '<%s>\n' "$@" > build-argv
printf '%s\n' "${OCSERV_VERSION:-}" > build-version
SH
  chmod +x "${DRY_REPO}/scripts/build.sh"
}

install_failing_build_stub() {
  cat > "${DRY_REPO}/scripts/build.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "build stdout"
echo "build stderr" >&2
exit 37
SH
  chmod +x "${DRY_REPO}/scripts/build.sh"
}

install_success_build_stub() {
  cat > "${DRY_REPO}/scripts/build.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "build ok"
SH
  chmod +x "${DRY_REPO}/scripts/build.sh"
}

install_make_that_must_not_run() {
  cat > "${FAKEBIN}/make" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'make called\n' > make-called
exit 99
SH
  chmod +x "${FAKEBIN}/make"
}

run_dry() {
  run bash -c "cd '${DRY_REPO}' && PATH='${FAKEBIN}:${PATH}' $*"
}

@test "dry-run forwards arguments and OCSERV_VERSION to build.sh" {
  install_forwarding_build_stub

  run_dry "OCSERV_VERSION='1.5.0-1~bpo13+wrapped1' bash scripts/dry-run.sh alpha beta"

  [ "${status}" -eq 0 ]
  [ "$(cat "${DRY_REPO}/build-argc")" = "2" ]
  [ "$(cat "${DRY_REPO}/build-argv")" = $'<alpha>\n<beta>' ]
  [ "$(cat "${DRY_REPO}/build-version")" = "1.5.0-1~bpo13+wrapped1" ]
}

@test "dry-run propagates build.sh exit status and output" {
  install_failing_build_stub

  run_dry "bash scripts/dry-run.sh"

  [ "${status}" -eq 37 ]
  [[ "${output}" == *"build stdout"* ]]
  [[ "${output}" == *"build stderr"* ]]
}

@test "dry-run wrapper does not invoke make directly" {
  install_success_build_stub
  install_make_that_must_not_run

  run_dry "bash scripts/dry-run.sh"

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"build ok"* ]]
  [ ! -e "${DRY_REPO}/make-called" ]
}
