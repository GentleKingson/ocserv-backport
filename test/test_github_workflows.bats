#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  WORK=""
}

teardown() {
  if [[ -n "${WORK:-}" ]]; then
    rm -rf -- "${WORK}"
  fi
}

assert_build_workflow_contract() {
  local workflow="$1" slug="$2" auto_script="$3" target_root="$4" runner_base="$5"

  [ -f "${workflow}" ]

  grep -Fq -- "workflow_dispatch:" "${workflow}"
  grep -Fq -- "workflow_call:" "${workflow}"
  grep -Fq -- "name: ${slug}-\${{ matrix.arch }}" "${workflow}"
  grep -Fq -- "strategy:" "${workflow}"
  grep -Fq -- "fail-fast: false" "${workflow}"
  grep -Fq -- "matrix:" "${workflow}"
  grep -Fq -- "arch: amd64" "${workflow}"
  grep -Fq -- "runner: ${runner_base}" "${workflow}"
  grep -Fq -- "arch: arm64" "${workflow}"
  grep -Fq -- "runner: ${runner_base}-arm" "${workflow}"
  grep -Fq -- 'runs-on: ${{ matrix.runner }}' "${workflow}"
  grep -Fq -- "timeout-minutes: 240" "${workflow}"
  grep -Fq -- 'TARGET_ARCH: ${{ matrix.arch }}' "${workflow}"
  grep -Fq -- "scripts/ci-ensure-disk-space.sh" "${workflow}"
  grep -Fq -- "sudo --preserve-env=TARGET_ARCH \\" "${workflow}"
  grep -Fq -- "./scripts/${auto_script} --provision --yes" "${workflow}"
  grep -Fq -- "scripts/ci-stage-build-artifacts.sh" "${workflow}"
  grep -Fq -- "\"${target_root}/\${TARGET_ARCH}\"" "${workflow}"
  grep -Fq -- "name: ${slug}-\${{ matrix.arch }}" "${workflow}"
  grep -Fq -- "scripts/ci-prepare-build-logs.sh" "${workflow}"
  grep -Fq -- "\"${target_root}\"" "${workflow}"
  grep -Fq -- "name: ${slug}-logs-\${{ matrix.arch }}" "${workflow}"
  [ "$(grep -Fc -- "if: always()" "${workflow}")" -eq 2 ]
  grep -Fq -- "if-no-files-found: error" "${workflow}"
  grep -Fq -- "if-no-files-found: warn" "${workflow}"
  grep -Eq -- "actions/checkout@v[0-9]+" "${workflow}"
  grep -Eq -- "actions/upload-artifact@v[0-9]+" "${workflow}"
}

@test "Ubuntu Noble build workflow matches aligned build contract" {
  assert_build_workflow_contract \
    .github/workflows/ubuntu-noble-build.yml \
    ubuntu-noble-build \
    noble-auto-build.sh \
    build/ubuntu/noble \
    ubuntu-24.04
}

@test "Ubuntu Resolute build workflow matches aligned build contract" {
  assert_build_workflow_contract \
    .github/workflows/ubuntu-resolute-build.yml \
    ubuntu-resolute-build \
    resolute-auto-build.sh \
    build/ubuntu/resolute \
    ubuntu-26.04
}

@test "Debian Trixie build workflow matches aligned build contract" {
  assert_build_workflow_contract \
    .github/workflows/debian-trixie-build.yml \
    debian-trixie-build \
    trixie-auto-build.sh \
    build/debian/trixie \
    ubuntu-24.04
}

@test "Dependabot keeps GitHub Actions versions current" {
  grep -Fq -- "package-ecosystem: github-actions" .github/dependabot.yml
}

@test "GitHub workflows use Node 24 action majors" {
  local ref action major min_major

  while read -r ref; do
    action="${ref%@v*}"
    major="${ref##*@v}"
    case "${action}" in
      actions/checkout | actions/upload-artifact) min_major=6 ;;
      actions/download-artifact) min_major=7 ;;
      *)
        echo "unmapped action in Node 24 guard: ${ref}" >&2
        return 1
        ;;
    esac
    [ "${major}" -ge "${min_major}" ] || {
      echo "outdated action major: ${ref} (need >= v${min_major})" >&2
      return 1
    }
  done < <(
    grep -RhoE -- "actions/[a-zA-Z0-9_-]+@v[0-9]+" .github/workflows | sort -u
  )
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

@test "CI helper scripts are executable" {
  local script
  for script in \
    scripts/ci-debian-keyrings.sh \
    scripts/ci-ensure-disk-space.sh \
    scripts/ci-stage-build-artifacts.sh \
    scripts/ci-prepare-build-logs.sh; do
    [ -x "${script}" ]
  done
}

