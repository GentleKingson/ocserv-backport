#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}"
  unset BOOTSTRAP_BUILDER_USER BOOTSTRAP_APTLY_ROOT BOOTSTRAP_REPO_NAME \
        BOOTSTRAP_APT_BASE_URL BOOTSTRAP_R2_BUCKET BOOTSTRAP_GPG_KEYID \
        BOOTSTRAP_GPG_PASSPHRASE BUILDER_USER APTLY_ROOT REPO_NAME \
        APT_BASE_URL R2_BUCKET 2>/dev/null || true
}

# load_defaults_and_aliases is defined in scripts/bootstrap-build-host.sh.
# The script guards main() behind BASH_SOURCE so sourcing it does not run main.

@test "fills all declared defaults when env unset" {
  source scripts/bootstrap-build-host.sh
  load_defaults_and_aliases
  [ "${BOOTSTRAP_BUILDER_USER}" = "builder" ]
  [ "${BOOTSTRAP_APTLY_ROOT}" = "/var/aptly" ]
  [ "${BOOTSTRAP_REPO_NAME}" = "ocserv-backports" ]
  [ "${BOOTSTRAP_APT_BASE_URL}" = "https://apt.example.com" ]
  [ "${BOOTSTRAP_R2_BUCKET}" = "apt-thehkus" ]
}

@test "does not override caller-provided values" {
  export BOOTSTRAP_BUILDER_USER=ops
  source scripts/bootstrap-build-host.sh
  load_defaults_and_aliases
  [ "${BOOTSTRAP_BUILDER_USER}" = "ops" ]
}

@test "exposes unified internal aliases" {
  source scripts/bootstrap-build-host.sh
  load_defaults_and_aliases
  [ "${BUILDER_USER}" = "builder" ]
  [ "${APTLY_ROOT}" = "/var/aptly" ]
  [ "${REPO_NAME}" = "ocserv-backports" ]
  [ "${APT_BASE_URL}" = "https://apt.example.com" ]
  [ "${R2_BUCKET}" = "apt-thehkus" ]
}
