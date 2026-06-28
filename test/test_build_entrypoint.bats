#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}"
  ENTRY_REPO=""
  FAKEBIN=""
  OUTSIDE_DIR=""
  SYSTEM_MAKE=""
}

teardown() {
  if [[ -n "${ENTRY_REPO:-}" ]]; then rm -rf "${ENTRY_REPO}"; fi
  if [[ -n "${FAKEBIN:-}" ]]; then rm -rf "${FAKEBIN}"; fi
  if [[ -n "${OUTSIDE_DIR:-}" ]]; then rm -rf "${OUTSIDE_DIR}"; fi
}

setup_entrypoint_repo() {
  ENTRY_REPO="$(mktemp -d)"
  mkdir -p "${ENTRY_REPO}/scripts"
  cp "${REPO_ROOT}/scripts/_common.sh" "${ENTRY_REPO}/scripts/_common.sh"
  cp "${REPO_ROOT}/scripts/dry-run.sh" "${ENTRY_REPO}/scripts/dry-run.sh"
  cp "${REPO_ROOT}/Makefile" "${ENTRY_REPO}/Makefile"
  if [[ -f "${REPO_ROOT}/scripts/build.sh" ]]; then
    cp "${REPO_ROOT}/scripts/build.sh" "${ENTRY_REPO}/scripts/build.sh"
  fi
  SYSTEM_MAKE="$(command -v make)"
  FAKEBIN="$(mktemp -d)"
}

install_fake_make() {
  local fail_target="${1:-}"
  cat > "${FAKEBIN}/make" <<SH
#!/usr/bin/env bash
set -euo pipefail
target="\${1:-}"
printf '%s\t%s\n' "\${target}" "\${OCSERV_VERSION:-}" >> "${ENTRY_REPO}/make-calls"
if [[ "\${target}" == "${fail_target}" ]]; then
  echo "fake failure for \${target}" >&2
  exit 42
fi
SH
  chmod +x "${FAKEBIN}/make"
}

install_make_target_stub() {
  local script="$1" call="$2"
  cat > "${ENTRY_REPO}/scripts/${script}" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${call}" >> "${ENTRY_REPO}/target-calls"
SH
  chmod +x "${ENTRY_REPO}/scripts/${script}"
}

install_pipeline_target_stubs() {
  install_make_target_stub verify-source-lock.sh verify-lock
  install_make_target_stub fetch-source.sh fetch
  install_make_target_stub rewrap-changelog.sh rewrap
  install_make_target_stub build-source-package.sh src-pkg
  install_make_target_stub build-binary.sh binary
  install_make_target_stub lint-package.sh lint
  install_make_target_stub smoke-test.sh smoke-basic
}

run_build_direct() {
  run bash -c "cd '${ENTRY_REPO}' && if [[ ! -f scripts/build.sh ]]; then echo 'scripts/build.sh is missing' >&2; exit 99; fi; PATH='${FAKEBIN}:${PATH}' bash scripts/build.sh"
}

run_make_build() {
  run bash -c "cd '${ENTRY_REPO}' && PATH='${FAKEBIN}:${PATH}' '${SYSTEM_MAKE}' build"
}

run_make_build_with_version() {
  local version="$1"
  run bash -c "cd '${ENTRY_REPO}' && PATH='${FAKEBIN}:${PATH}' OCSERV_VERSION='${version}' '${SYSTEM_MAKE}' build"
}

run_make_debian_auto_build() {
  run bash -c "cd '${ENTRY_REPO}' && PATH='${FAKEBIN}:${PATH}' TARGET_ARCH=amd64 '${SYSTEM_MAKE}' debian-auto-build"
}

run_build_from_outside() {
  OUTSIDE_DIR="$(mktemp -d)"
  run bash -c "cd '${OUTSIDE_DIR}' && PATH='${FAKEBIN}:${PATH}' bash '${ENTRY_REPO}/scripts/build.sh'"
}

run_dry_run_from_outside() {
  OUTSIDE_DIR="$(mktemp -d)"
  run bash -c "cd '${OUTSIDE_DIR}' && PATH='${FAKEBIN}:${PATH}' bash '${ENTRY_REPO}/scripts/dry-run.sh'"
}

require_make_calls() {
  if [[ ! -f "${ENTRY_REPO}/make-calls" ]]; then
    echo "expected fake make calls at ${ENTRY_REPO}/make-calls, but the file does not exist" >&2
    return 1
  fi
}

make_targets() {
  require_make_calls || return
  cut -f1 "${ENTRY_REPO}/make-calls"
}

make_versions() {
  require_make_calls || return
  cut -f2 "${ENTRY_REPO}/make-calls" | sort -u
}

entrypoint_file() {
  local path="${ENTRY_REPO}/$1"
  if [[ ! -f "${path}" ]]; then
    echo "expected ${path} to exist" >&2
    return 1
  fi
  cat "${path}"
}

assert_status() {
  local expected="$1"
  if [[ "${status}" -ne "${expected}" ]]; then
    echo "expected status ${expected}, got ${status}" >&2
    [[ -n "${output}" ]] && echo "${output}" >&2
    return 1
  fi
}

