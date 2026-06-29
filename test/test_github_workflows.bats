#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
}

@test "manual Ubuntu Noble build workflow matches documented contract" {
  workflow=".github/workflows/ubuntu-noble-build.yml"

  [ -f "${workflow}" ]

  grep -Fq -- "workflow_dispatch:" "${workflow}"
  grep -Fq -- "strategy:" "${workflow}"
  grep -Fq -- "fail-fast: false" "${workflow}"
  grep -Fq -- "matrix:" "${workflow}"
  grep -Fq -- "arch: amd64" "${workflow}"
  grep -Fq -- "runner: ubuntu-24.04" "${workflow}"
  grep -Fq -- "arch: arm64" "${workflow}"
  grep -Fq -- "runner: ubuntu-24.04-arm" "${workflow}"
  grep -Fq -- 'runs-on: ${{ matrix.runner }}' "${workflow}"
  grep -Fq -- "timeout-minutes: 240" "${workflow}"
  grep -Fq -- 'TARGET_ARCH: ${{ matrix.arch }}' "${workflow}"
  grep -Fq -- "sudo --preserve-env=TARGET_ARCH \\" "${workflow}"
  grep -Fq -- "./scripts/noble-auto-build.sh --provision" "${workflow}"
  grep -Fq -- "Stage Ubuntu Noble artifacts" "${workflow}"
  grep -Fq -- 'staging="${RUNNER_TEMP}/ubuntu-noble-artifacts"' "${workflow}"
  grep -Fq -- 'rm -rf "${staging}"' "${workflow}"
  grep -Fq -- 'build/ubuntu/noble/${TARGET_ARCH}' "${workflow}"
  grep -Fq -- 'find "${target_root}/source/node-undici"' "${workflow}"
  grep -Fq -- 'find "${target_root}/source/ocserv"' "${workflow}"
  grep -Fq -- 'find "${target_root}/binary/node-undici"' "${workflow}"
  grep -Fq -- 'find "${target_root}/binary/ocserv"' "${workflow}"
  grep -Fq -- 'find "${target_root}/repo"' "${workflow}"
  ! grep -Fq -- 'cp -a "${target_root}/source"' "${workflow}"
  ! grep -Fq -- 'cp -a "${target_root}/binary"' "${workflow}"
  grep -Fq -- '${{ runner.temp }}/ubuntu-noble-artifacts/**' "${workflow}"
  grep -Fq -- 'ubuntu-noble-build-${{ matrix.arch }}' "${workflow}"
  grep -Fq -- 'ubuntu-noble-build-logs-${{ matrix.arch }}' "${workflow}"
  grep -Fq -- "actions/checkout@v6" "${workflow}"
  grep -Fq -- "actions/upload-artifact@v6" "${workflow}"
}

@test "GitHub workflows use Node 24 action majors" {
  ! grep -R -Fq -- "actions/checkout@v4" .github/workflows
  ! grep -R -Fq -- "actions/upload-artifact@v4" .github/workflows
}

@test "manual Debian Trixie build workflow matches documented contract" {
  workflow=".github/workflows/debian-trixie-build.yml"

  [ -f "${workflow}" ]

  grep -Fq -- "workflow_dispatch:" "${workflow}"
  grep -Fq -- "strategy:" "${workflow}"
  grep -Fq -- "fail-fast: false" "${workflow}"
  grep -Fq -- "matrix:" "${workflow}"
  grep -Fq -- "arch: amd64" "${workflow}"
  grep -Fq -- "runner: ubuntu-24.04" "${workflow}"
  grep -Fq -- "arch: arm64" "${workflow}"
  grep -Fq -- "runner: ubuntu-24.04-arm" "${workflow}"
  grep -Fq -- 'runs-on: ${{ matrix.runner }}' "${workflow}"
  grep -Fq -- 'name: debian-trixie-build-${{ matrix.arch }}' "${workflow}"
  grep -Fq -- "timeout-minutes: 240" "${workflow}"
  grep -Fq -- 'TARGET_ARCH: ${{ matrix.arch }}' "${workflow}"
  grep -Fq -- "sudo --preserve-env=TARGET_ARCH \\" "${workflow}"
  grep -Fq -- "./scripts/debian-auto-build.sh --provision" "${workflow}"
  grep -Fq -- "Stage Debian Trixie artifacts" "${workflow}"
  grep -Fq -- 'staging="${RUNNER_TEMP}/debian-trixie-artifacts"' "${workflow}"
  grep -Fq -- 'rm -rf "${staging}"' "${workflow}"
  grep -Fq -- 'build/debian/trixie/${TARGET_ARCH}' "${workflow}"
  grep -Fq -- 'find "${target_root}/source"' "${workflow}"
  grep -Fq -- 'find "${target_root}/binary"' "${workflow}"
  ! grep -Fq -- 'cp -a "${target_root}/source"' "${workflow}"
  ! grep -Fq -- 'cp -a "${target_root}/binary"' "${workflow}"
  grep -Fq -- '${{ runner.temp }}/debian-trixie-artifacts/**' "${workflow}"
  grep -Fq -- 'debian-trixie-build-${{ matrix.arch }}' "${workflow}"
  grep -Fq -- 'debian-trixie-build-logs-${{ matrix.arch }}' "${workflow}"
  grep -Fq -- "if: always()" "${workflow}"
  grep -Fq -- "if-no-files-found: warn" "${workflow}"
  grep -Fq -- "if-no-files-found: error" "${workflow}"
  grep -Fq -- "actions/checkout@v6" "${workflow}"
  grep -Fq -- "actions/upload-artifact@v6" "${workflow}"
}

