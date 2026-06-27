#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
}

@test "manual Ubuntu Noble build workflow matches documented contract" {
  workflow=".github/workflows/ubuntu-noble-build.yml"

  [ -f "${workflow}" ]

  grep -Fq -- "workflow_dispatch:" "${workflow}"
  grep -Fq -- "runs-on: ubuntu-24.04" "${workflow}"
  grep -Fq -- "timeout-minutes: 240" "${workflow}"
  grep -Fq -- "TARGET_ARCH: amd64" "${workflow}"
  grep -Fq -- "sudo --preserve-env=TARGET_ARCH \\" "${workflow}"
  grep -Fq -- "./scripts/noble-auto-build.sh --provision" "${workflow}"
  grep -Fq -- "ubuntu-noble-build-amd64" "${workflow}"
  grep -Fq -- "ubuntu-noble-build-logs-amd64" "${workflow}"
  grep -Fq -- "actions/upload-artifact@v4" "${workflow}"
}

@test "primary CI watches every GitHub workflow file" {
  grep -Fq -- "'.github/workflows/**'" .github/workflows/ci.yml
  ! grep -Fq -- "'.github/workflows/source-ci.yml'" .github/workflows/ci.yml
}

@test "README documents the manual Ubuntu Noble build workflow" {
  grep -Fq -- ".github/workflows/ubuntu-noble-build.yml" README.md
  grep -Fq -- "Manual Ubuntu Noble build workflow" README.md
  grep -Fq -- "does not publish packages, deploy hosts, or read repository secrets" README.md
}
