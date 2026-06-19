#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() { cd "${REPO_ROOT}"; }
teardown() { :; }

# ---- load_bootstrap_env_defaults ----
@test "fills unset vars and does NOT override already-set env vars" {
  export BOOTSTRAP_BUILDER_USER=from-env
  source scripts/_common.sh
  load_bootstrap_env_defaults test/fixtures/env/full.env
  [ "${BOOTSTRAP_BUILDER_USER}" = "from-env" ]      # not overridden
  [ "${BOOTSTRAP_APTLY_ROOT}" = "/var/aptly" ]      # filled from file
  [ "${BOOTSTRAP_REPO_NAME}" = "ocserv-backports" ]
  [ "${BOOTSTRAP_GPG_PASSPHRASE}" = "secret-with-=-sign" ]  # = not truncated
  [ -z "${WEIRD_VAR:-}" ]                            # non-BOOTSTRAP_ ignored
}

@test "strips surrounding double quotes from values" {
  unset BOOTSTRAP_APT_BASE_URL BOOTSTRAP_R2_BUCKET
  source scripts/_common.sh
  load_bootstrap_env_defaults test/fixtures/env/quoted.env
  [ "${BOOTSTRAP_APT_BASE_URL}" = "https://apt.example.com" ]
  [ "${BOOTSTRAP_R2_BUCKET}" = "apt-thehkus" ]
}

@test "skips blank and comment lines without error" {
  source scripts/_common.sh
  run load_bootstrap_env_defaults test/fixtures/env/full.env
  [ "$status" -eq 0 ]
}

# ---- require_var / is_set / cmd_exists ----
@test "require_var dies when var is unset" {
  source scripts/_common.sh
  unset MISSING_VAR_FOR_TEST
  run require_var MISSING_VAR_FOR_TEST
  [ "$status" -ne 0 ]
}

@test "is_set returns true for nonempty, false for empty/unset" {
  source scripts/_common.sh
  local X=val Y=""
  is_set X && true || false
  ! is_set Y
}

@test "cmd_exists finds bash, misses nosuchcmd_xyz" {
  source scripts/_common.sh
  cmd_exists bash
  ! cmd_exists nosuchcmd_xyz
}

# ---- run_cmd ----
@test "run_cmd executes the command when not dry-run" {
  source scripts/_common.sh
  BOOTSTRAP_DRY_RUN=0
  run run_cmd /bin/echo executed
  [ "$output" = "executed" ]
}

@test "run_cmd prints DRY-RUN and does NOT execute when dry-run" {
  source scripts/_common.sh
  BOOTSTRAP_DRY_RUN=1
  run run_cmd /bin/echo would-not-run-side-effect
  [ "$status" -eq 0 ]
  [[ "$output" == "DRY-RUN:"* ]]
}
