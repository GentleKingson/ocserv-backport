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
  cp "${REPO_ROOT}/scripts/_target_arch.sh" "${SOURCE_CI_REPO}/scripts/_target_arch.sh"
  cp "${REPO_ROOT}/scripts/_target_paths.sh" "${SOURCE_CI_REPO}/scripts/_target_paths.sh"
  cp "${REPO_ROOT}/scripts/trixie-env.sh" "${SOURCE_CI_REPO}/scripts/trixie-env.sh"
  cp "${REPO_ROOT}/scripts/trixie-source-package-ci.sh" "${SOURCE_CI_REPO}/scripts/trixie-source-package-ci.sh"
  cp "${REPO_ROOT}/Makefile" "${SOURCE_CI_REPO}/Makefile"
  SYSTEM_MAKE="$(command -v make)"
  FAKEBIN="$(mktemp -d)"
  cat > "${FAKEBIN}/dpkg" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --print-architecture) printf 'amd64\n' ;;
  *) exit 99 ;;
esac
SH
  cat > "${FAKEBIN}/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf 'x86_64\n' ;;
  *) exit 99 ;;
esac
SH
  chmod +x "${FAKEBIN}/dpkg" "${FAKEBIN}/uname"
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
  trixie-verify-locks|trixie-fetch-ocserv|trixie-rewrap-ocserv|trixie-src-pkg-ocserv) ;;
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
  install_make_target_stub verify-source-lock.sh trixie-verify-locks
  install_make_target_stub trixie-fetch-source.sh trixie-fetch-ocserv
  install_make_target_stub trixie-rewrap-changelog.sh trixie-rewrap-ocserv
  install_make_target_stub trixie-build-source-package.sh trixie-src-pkg-ocserv
}

run_source_ci() {
  run bash -c "cd '${SOURCE_CI_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/trixie-source-package-ci.sh"
}

run_source_ci_from_outside() {
  OUTSIDE_DIR="$(mktemp -d)"
  run bash -c "cd '${OUTSIDE_DIR}' && PATH='${FAKEBIN}:${PATH}' bash '${SOURCE_CI_REPO}/scripts/trixie-source-package-ci.sh'"
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
  [ "${calls}" = $'trixie-verify-locks\ntrixie-fetch-ocserv\ntrixie-rewrap-ocserv\ntrixie-src-pkg-ocserv' ]
}

@test "source CI entrypoint runs from outside the repo root" {
  setup_source_ci_repo
  install_source_target_stubs
  run_source_ci_from_outside
  [ "${status}" -eq 0 ]
  calls="$(source_ci_file target-calls)"
  [ "${calls}" = $'trixie-verify-locks\ntrixie-fetch-ocserv\ntrixie-rewrap-ocserv\ntrixie-src-pkg-ocserv' ]
}

@test "source CI stops immediately and reports the failing stage" {
  setup_source_ci_repo
  install_fake_make trixie-rewrap-ocserv
  run_source_ci
  calls="$(source_ci_targets)"
  [ "${status}" -eq 1 ]
  [ "${calls}" = $'trixie-verify-locks\ntrixie-fetch-ocserv\ntrixie-rewrap-ocserv' ]
  [[ "${output}" == *"SOURCE-CI FAILED at: trixie-rewrap-ocserv"* ]]
}

@test "source CI verifies lock before cleaning source artifacts" {
  setup_source_ci_repo
  mkdir -p "${SOURCE_CI_REPO}/build/debian/trixie/amd64/source" "${SOURCE_CI_REPO}/build/debian/trixie/amd64/binary"
  printf 'old source\n' > "${SOURCE_CI_REPO}/build/debian/trixie/amd64/source/marker"
  printf 'old binary\n' > "${SOURCE_CI_REPO}/build/debian/trixie/amd64/binary/marker"
  install_fake_make trixie-verify-locks
  run_source_ci
  source_marker="$([ -f "${SOURCE_CI_REPO}/build/debian/trixie/amd64/source/marker" ] && echo yes || echo no)"
  binary_marker="$([ -f "${SOURCE_CI_REPO}/build/debian/trixie/amd64/binary/marker" ] && echo yes || echo no)"
  [ "${status}" -eq 1 ]
  [ "${source_marker}" = "yes" ]
  [ "${binary_marker}" = "yes" ]
}

@test "source CI ignores legacy build source and binary sentinels" {
  setup_source_ci_repo
  mkdir -p "${SOURCE_CI_REPO}/build/source" "${SOURCE_CI_REPO}/build/binary"
  printf 'legacy source sentinel\n' > "${SOURCE_CI_REPO}/build/source/SENTINEL_OLD_PATH"
  printf 'legacy binary sentinel\n' > "${SOURCE_CI_REPO}/build/binary/SENTINEL_OLD_PATH"
  install_fake_make
  run_source_ci
  [ "${status}" -eq 0 ]
  [ "$(cat "${SOURCE_CI_REPO}/build/source/SENTINEL_OLD_PATH")" = "legacy source sentinel" ]
  [ "$(cat "${SOURCE_CI_REPO}/build/binary/SENTINEL_OLD_PATH")" = "legacy binary sentinel" ]
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
  run bash -c "cd '${SOURCE_CI_REPO}' && PATH='${FAKEBIN}:${PATH}' OCSERV_VERSION='1.5.0-1~bpo13+source1' bash scripts/trixie-source-package-ci.sh"
  versions="$(source_ci_versions)"
  [ "${status}" -eq 0 ]
  [ "${versions}" = "1.5.0-1~bpo13+source1" ]
}

@test "trixie-source-ci target skips duplicate lock verification during fetch" {
  setup_source_ci_repo
  install_source_target_stubs

  run bash -c "cd '${SOURCE_CI_REPO}' && '${SYSTEM_MAKE}' trixie-source-ci"
  calls="$(source_ci_file target-calls)"
  [ "${status}" -eq 0 ]
  [ "${calls}" = $'trixie-verify-locks\ntrixie-fetch-ocserv\ntrixie-rewrap-ocserv\ntrixie-src-pkg-ocserv' ]
}
