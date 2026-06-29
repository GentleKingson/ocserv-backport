#!/usr/bin/env bats
#
# Regression guard: scripts invoked directly by Makefile targets (relying on the
# shebang + exec bit) must remain executable. A file edit that drops the mode
# from 100755 to 100644 makes the Makefile fail with "Permission denied" (exit
# 126) at the affected target. bats invokes scripts via "bash scripts/...", so
# the exec bit is invisible to every other test; this guard closes that gap.
#
# Sourced library helpers (_noble_sbuild.sh, noble-env.sh, _common.sh, _dsc.sh)
# are NOT invoked directly and are intentionally excluded; they stay 100644.
load helpers/bats-helper.bash

# Authoritative list: every "scripts/<name>.sh ..." recipe line in the Makefile
# that is NOT prefixed with an interpreter. Update this list if a Makefile
# target adds a new directly-invoked script.
DIRECTLY_INVOKED_SCRIPTS=(
  verify-source-lock.sh
  trixie-fetch-source.sh
  trixie-rewrap-changelog.sh
  trixie-build-source-package.sh
  trixie-build-binary-ocserv.sh
  trixie-lint-package.sh
  trixie-smoke-test.sh
  trixie-build.sh
  trixie-auto-build.sh
  trixie-source-package-ci.sh
  noble-build.sh
  noble-auto-build.sh
  noble-fetch-source.sh
  noble-rewrap-changelog.sh
  noble-build-source-package.sh
  noble-build-binary-node-undici.sh
  noble-build-binary-ocserv.sh
  noble-build-repo.sh
  noble-lint-package.sh
  noble-smoke-test.sh
)

@test "every Makefile-invoked script is executable in the git index" {
  local script failures=0
  for script in "${DIRECTLY_INVOKED_SCRIPTS[@]}"; do
    mode="$(git ls-files --stage "scripts/${script}" | awk '{print $1}')"
    if [[ "${mode}" != "100755" ]]; then
      echo "scripts/${script} has git mode ${mode}, expected 100755" >&2
      failures=$((failures + 1))
    fi
  done
  [[ "${failures}" -eq 0 ]]
}

@test "every Makefile-invoked script is executable in the working tree" {
  local script failures=0
  for script in "${DIRECTLY_INVOKED_SCRIPTS[@]}"; do
    if [[ ! -x "${REPO_ROOT}/scripts/${script}" ]]; then
      echo "scripts/${script} is not executable in the working tree" >&2
      failures=$((failures + 1))
    fi
  done
  [[ "${failures}" -eq 0 ]]
}

@test "noble-rewrap-changelog.sh is directly invokable via its shebang" {
  # This is the exact invocation form the Makefile uses. It must not fail with
  # exit 126 (Permission denied). It will exit non-zero on a missing source
  # tree (expected here); we only assert the exec bit is honored.
  run "${REPO_ROOT}/scripts/noble-rewrap-changelog.sh" node-undici
  [[ "${status}" -ne 126 ]]
}
