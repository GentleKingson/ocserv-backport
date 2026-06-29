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
  cp "${REPO_ROOT}/scripts/_target_arch.sh" "${ENTRY_REPO}/scripts/_target_arch.sh"
  cp "${REPO_ROOT}/scripts/_target_paths.sh" "${ENTRY_REPO}/scripts/_target_paths.sh"
  cp "${REPO_ROOT}/scripts/trixie-env.sh" "${ENTRY_REPO}/scripts/trixie-env.sh"
  cp "${REPO_ROOT}/Makefile" "${ENTRY_REPO}/Makefile"
  if [[ -f "${REPO_ROOT}/scripts/trixie-build.sh" ]]; then
    cp "${REPO_ROOT}/scripts/trixie-build.sh" "${ENTRY_REPO}/scripts/trixie-build.sh"
  fi
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
  install_make_target_stub verify-source-lock.sh trixie-verify-locks
  install_make_target_stub trixie-fetch-source.sh trixie-fetch-ocserv
  install_make_target_stub trixie-rewrap-changelog.sh trixie-rewrap-ocserv
  install_make_target_stub trixie-build-source-package.sh trixie-src-pkg-ocserv
  install_make_target_stub trixie-build-binary-ocserv.sh trixie-binary-ocserv
  install_make_target_stub trixie-lint-package.sh trixie-lint
  install_make_target_stub trixie-smoke-test.sh trixie-smoke-basic
}

run_build_direct() {
  run bash -c "cd '${ENTRY_REPO}' && if [[ ! -f scripts/trixie-build.sh ]]; then echo 'scripts/trixie-build.sh is missing' >&2; exit 99; fi; PATH='${FAKEBIN}:${PATH}' bash scripts/trixie-build.sh"
}

run_make_build() {
  run bash -c "cd '${ENTRY_REPO}' && PATH='${FAKEBIN}:${PATH}' '${SYSTEM_MAKE}' trixie-build"
}

run_make_build_with_version() {
  local version="$1"
  run bash -c "cd '${ENTRY_REPO}' && PATH='${FAKEBIN}:${PATH}' OCSERV_VERSION='${version}' '${SYSTEM_MAKE}' trixie-build"
}

run_make_trixie_auto_build() {
  run bash -c "cd '${ENTRY_REPO}' && PATH='${FAKEBIN}:${PATH}' TARGET_ARCH=amd64 '${SYSTEM_MAKE}' trixie-auto-build"
}

run_build_from_outside() {
  OUTSIDE_DIR="$(mktemp -d)"
  run bash -c "cd '${OUTSIDE_DIR}' && PATH='${FAKEBIN}:${PATH}' bash '${ENTRY_REPO}/scripts/trixie-build.sh'"
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
  [ "${calls}" = $'trixie-verify-locks\ntrixie-fetch-ocserv\ntrixie-rewrap-ocserv\ntrixie-src-pkg-ocserv\ntrixie-binary-ocserv\ntrixie-lint\ntrixie-smoke-basic' ]
}

@test "build entrypoint runs from outside the repo root" {
  setup_entrypoint_repo
  install_pipeline_target_stubs
  run_build_from_outside
  assert_status 0
  calls="$(entrypoint_file target-calls)"
  [ "${calls}" = $'trixie-verify-locks\ntrixie-fetch-ocserv\ntrixie-rewrap-ocserv\ntrixie-src-pkg-ocserv\ntrixie-binary-ocserv\ntrixie-lint\ntrixie-smoke-basic' ]
}

@test "build stops immediately and reports the failing stage" {
  setup_entrypoint_repo
  install_fake_make trixie-binary-ocserv
  run_build_direct
  assert_status 1
  calls="$(make_targets)"
  [ "${calls}" = $'trixie-verify-locks\ntrixie-fetch-ocserv\ntrixie-rewrap-ocserv\ntrixie-src-pkg-ocserv\ntrixie-binary-ocserv' ]
  [[ "${output}" == *"BUILD FAILED at: trixie-binary-ocserv"* ]]
}

@test "build verifies lock before cleaning old artifacts" {
  setup_entrypoint_repo
  mkdir -p "${ENTRY_REPO}/build/debian/trixie/amd64/source" "${ENTRY_REPO}/build/debian/trixie/amd64/binary"
  printf 'old source\n' > "${ENTRY_REPO}/build/debian/trixie/amd64/source/marker"
  printf 'old binary\n' > "${ENTRY_REPO}/build/debian/trixie/amd64/binary/marker"
  install_fake_make trixie-verify-locks
  run_build_direct
  assert_status 1
  source_marker="$([ -f "${ENTRY_REPO}/build/debian/trixie/amd64/source/marker" ] && echo yes || echo no)"
  binary_marker="$([ -f "${ENTRY_REPO}/build/debian/trixie/amd64/binary/marker" ] && echo yes || echo no)"
  [ "${source_marker}" = "yes" ]
  [ "${binary_marker}" = "yes" ]
}

