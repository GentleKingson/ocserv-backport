#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}"
  SOURCE_CI_REPO=""
  FAKEBIN=""
  OUTSIDE_DIR=""
  SYSTEM_MAKE=""
}

teardown() {
  teardown_source_ci_repo
}

setup_source_ci_repo() {
  SOURCE_CI_REPO="$(mktemp -d)"
  mkdir -p "${SOURCE_CI_REPO}/scripts"
  cp "${REPO_ROOT}/scripts/_common.sh" "${SOURCE_CI_REPO}/scripts/_common.sh"
  cp "${REPO_ROOT}/scripts/source-package-ci.sh" "${SOURCE_CI_REPO}/scripts/source-package-ci.sh"
  cp "${REPO_ROOT}/Makefile" "${SOURCE_CI_REPO}/Makefile"
  SYSTEM_MAKE="$(command -v make)"
  FAKEBIN="$(mktemp -d)"
}

teardown_source_ci_repo() {
  [[ -n "${SOURCE_CI_REPO:-}" ]] && rm -rf "${SOURCE_CI_REPO}"
  [[ -n "${FAKEBIN:-}" ]] && rm -rf "${FAKEBIN}"
  [[ -n "${OUTSIDE_DIR:-}" ]] && rm -rf "${OUTSIDE_DIR}"
  SOURCE_CI_REPO=""
  FAKEBIN=""
  OUTSIDE_DIR=""
  SYSTEM_MAKE=""
}

install_fake_make() {
  local fail_target="${1:-}"
  cat > "${FAKEBIN}/make" <<SH
#!/usr/bin/env bash
set -euo pipefail
target="\${1:-}"
case "\${target}" in
  verify-lock|fetch|rewrap|src-pkg) ;;
  *) echo "unexpected target: \${target}" >&2; exit 64 ;;
esac
printf '%s\t%s\n' "\${target}" "\${OCSERV_VERSION:-}" >> "${SOURCE_CI_REPO}/make-calls"
if [[ "\${target}" == "${fail_target}" ]]; then
  echo "fake failure for \${target}" >&2
  exit 42
fi
SH
  chmod +x "${FAKEBIN}/make"
}

install_make_target_stub() {
  local script="$1" call="$2"
  cat > "${SOURCE_CI_REPO}/scripts/${script}" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${call}" >> "${SOURCE_CI_REPO}/target-calls"
SH
  chmod +x "${SOURCE_CI_REPO}/scripts/${script}"
}

install_source_target_stubs() {
  install_make_target_stub verify-source-lock.sh verify-lock
  install_make_target_stub fetch-source.sh fetch
  install_make_target_stub rewrap-changelog.sh rewrap
  install_make_target_stub build-source-package.sh src-pkg
}

run_source_ci() {
  run bash -c "cd '${SOURCE_CI_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/source-package-ci.sh"
}

run_source_ci_from_outside() {
  OUTSIDE_DIR="$(mktemp -d)"
  run bash -c "cd '${OUTSIDE_DIR}' && PATH='${FAKEBIN}:${PATH}' bash '${SOURCE_CI_REPO}/scripts/source-package-ci.sh'"
}

source_ci_targets() {
  cut -f1 "${SOURCE_CI_REPO}/make-calls"
}

source_ci_versions() {
  cut -f2 "${SOURCE_CI_REPO}/make-calls" | sort -u
}

source_ci_file() {
  local path="${SOURCE_CI_REPO}/$1"
  if [[ ! -f "${path}" ]]; then
    echo "expected ${path} to exist" >&2
    return 1
  fi
  cat "${path}"
}

@test "source CI executes only source package stages in order" {
  setup_source_ci_repo
  install_fake_make
  run_source_ci
  calls="$(source_ci_targets)"
  [ "${status}" -eq 0 ]
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg' ]
}

@test "source CI entrypoint runs from outside the repo root" {
  setup_source_ci_repo
  install_source_target_stubs
  run_source_ci_from_outside
  [ "${status}" -eq 0 ]
  calls="$(source_ci_file target-calls)"
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg' ]
}

@test "source CI stops immediately and reports the failing stage" {
  setup_source_ci_repo
  install_fake_make rewrap
  run_source_ci
  calls="$(source_ci_targets)"
  [ "${status}" -eq 1 ]
  [ "${calls}" = $'verify-lock\nfetch\nrewrap' ]
  [[ "${output}" == *"SOURCE-CI FAILED at: rewrap"* ]]
}

@test "source CI verifies lock before cleaning source artifacts" {
  setup_source_ci_repo
  mkdir -p "${SOURCE_CI_REPO}/build/source" "${SOURCE_CI_REPO}/build/binary"
  printf 'old source\n' > "${SOURCE_CI_REPO}/build/source/marker"
  printf 'old binary\n' > "${SOURCE_CI_REPO}/build/binary/marker"
  install_fake_make verify-lock
  run_source_ci
  source_marker="$([ -f "${SOURCE_CI_REPO}/build/source/marker" ] && echo yes || echo no)"
  binary_marker="$([ -f "${SOURCE_CI_REPO}/build/binary/marker" ] && echo yes || echo no)"
  [ "${status}" -eq 1 ]
  [ "${source_marker}" = "yes" ]
  [ "${binary_marker}" = "yes" ]
}

@test "source CI exports the default local backport version" {
  setup_source_ci_repo
  install_fake_make
  run_source_ci
  versions="$(source_ci_versions)"
  [ "${status}" -eq 0 ]
  [ "${versions}" = "1.5.0-1~debian13.1" ]
}

@test "source CI preserves an OCSERV_VERSION override" {
  setup_source_ci_repo
  install_fake_make
  run bash -c "cd '${SOURCE_CI_REPO}' && PATH='${FAKEBIN}:${PATH}' OCSERV_VERSION='1.5.0-1~bpo13+source1' bash scripts/source-package-ci.sh"
  versions="$(source_ci_versions)"
  [ "${status}" -eq 0 ]
  [ "${versions}" = "1.5.0-1~bpo13+source1" ]
}

@test "make source-ci skips fetch target's duplicate lock verification" {
  setup_source_ci_repo
  install_source_target_stubs

  run bash -c "cd '${SOURCE_CI_REPO}' && '${SYSTEM_MAKE}' source-ci"
  calls="$(source_ci_file target-calls)"
  [ "${status}" -eq 0 ]
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg' ]
}
