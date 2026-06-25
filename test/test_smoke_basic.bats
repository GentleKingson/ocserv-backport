#!/usr/bin/env bats
load helpers/bats-helper.bash

setup_smoke_repo() {
  SMOKE_REPO="$(mktemp -d)"
  mkdir -p "${SMOKE_REPO}/scripts" "${SMOKE_REPO}/build/binary"
  cp "${REPO_ROOT}/scripts/_common.sh" "${SMOKE_REPO}/scripts/_common.sh"
  cp "${REPO_ROOT}/scripts/smoke-test.sh" "${SMOKE_REPO}/scripts/smoke-test.sh"
  FAKEBIN="$(mktemp -d)"
}

teardown_smoke_repo() {
  [[ -n "${SMOKE_REPO:-}" ]] && rm -rf "${SMOKE_REPO}"
  [[ -n "${FAKEBIN:-}" ]] && rm -rf "${FAKEBIN}"
  SMOKE_REPO=""
  FAKEBIN=""
}

write_deb() {
  local path="${SMOKE_REPO}/build/binary/${1:-ocserv_1.5.0-1~bpo13+0local1_amd64.deb}"
  printf 'fake deb\n' > "${path}"
}

install_fake_dpkg_deb() {
  cat > "${FAKEBIN}/dpkg-deb" <<'SH'
#!/usr/bin/env bash
field="$3"
case "$field" in
  Package) echo ocserv ;;
  Version) echo 1.5.0-1~bpo13+0local1 ;;
  Architecture) echo amd64 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "${FAKEBIN}/dpkg-deb"
}

install_fake_docker() {
  local mode="${1:-success}"
  cat > "${FAKEBIN}/docker" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${SMOKE_REPO}/docker-args"
case "${mode}" in
  fail) exit 17 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "${FAKEBIN}/docker"
}

run_smoke() {
  run bash -c "cd '${SMOKE_REPO}' && PATH='${FAKEBIN}:${PATH}' bash scripts/smoke-test.sh $*"
}

@test "smoke-basic requires exactly one target deb" {
  setup_smoke_repo
  install_fake_dpkg_deb
  install_fake_docker
  run_smoke
  [ "${status}" -ne 0 ]

  write_deb
  write_deb "ocserv_1.5.0-1~bpo13+0_amd64.deb"
  run_smoke
  teardown_smoke_repo
  [ "${status}" -ne 0 ]
}

@test "smoke-basic validates local deb metadata and passes expected values to container" {
  setup_smoke_repo
  write_deb
  install_fake_dpkg_deb
  install_fake_docker
  run_smoke
  args="$(cat "${SMOKE_REPO}/docker-args")"
  teardown_smoke_repo
  [ "${status}" -eq 0 ]
  [[ "${args}" == *"ocserv_1.5.0-1~bpo13+0local1_amd64.deb"* ]]
  [[ "${args}" == *"1.5.0-1~bpo13+0local1"* ]]
  [[ "${args}" == *"amd64"* ]]
}

@test "smoke-basic propagates docker failure" {
  setup_smoke_repo
  write_deb
  install_fake_dpkg_deb
  install_fake_docker fail
  run_smoke
  teardown_smoke_repo
  [ "${status}" -eq 17 ]
}

@test "smoke-test rejects non-basic modes" {
  setup_smoke_repo
  write_deb
  install_fake_dpkg_deb
  install_fake_docker
  run_smoke service
  teardown_smoke_repo
  [ "${status}" -ne 0 ]
}