@test "build ignores legacy build source and binary sentinels" {
  setup_entrypoint_repo
  mkdir -p "${ENTRY_REPO}/build/source" "${ENTRY_REPO}/build/binary"
  printf 'legacy source sentinel\n' > "${ENTRY_REPO}/build/source/SENTINEL_OLD_PATH"
  printf 'legacy binary sentinel\n' > "${ENTRY_REPO}/build/binary/SENTINEL_OLD_PATH"
  install_fake_make
  run_build_direct
  assert_status 0
  [ "$(cat "${ENTRY_REPO}/build/source/SENTINEL_OLD_PATH")" = "legacy source sentinel" ]
  [ "$(cat "${ENTRY_REPO}/build/binary/SENTINEL_OLD_PATH")" = "legacy binary sentinel" ]
}

@test "build exports the default local backport version when run directly" {
  setup_entrypoint_repo
  install_fake_make
  run_build_direct
  assert_status 0
  versions="$(make_versions)"
  [ "${versions}" = "1.5.0-1~debian13.1" ]
}

@test "trixie env rejects legacy Debian environment variables" {
  setup_entrypoint_repo
  install_fake_make

  for legacy_var in DEBIAN_DOCKER_CMD DEBIAN_NATIVE_ARCH OCSERV_SKIP_FETCH_VERIFY_LOCK DEBIAN_AUTO_BUILD_CHROOT_BASE; do
    run bash -c "cd '${ENTRY_REPO}' && ${legacy_var}=legacy PATH='${FAKEBIN}:${PATH}' bash scripts/trixie-build.sh"
    assert_status 2
    [[ "${output}" == *"legacy environment variable ${legacy_var} is no longer supported"* ]]
  done
}

@test "make trixie-build exports the default local backport version" {
  setup_entrypoint_repo
  install_fake_make
  run_make_build
  assert_status 0
  versions="$(make_versions)"
  [ "${versions}" = "1.5.0-1~debian13.1" ]
}

@test "make trixie-build preserves an OCSERV_VERSION override" {
  setup_entrypoint_repo
  install_fake_make
  run_make_build_with_version "1.5.0-1~bpo13+custom1"
  assert_status 0
  versions="$(make_versions)"
  [ "${versions}" = "1.5.0-1~bpo13+custom1" ]
}

@test "make trixie-auto-build delegates to scripts/trixie-auto-build.sh" {
  setup_entrypoint_repo
  cat > "${ENTRY_REPO}/scripts/trixie-auto-build.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\${TARGET_ARCH:-}" > "${ENTRY_REPO}/trixie-auto-build-target-arch"
SH
  chmod +x "${ENTRY_REPO}/scripts/trixie-auto-build.sh"

  run_make_trixie_auto_build

  assert_status 0
  [ "$(cat "${ENTRY_REPO}/trixie-auto-build-target-arch")" = "amd64" ]
}

@test "legacy Debian scripts are not present" {
  setup_entrypoint_repo

  for script in \
    build.sh \
    debian-auto-build.sh \
    debian-env.sh \
    fetch-source.sh \
    rewrap-changelog.sh \
    build-source-package.sh \
    build-binary.sh \
    build-binary-ocserv.sh \
    lint-package.sh \
    smoke-test.sh \
    source-package-ci.sh \
    dry-run.sh; do
    [ ! -e "${ENTRY_REPO}/scripts/${script}" ]
  done
}

@test "legacy Debian make targets are not defined" {
  setup_entrypoint_repo

  targets="$(
    cd "${ENTRY_REPO}" &&
      "${SYSTEM_MAKE}" -prRrq -f Makefile : 2>/dev/null |
        awk -F: '/^[^#.\t][^=]*:([^=]|$)/ { split($1,t,/[[:space:]]+/); for (i in t) if (t[i]!="") print t[i] }' |
        sort -u
  )"
  for target in build debian-auto-build verify-lock fetch rewrap src-pkg binary lint smoke-basic source-ci dry-run; do
    ! printf '%s\n' "${targets}" | grep -qx "${target}"
  done
}

@test "trixie-fetch-ocserv target delegates verification to fetch-source script" {
  setup_entrypoint_repo
  install_make_target_stub trixie-fetch-source.sh trixie-fetch-ocserv

  run bash -c "cd '${ENTRY_REPO}' && '${SYSTEM_MAKE}' trixie-fetch-ocserv"
  assert_status 0
  calls="$(entrypoint_file target-calls)"
  [ "${calls}" = "trixie-fetch-ocserv" ]
}

@test "build skips fetch target's duplicate lock verification" {
  setup_entrypoint_repo
  install_pipeline_target_stubs

  run bash -c "cd '${ENTRY_REPO}' && '${SYSTEM_MAKE}' trixie-build"
  assert_status 0
  calls="$(entrypoint_file target-calls)"
  [ "${calls}" = $'trixie-verify-locks\ntrixie-fetch-ocserv\ntrixie-rewrap-ocserv\ntrixie-src-pkg-ocserv\ntrixie-binary-ocserv\ntrixie-lint\ntrixie-smoke-basic' ]
}
