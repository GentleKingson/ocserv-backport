#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() { cd "${REPO_ROOT}"; }

# Source _common.sh into a subshell and invoke require_cmds via a wrapper,
# since require_cmds is a function (not a standalone script). die() exits the
# subshell with status 1.
run_require() {
  run bash -c "set -euo pipefail; source '${REPO_ROOT}/scripts/_common.sh'; require_cmds \"\$@\"" _ "$@"
}

@test "require_cmds: all present -> exit 0, no output" {
  # ls (coreutils) and bash itself are guaranteed present on any test host.
  run_require ls:coreutils bash:bash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "require_cmds: missing command -> die with package + fix guidance" {
  # zzz-not-a-real-cmd-xyz is guaranteed absent.
  run_require zzz-not-a-real-cmd-xyz:fakepkg ls:coreutils
  [ "$status" -ne 0 ]
  # multi-line message mentions the command, the package, and the fix.
  echo "$output" | grep -q "zzz-not-a-real-cmd-xyz"
  echo "$output" | grep -q "fakepkg"
  echo "$output" | grep -q "apt-get install"
  echo "$output" | grep -q "bootstrap-build-host"
}

@test "require_cmds: reports ALL missing commands at once, not just the first" {
  run_require zzz-missing-one:pkg-one zzz-missing-two:pkg-two ls:coreutils
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "zzz-missing-one"
  echo "$output" | grep -q "zzz-missing-two"
  echo "$output" | grep -q "pkg-one"
  echo "$output" | grep -q "pkg-two"
}

@test "require_cmds: no args -> exit 0 (defensive no-op)" {
  run_require
  [ "$status" -eq 0 ]
}
