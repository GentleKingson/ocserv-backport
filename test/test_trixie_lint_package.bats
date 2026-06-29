#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  LINT_REPO="$(mktemp -d)"
  FAKEBIN="$(mktemp -d)"
  mkdir -p "${LINT_REPO}/scripts" "${LINT_REPO}/build/debian/trixie/amd64/binary"
  cp "${REPO_ROOT}/scripts/_common.sh" "${LINT_REPO}/scripts/_common.sh"
  [[ -f "${REPO_ROOT}/scripts/_target_arch.sh" ]] && cp "${REPO_ROOT}/scripts/_target_arch.sh" "${LINT_REPO}/scripts/_target_arch.sh"
  cp "${REPO_ROOT}/scripts/_target_paths.sh" "${LINT_REPO}/scripts/_target_paths.sh"
  [[ -f "${REPO_ROOT}/scripts/trixie-env.sh" ]] && cp "${REPO_ROOT}/scripts/trixie-env.sh" "${LINT_REPO}/scripts/trixie-env.sh"
  cp "${REPO_ROOT}/scripts/trixie-lint-package.sh" "${LINT_REPO}/scripts/trixie-lint-package.sh"
  touch "${LINT_REPO}/build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.changes"
  cat > "${FAKEBIN}/lintian" <<SH
#!/usr/bin/env bash
printf 'lintian %s\n' "\$*" >> "${LINT_REPO}/lintian-calls"
exit 0
SH
  cat > "${FAKEBIN}/dpkg" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --print-architecture) printf '%s\n' "${FAKE_DPKG_ARCH:-amd64}" ;;
  *) exit 99 ;;
esac
SH
  cat > "${FAKEBIN}/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf '%s\n' "${FAKE_UNAME_M:-x86_64}" ;;
  *) exit 99 ;;
esac
SH
  chmod +x "${FAKEBIN}/lintian" "${FAKEBIN}/dpkg" "${FAKEBIN}/uname"
}

teardown() {
  [[ -n "${LINT_REPO:-}" ]] && rm -rf "${LINT_REPO}"
  [[ -n "${FAKEBIN:-}" ]] && rm -rf "${FAKEBIN}"
}

@test "lint-package suppresses trixie distribution tag by default" {
  run bash -c "cd '${LINT_REPO}' && PATH='${FAKEBIN}':\"\${PATH}\" bash scripts/trixie-lint-package.sh"

  [ "${status}" -eq 0 ]
  grep -Fxq -- "lintian --suppress-tags bad-distribution-in-changes-file --fail-on error build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.changes" "${LINT_REPO}/lintian-calls"
}

@test "lint-package passes explicit lintian profile" {
  run bash -c "cd '${LINT_REPO}' && LINTIAN_PROFILE=debian PATH='${FAKEBIN}':\"\${PATH}\" bash scripts/trixie-lint-package.sh"

  [ "${status}" -eq 0 ]
  grep -Fxq -- "lintian --profile debian --suppress-tags bad-distribution-in-changes-file --fail-on error build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.changes" "${LINT_REPO}/lintian-calls"
}

@test "lint-package allows suppress tag override" {
  run bash -c "cd '${LINT_REPO}' && LINTIAN_SUPPRESS_TAGS=custom-tag PATH='${FAKEBIN}':\"\${PATH}\" bash scripts/trixie-lint-package.sh"

  [ "${status}" -eq 0 ]
  grep -Fxq -- "lintian --suppress-tags custom-tag --fail-on error build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.changes" "${LINT_REPO}/lintian-calls"
}

@test "lint-package allows suppress tags to be disabled" {
  run bash -c "cd '${LINT_REPO}' && LINTIAN_SUPPRESS_TAGS= PATH='${FAKEBIN}':\"\${PATH}\" bash scripts/trixie-lint-package.sh"

  [ "${status}" -eq 0 ]
  grep -Fxq -- "lintian --fail-on error build/debian/trixie/amd64/binary/ocserv_1.5.0-1~debian13.1_amd64.changes" "${LINT_REPO}/lintian-calls"
}

@test "lint-package honors arm64 TARGET_ARCH paths" {
  mkdir -p "${LINT_REPO}/build/debian/trixie/arm64/binary"
  touch "${LINT_REPO}/build/debian/trixie/arm64/binary/ocserv_1.5.0-1~debian13.1_arm64.changes"

  run bash -c "cd '${LINT_REPO}' && FAKE_DPKG_ARCH=arm64 TARGET_ARCH=arm64 PATH='${FAKEBIN}':\"\${PATH}\" bash scripts/trixie-lint-package.sh"

  [ "${status}" -eq 0 ]
  grep -Fxq -- "lintian --suppress-tags bad-distribution-in-changes-file --fail-on error build/debian/trixie/arm64/binary/ocserv_1.5.0-1~debian13.1_arm64.changes" "${LINT_REPO}/lintian-calls"
}