@test "YAML files checked by CI stay within yamllint line length" {
  local output

  output="$(
    python3 - <<'PY'
from pathlib import Path

for root in (Path(".github"), Path("source-lock")):
    for yaml_file in sorted(root.rglob("*")):
        if yaml_file.suffix not in {".yml", ".yaml"}:
            continue
        for line_number, line in enumerate(yaml_file.read_text().splitlines(), 1):
            if len(line) > 80:
                print(f"{yaml_file}:{line_number}:{len(line)}:{line}")
PY
  )"

  [ -z "${output}" ] || {
    printf '%s\n' "${output}" >&2
    return 1
  }
}

@test "manual Ubuntu Noble build workflow delegates Debian keyring refresh to script" {
  workflow=".github/workflows/ubuntu-noble-build.yml"

  ! grep -Fq -- "Refresh Debian source verification keyrings" "${workflow}"
  ! grep -Fq -- "debian:sid" "${workflow}"
  ! grep -Fq -- "DSCVERIFY_KEYRING_PATHS" "${workflow}"
  ! grep -Fq -- "GITHUB_ENV" "${workflow}"
}

@test "manual Ubuntu Noble build workflow conditionally frees runner disk space" {
  workflow=".github/workflows/ubuntu-noble-build.yml"

  grep -Fq -- "Ensure enough runner disk space" "${workflow}"
  ! grep -Fq -- "Free runner disk space" "${workflow}"
  grep -Fq -- "min_free_gib=8" "${workflow}"
  grep -Fq -- 'df -h / "$GITHUB_WORKSPACE" /tmp' "${workflow}"
  grep -Fq -- "df --output=avail /" "${workflow}"
  grep -Fq -- 'tr -d '"'"'[:space:]'"'"'' "${workflow}"
  grep -Fq -- '[[ "${avail_kb}" =~ ^[0-9]+$ ]]' "${workflow}"
  grep -Fq -- "if (( avail_kb < min_free_kb )); then" "${workflow}"
  grep -Fq -- "::error::Insufficient free disk" "${workflow}"
  grep -Fq -- "/usr/share/dotnet" "${workflow}"
  grep -Fq -- "/usr/local/lib/android" "${workflow}"
  grep -Fq -- "/usr/local/share/boost" "${workflow}"
  grep -Fq -- "/usr/local/.ghcup" "${workflow}"
  grep -Fq -- "/opt/ghc" "${workflow}"
  grep -Fq -- "/opt/hostedtoolcache/CodeQL" "${workflow}"
  grep -Fq -- "docker system prune -af || true" "${workflow}"
}

@test "manual Ubuntu Noble build workflow sanitizes failure logs before upload" {
  workflow=".github/workflows/ubuntu-noble-build.yml"

  grep -Fq -- "Prepare Ubuntu Noble build logs" "${workflow}"
  grep -Fq -- 'upload_dir="${RUNNER_TEMP}/noble-upload-logs"' "${workflow}"
  grep -Fq -- "noble-upload-logs" "${workflow}"
  grep -Fq -- "safe_name=\"\${rel//:/_}\"" "${workflow}"
  grep -Fq -- '${{ runner.temp }}/noble-upload-logs/**' "${workflow}"
  grep -Fq -- "find build/ubuntu/noble" "${workflow}"
  ! grep -Fq -- "build/noble/**/*.build" "${workflow}"
  ! grep -Fq -- "find build/noble" "${workflow}"
}

