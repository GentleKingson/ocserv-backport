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
  grep -Fq -- "actions/checkout@v6" "${workflow}"
  grep -Fq -- "actions/upload-artifact@v6" "${workflow}"
}

@test "GitHub workflows use Node 24 action majors" {
  ! grep -R -Fq -- "actions/checkout@v4" .github/workflows
  ! grep -R -Fq -- "actions/upload-artifact@v4" .github/workflows
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
  ! grep -Fq -- "build/noble/**/*.build" "${workflow}"
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
