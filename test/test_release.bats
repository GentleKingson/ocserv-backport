#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  WORK="$(mktemp -d)"
  export OCSERV_DEBIAN_VERSION=2.0.0-1
  unset OCSERV_VERSION OCSERV_NOBLE_VERSION BACKPORT_REVISION
}

teardown() {
  rm -rf "${WORK}"
}

fake_deb() {
  mkdir -p "$(dirname -- "${WORK}/artifacts/$1")"
  printf '%s\n' "$1" > "${WORK}/artifacts/$1"
}

fake_build_artifacts() {
  local arch
  for arch in amd64 arm64; do
    fake_deb "debian-trixie-build-${arch}/build/debian/trixie/${arch}/binary/ocserv_2.0.0-1~debian13.1_${arch}.deb"
    fake_deb "ubuntu-noble-build-${arch}/build/ubuntu/noble/${arch}/binary/ocserv/ocserv_2.0.0-1~ubuntu24.04.1_${arch}.deb"
  done
}

@test "release scripts are executable for direct workflow calls" {
  [ -x scripts/release-preflight.sh ]
  [ -x scripts/release-collect-assets.sh ]
  [ -x scripts/release-render-notes.sh ]
}

@test "release preflight prints versions for a tag matching upstream" {
  run scripts/release-preflight.sh 2.0.0
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "ocserv_debian13=2.0.0-1~debian13.1" ]
  [ "${lines[1]}" = "ocserv_noble=2.0.0-1~ubuntu24.04.1" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "release preflight accepts suffixed tags of the upstream version" {
  run scripts/release-preflight.sh 2.0.0-2
  [ "${status}" -eq 0 ]
  run scripts/release-preflight.sh 2.0.0.1
  [ "${status}" -eq 0 ]
}

@test "release preflight rejects tags for other upstream versions" {
  local tag
  for tag in 2.1.0 2.0.00 v2.0.0; do
    run scripts/release-preflight.sh "${tag}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"does not match packaged ocserv 2.0.0"* ]]
  done
}

@test "release preflight rejects ocserv versions that are already published" {
  printf '%s\n' SHA256SUMS ocserv_2.0.0-1.ubuntu24.04.1_arm64.deb \
    > "${WORK}/published"
  run scripts/release-preflight.sh 2.0.0-2 "${WORK}/published"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ocserv 2.0.0-1~ubuntu24.04.1 is already published"* ]]

  run env BACKPORT_REVISION=2 \
    scripts/release-preflight.sh 2.0.0-2 "${WORK}/published"
  [ "${status}" -eq 0 ]
}

@test "release collect picks the four ocserv packages and writes checksums" {
  fake_build_artifacts
  run scripts/release-collect-assets.sh "${WORK}/artifacts" "${WORK}/release"
  [ "${status}" -eq 0 ]
  run bash -c "cd '${WORK}/release' && LC_ALL=C ls"
  [ "${output}" = "$(printf '%s\n' \
    SHA256SUMS \
    ocserv_2.0.0-1.debian13.1_amd64.deb \
    ocserv_2.0.0-1.debian13.1_arm64.deb \
    ocserv_2.0.0-1.ubuntu24.04.1_amd64.deb \
    ocserv_2.0.0-1.ubuntu24.04.1_arm64.deb)" ]
  run bash -c "cd '${WORK}/release' && sha256sum -c SHA256SUMS"
  [ "${status}" -eq 0 ]
}

@test "release collect fails when an architecture is missing" {
  fake_build_artifacts
  rm -rf "${WORK}/artifacts/ubuntu-noble-build-arm64"
  run scripts/release-collect-assets.sh "${WORK}/artifacts" "${WORK}/release"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"expected exactly one"*"ocserv_2.0.0-1~ubuntu24.04.1_arm64.deb, found 0"* ]]
}