@test "manual Debian Trixie build workflow conditionally frees runner disk space" {
  workflow=".github/workflows/debian-trixie-build.yml"

  grep -Fq -- "Ensure enough runner disk space" "${workflow}"
  grep -Fq -- "min_free_gib=8" "${workflow}"
  grep -Fq -- 'df -h / "$GITHUB_WORKSPACE" /tmp' "${workflow}"
  grep -Fq -- "df --output=avail /" "${workflow}"
  grep -Fq -- "docker system prune -af || true" "${workflow}"
  grep -Fq -- "::error::Insufficient free disk" "${workflow}"
}

@test "manual Debian Trixie build workflow sanitizes failure logs before upload" {
  workflow=".github/workflows/debian-trixie-build.yml"

  grep -Fq -- "Prepare Debian Trixie build logs" "${workflow}"
  grep -Fq -- 'upload_dir="${RUNNER_TEMP}/debian-trixie-upload-logs"' "${workflow}"
  grep -Fq -- "safe_name=\"\${rel//:/_}\"" "${workflow}"
  grep -Fq -- '${{ runner.temp }}/debian-trixie-upload-logs/**' "${workflow}"
  grep -Fq -- "find build/debian/trixie" "${workflow}"
  ! grep -Fq -- "build/**/*.build" "${workflow}"
}

@test "primary CI runs source package verification without artifacts" {
  workflow=".github/workflows/ci.yml"
  removed_workflow=".github/workflows/source-ci"
  removed_workflow+=".yml"
  stage_step="Stage source package"
  stage_step+=" artifacts"
  upload_step="Upload source package"
  upload_step+=" artifacts"
  staging_dir="source-package"
  staging_dir+="-artifacts"
  artifact_name="ocserv-source"
  artifact_name+="-package"

  [ -f "${workflow}" ]
  [ ! -f "${removed_workflow}" ]

  grep -Fq -- "workflow_dispatch:" "${workflow}"
  grep -Fq -- "schedule:" "${workflow}"
  grep -Fq -- "cron: '23 3 * * 1'" "${workflow}"
  grep -Fq -- "target:" "${workflow}"
  grep -Fq -- "required: true" "${workflow}"
  grep -Fq -- "default: checks" "${workflow}"
  grep -Fq -- "type: choice" "${workflow}"
  grep -Fq -- "source-package" "${workflow}"
  grep -Fq -- "all" "${workflow}"
  grep -Fq -- "github.event_name == 'push'" "${workflow}"
  grep -Fq -- "github.event_name == 'pull_request'" "${workflow}"
  grep -Fq -- "github.event_name == 'schedule'" "${workflow}"
  grep -Fq -- "inputs.target == 'checks'" "${workflow}"
  grep -Fq -- "inputs.target == 'source-package'" "${workflow}"
  grep -Fq -- "TARGET_ARCH: amd64" "${workflow}"
  grep -Fq -- "image: debian:trixie" "${workflow}"
  grep -Fq -- "actions/checkout@v6" "${workflow}"
  grep -Fq -- "Refresh Debian source verification keyrings" "${workflow}"
  grep -Fq -- "Suites: sid" "${workflow}"
  grep -Fq -- "apt_sid() {" "${workflow}"
  grep -Fq -- "apt_sid download \\" "${workflow}"
  grep -Fq -- "debian-keyring" "${workflow}"
  grep -Fq -- "DSCVERIFY_KEYRING_PATHS=" "${workflow}"
  grep -Fq -- "GITHUB_ENV" "${workflow}"
  grep -Fq -- "make source-ci" "${workflow}"
  ! grep -Fq -- "${stage_step}" "${workflow}"
  ! grep -Fq -- "${upload_step}" "${workflow}"
  ! grep -Fq -- "${staging_dir}" "${workflow}"
  ! grep -Fq -- "${artifact_name}" "${workflow}"
}

@test "primary CI watches every GitHub workflow file" {
  old_source_workflow=".github/workflows/source-ci"
  old_source_workflow+=".yml"

  grep -Fq -- "'.github/workflows/**'" .github/workflows/ci.yml
  ! grep -Fq -- "'${old_source_workflow}'" .github/workflows/ci.yml
}

@test "README documents the manual Ubuntu 24.04 build workflow" {
  grep -Fq -- ".github/workflows/ubuntu-noble-build.yml" README.md
  grep -Fq -- "Manual Ubuntu 24.04 build workflow" README.md
  grep -Fq -- "amd64 and arm64" README.md
  grep -Fq -- "ubuntu-24.04-arm" README.md
  grep -Fq -- "does not publish packages, deploy hosts, or read repository secrets" README.md
}

@test "README documents the manual Debian 13 build workflow" {
  grep -Fq -- ".github/workflows/debian-trixie-build.yml" README.md
  grep -Fq -- "Manual Debian 13 build workflow" README.md
  grep -Fq -- "does not publish packages, deploy hosts, or read repository secrets" README.md
}