@test "ci-stage-build-artifacts stages ocserv source and binary outputs" {
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/build/ubuntu/noble/amd64/source" \
    "${WORK}/build/ubuntu/noble/amd64/binary"
  : > "${WORK}/build/ubuntu/noble/amd64/source/ocserv_1.6.0-0local1~ubuntu24.04.1.dsc"
  : > "${WORK}/build/ubuntu/noble/amd64/source/ocserv_1.6.0.orig.tar.xz"
  : > "${WORK}/build/ubuntu/noble/amd64/source/unrelated.txt"
  : > "${WORK}/build/ubuntu/noble/amd64/binary/ocserv_1.6.0-0local1~ubuntu24.04.1_amd64.deb"
  : > "${WORK}/build/ubuntu/noble/amd64/binary/ocserv_1.6.0-0local1~ubuntu24.04.1_amd64.changes"
  : > "${WORK}/build/ubuntu/noble/amd64/binary/ocserv_1.6.0-0local1~ubuntu24.04.1_amd64.build"

  run bash -c "cd '${WORK}' && '${REPO_ROOT}/scripts/ci-stage-build-artifacts.sh' build/ubuntu/noble/amd64 '${WORK}/staged'"
  [ "${status}" -eq 0 ]
  [ -f "${WORK}/staged/build/ubuntu/noble/amd64/source/ocserv_1.6.0-0local1~ubuntu24.04.1.dsc" ]
  [ -f "${WORK}/staged/build/ubuntu/noble/amd64/source/ocserv_1.6.0.orig.tar.xz" ]
  [ ! -e "${WORK}/staged/build/ubuntu/noble/amd64/source/unrelated.txt" ]
  [ -f "${WORK}/staged/build/ubuntu/noble/amd64/binary/ocserv_1.6.0-0local1~ubuntu24.04.1_amd64.deb" ]
  [ -f "${WORK}/staged/build/ubuntu/noble/amd64/binary/ocserv_1.6.0-0local1~ubuntu24.04.1_amd64.changes" ]
  [ ! -e "${WORK}/staged/build/ubuntu/noble/amd64/binary/ocserv_1.6.0-0local1~ubuntu24.04.1_amd64.build" ]
}

@test "ci-prepare-build-logs copies logs and sanitizes colons" {
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/build/ubuntu/noble/amd64/binary"
  printf 'log\n' > "${WORK}/build/ubuntu/noble/amd64/binary/ocserv_1:1.6.0_amd64.build"
  printf 'ignore\n' > "${WORK}/build/ubuntu/noble/amd64/binary/ocserv_1.6.0_amd64.deb"

  run bash -c "cd '${WORK}' && '${REPO_ROOT}/scripts/ci-prepare-build-logs.sh' build/ubuntu/noble '${WORK}/logs'"
  [ "${status}" -eq 0 ]
  [ -f "${WORK}/logs/build/ubuntu/noble/amd64/binary/ocserv_1_1.6.0_amd64.build" ]
  [ ! -e "${WORK}/logs/build/ubuntu/noble/amd64/binary/ocserv_1.6.0_amd64.deb" ]
}

@test "primary CI runs checks and scheduled source package matrix" {
  workflow=".github/workflows/ci.yml"

  [ -f "${workflow}" ]

  grep -Fq -- "'.github/**'" "${workflow}"
  grep -Fq -- "workflow_dispatch:" "${workflow}"
  grep -Fq -- "schedule:" "${workflow}"
  grep -Fq -- "cron: '23 3 * * 1'" "${workflow}"
  grep -Fq -- "target:" "${workflow}"
  grep -Fq -- "required: true" "${workflow}"
  grep -Fq -- "default: checks" "${workflow}"
  grep -Fq -- "type: choice" "${workflow}"
  grep -Fq -- "source-package" "${workflow}"
  grep -Fq -- "all" "${workflow}"
  grep -Fq -- "make test" "${workflow}"
  ! grep -Fq -- "ci-script-test" "${workflow}"
  grep -Fq -- "image: debian:trixie" "${workflow}"
  grep -Fq -- "target: trixie-source-ci" "${workflow}"
  grep -Fq -- "image: ubuntu:24.04" "${workflow}"
  grep -Fq -- "target: noble-source-ci" "${workflow}"
  grep -Fq -- "image: ubuntu:26.04" "${workflow}"
  grep -Fq -- "target: resolute-source-ci" "${workflow}"
  grep -Fq -- 'scripts/ci-debian-keyrings.sh "${RUNNER_TEMP}/debian-keyrings"' "${workflow}"
  grep -Fq -- '>> "${GITHUB_ENV}"' "${workflow}"
}

@test "README is a concise project entrypoint" {
  grep -Fq -- "# ocserv-backport" README.md
  grep -Fq -- "Debian 13" README.md
  grep -Fq -- "Ubuntu 24.04" README.md
  grep -Fq -- "Ubuntu 26.04" README.md
  grep -Fq -- "## Build Guides" README.md
  grep -Fq -- "[Build on Debian 13](docs/build-ocserv-backport-on-debian13.md)" README.md
  grep -Fq -- "[Build on Ubuntu 24.04](docs/build-ocserv-backport-on-ubuntu24.04.md)" README.md
  grep -Fq -- "[Build on Ubuntu 26.04](docs/build-ocserv-backport-on-ubuntu26.04.md)" README.md
  [ -f docs/build-ocserv-backport-on-debian13.md ]
  [ -f docs/build-ocserv-backport-on-ubuntu24.04.md ]
  [ -f docs/build-ocserv-backport-on-ubuntu26.04.md ]
}

@test "README does not duplicate workflow or command reference details" {
  ! grep -Eq -- "Source Locks|Boundaries|GitHub Actions|workflow|manual Debian|manual Ubuntu|scripts/|make " README.md
}