@test "release collect fails when a package has an unexpected version" {
  fake_build_artifacts
  mv "${WORK}/artifacts/debian-trixie-build-amd64/build/debian/trixie/amd64/binary/ocserv_2.0.0-1~debian13.1_amd64.deb" \
    "${WORK}/artifacts/debian-trixie-build-amd64/build/debian/trixie/amd64/binary/ocserv_1.9.0-1~debian13.1_amd64.deb"
  run scripts/release-collect-assets.sh "${WORK}/artifacts" "${WORK}/release"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"ocserv_2.0.0-1~debian13.1_amd64.deb, found 0"* ]]
}

@test "release workflow builds both distributions on tag push and publishes" {
  workflow=".github/workflows/release.yml"

  grep -Fq -- "tags:" "${workflow}"
  grep -Fq -- "uses: ./.github/workflows/debian-trixie-build.yml" "${workflow}"
  grep -Fq -- "uses: ./.github/workflows/ubuntu-noble-build.yml" "${workflow}"
  grep -Fq -- "needs: [preflight, debian-trixie, ubuntu-noble]" "${workflow}"
  grep -Fq -- "contents: write" "${workflow}"
  grep -Fq -- "scripts/release-preflight.sh" "${workflow}"
  grep -Fq -- "scripts/release-collect-assets.sh" "${workflow}"
  grep -Fq -- "gh release create" "${workflow}"
  grep -Fq -- "workflow_call:" .github/workflows/debian-trixie-build.yml
  grep -Fq -- "workflow_call:" .github/workflows/ubuntu-noble-build.yml
}

@test "release workflow dry run skips publishing" {
  workflow=".github/workflows/release.yml"

  grep -Fq -- "workflow_dispatch:" "${workflow}"
  grep -Fq -- 'if [[ "${GITHUB_EVENT_NAME}" != push ]]; then' "${workflow}"
  grep -Fq -- "name: release-assets" "${workflow}"
  awk '/- name: Publish GitHub release/{getline; print}' "${workflow}" \
    | grep -Fq -- "if: github.event_name == 'push'"
}

@test "release notes render the template with the packaged versions" {
  run env TAG=2.0.0 OCSERV_DEBIAN13=2.0.0-1~debian13.1 \
    OCSERV_NOBLE=2.0.0-1~ubuntu24.04.1 scripts/release-render-notes.sh
  [ "${status}" -eq 0 ]
  [[ "${output}" == "## Packages"* ]]
  [[ "${output}" == *'`2.0.0-1~debian13.1`'* ]]
  [[ "${output}" == *'`2.0.0-1~ubuntu24.04.1`'* ]]
  [[ "${output}" == *"sha256sum -c --ignore-missing SHA256SUMS"* ]]
  [[ "${output}" != *'${'* ]]
}

@test "release notes put a per-tag notes file before the template" {
  mkdir -p "${WORK}/notes"
  printf '%s\n' '## Packages' '${OCSERV_NOBLE}' > "${WORK}/notes/template.md"
  printf '%s\n' '## Upgrade notes' 'Restart ocserv.' > "${WORK}/notes/2.0.0-2.md"
  run env TAG=2.0.0-2 OCSERV_DEBIAN13=d OCSERV_NOBLE=n \
    scripts/release-render-notes.sh "${WORK}/notes"
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf '%s\n' '## Upgrade notes' 'Restart ocserv.' '' \
    '## Packages' 'n')" ]
}

@test "release notes fail without the packaged versions" {
  run env -u OCSERV_NOBLE TAG=2.0.0 OCSERV_DEBIAN13=d \
    scripts/release-render-notes.sh
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"OCSERV_NOBLE must be set"* ]]
}

@test "release workflow appends generated notes grouped by labels" {
  workflow=".github/workflows/release.yml"

  grep -Fq -- "scripts/release-render-notes.sh" "${workflow}"
  grep -Fq -- "--generate-notes" "${workflow}"
  grep -Fq -- "name: release-notes" "${workflow}"
  grep -Fq -- "- release/internal" .github/release.yml
  grep -Fq -- '- "*"' .github/release.yml
  grep -Fq -- "- release/internal" .github/dependabot.yml
  grep -Fq -- "## Release note" .github/PULL_REQUEST_TEMPLATE.md
}