@test "build executes exactly the seven validation stages in order" {
  setup_entrypoint_repo
  install_fake_make
  run_build_direct
  assert_status 0
  calls="$(make_targets)"
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg\nbinary\nlint\nsmoke-basic' ]
}

@test "build entrypoint runs from outside the repo root" {
  setup_entrypoint_repo
  install_pipeline_target_stubs
  run_build_from_outside
  assert_status 0
  calls="$(entrypoint_file target-calls)"
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg\nbinary\nlint\nsmoke-basic' ]
}

@test "build stops immediately and reports the failing stage" {
  setup_entrypoint_repo
  install_fake_make binary
  run_build_direct
  assert_status 1
  calls="$(make_targets)"
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg\nbinary' ]
  [[ "${output}" == *"BUILD FAILED at: binary"* ]]
}

@test "build verifies lock before cleaning old artifacts" {
  setup_entrypoint_repo
  mkdir -p "${ENTRY_REPO}/build/source" "${ENTRY_REPO}/build/binary"
  printf 'old source\n' > "${ENTRY_REPO}/build/source/marker"
  printf 'old binary\n' > "${ENTRY_REPO}/build/binary/marker"
  install_fake_make verify-lock
  run_build_direct
  assert_status 1
  source_marker="$([ -f "${ENTRY_REPO}/build/source/marker" ] && echo yes || echo no)"
  binary_marker="$([ -f "${ENTRY_REPO}/build/binary/marker" ] && echo yes || echo no)"
  [ "${source_marker}" = "yes" ]
  [ "${binary_marker}" = "yes" ]
}

@test "build exports the default local backport version when run directly" {
  setup_entrypoint_repo
  install_fake_make
  run_build_direct
  assert_status 0
  versions="$(make_versions)"
  [ "${versions}" = "1.5.0-1~debian13.1" ]
}

@test "make build exports the default local backport version" {
  setup_entrypoint_repo
  install_fake_make
  run_make_build
  assert_status 0
  versions="$(make_versions)"
  [ "${versions}" = "1.5.0-1~debian13.1" ]
}

@test "make build preserves an OCSERV_VERSION override" {
  setup_entrypoint_repo
  install_fake_make
  run_make_build_with_version "1.5.0-1~bpo13+custom1"
  assert_status 0
  versions="$(make_versions)"
  [ "${versions}" = "1.5.0-1~bpo13+custom1" ]
}

@test "make debian-auto-build delegates to scripts/debian-auto-build.sh" {
  setup_entrypoint_repo
  cat > "${ENTRY_REPO}/scripts/debian-auto-build.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\${TARGET_ARCH:-}" > "${ENTRY_REPO}/debian-auto-build-target-arch"
SH
  chmod +x "${ENTRY_REPO}/scripts/debian-auto-build.sh"

  run_make_debian_auto_build

  assert_status 0
  [ "$(cat "${ENTRY_REPO}/debian-auto-build-target-arch")" = "amd64" ]
}

@test "dry-run forwards to build.sh without keeping a stage list" {
  setup_entrypoint_repo
  install_fake_make
  cat > "${ENTRY_REPO}/scripts/build.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" > "${ENTRY_REPO}/dry-run-forwarded-args"
printf '%s\n' "\${OCSERV_VERSION:-}" > "${ENTRY_REPO}/dry-run-forwarded-version"
SH
  chmod +x "${ENTRY_REPO}/scripts/build.sh"

  run bash -c "cd '${ENTRY_REPO}' && PATH='${FAKEBIN}:${PATH}' OCSERV_VERSION='1.5.0-1~bpo13+wrapped1' bash scripts/dry-run.sh alpha beta"
  assert_status 0
  args="$(entrypoint_file dry-run-forwarded-args)"
  version="$(entrypoint_file dry-run-forwarded-version)"
  [ "${args}" = "alpha beta" ]
  [ "${version}" = "1.5.0-1~bpo13+wrapped1" ]
}

@test "dry-run entrypoint runs build pipeline from outside the repo root" {
  setup_entrypoint_repo
  install_pipeline_target_stubs
  run_dry_run_from_outside
  assert_status 0
  calls="$(entrypoint_file target-calls)"
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg\nbinary\nlint\nsmoke-basic' ]
}

@test "fetch target delegates verification to fetch-source script" {
  setup_entrypoint_repo
  install_make_target_stub fetch-source.sh fetch

  run bash -c "cd '${ENTRY_REPO}' && '${SYSTEM_MAKE}' fetch"
  assert_status 0
  calls="$(entrypoint_file target-calls)"
  [ "${calls}" = "fetch" ]
}

@test "build skips fetch target's duplicate lock verification" {
  setup_entrypoint_repo
  install_pipeline_target_stubs

  run bash -c "cd '${ENTRY_REPO}' && '${SYSTEM_MAKE}' build"
  assert_status 0
  calls="$(entrypoint_file target-calls)"
  [ "${calls}" = $'verify-lock\nfetch\nrewrap\nsrc-pkg\nbinary\nlint\nsmoke-basic' ]
}
