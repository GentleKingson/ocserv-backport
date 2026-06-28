#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  LINT_REPO="$(mktemp -d)"
  FAKEBIN="$(mktemp -d)"
  mkdir -p "${LINT_REPO}/scripts" "${LINT_REPO}/build/binary"
  cp "${REPO_ROOT}/scripts/_common.sh" "${LINT_REPO}/scripts/_common.sh"
  cp "${REPO_ROOT}/scripts/lint-package.sh" "${LINT_REPO}/scripts/lint-package.sh"
  touch "${LINT_REPO}/build/binary/ocserv_1.5.0-1~bpo13+0local1_amd64.changes"
  cat > "${FAKEBIN}/lintian" <<SH
#!/usr/bin/env bash
printf 'lintian %s\n' "\$*" >> "${LINT_REPO}/lintian-calls"
exit 0
SH
  chmod +x "${FAKEBIN}/lintian"
}

teardown() {
  [[ -n "${LINT_REPO:-}" ]] && rm -rf "${LINT_REPO}"
  [[ -n "${FAKEBIN:-}" ]] && rm -rf "${FAKEBIN}"
}

@test "lint-package runs lintian without profile by default" {
  run bash -c "cd '${LINT_REPO}' && PATH='${FAKEBIN}':\"\${PATH}\" bash scripts/lint-package.sh"

  [ "${status}" -eq 0 ]
  grep -Fxq -- "lintian --fail-on error build/binary/ocserv_1.5.0-1~bpo13+0local1_amd64.changes" "${LINT_REPO}/lintian-calls"
}

@test "lint-package passes explicit lintian profile" {
  run bash -c "cd '${LINT_REPO}' && LINTIAN_PROFILE=debian PATH='${FAKEBIN}':\"\${PATH}\" bash scripts/lint-package.sh"

  [ "${status}" -eq 0 ]
  grep -Fxq -- "lintian --profile debian --fail-on error build/binary/ocserv_1.5.0-1~bpo13+0local1_amd64.changes" "${LINT_REPO}/lintian-calls"
}
