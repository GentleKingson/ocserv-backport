#!/usr/bin/env bats
load helpers/bats-helper.bash

setup_smoke_repo() {
  SMOKE_REPO="$(mktemp -d)"
  local target_arch="${TARGET_ARCH:-amd64}"
  mkdir -p "${SMOKE_REPO}/scripts" "${SMOKE_REPO}/build/debian/trixie/${target_arch}/binary"
  cp "${REPO_ROOT}/scripts/_common.sh" "${SMOKE_REPO}/scripts/_common.sh"
  [[ -f "${REPO_ROOT}/scripts/_target_arch.sh" ]] && cp "${REPO_ROOT}/scripts/_target_arch.sh" "${SMOKE_REPO}/scripts/_target_arch.sh"
  cp "${REPO_ROOT}/scripts/_target_paths.sh" "${SMOKE_REPO}/scripts/_target_paths.sh"
  [[ -f "${REPO_ROOT}/scripts/trixie-env.sh" ]] && cp "${REPO_ROOT}/scripts/trixie-env.sh" "${SMOKE_REPO}/scripts/trixie-env.sh"
  cp "${REPO_ROOT}/scripts/trixie-smoke-test.sh" "${SMOKE_REPO}/scripts/trixie-smoke-test.sh"
  FAKEBIN="$(mktemp -d)"
  cat > "${FAKEBIN}/dpkg" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --print-architecture) printf '%s\n' "${FAKE_DPKG_ARCH:-amd64}" ;;
  *) exit 99 ;;
esac
SH
  cat > "${FAKEBIN}/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m) printf '%s\n' "${FAKE_UNAME_M:-x86_64}" ;;
  *) exit 99 ;;
esac
SH
  chmod +x "${FAKEBIN}/dpkg" "${FAKEBIN}/uname"
}

teardown_smoke_repo() {
  [[ -n "${SMOKE_REPO:-}" ]] && rm -rf "${SMOKE_REPO}"
  [[ -n "${FAKEBIN:-}" ]] && rm -rf "${FAKEBIN}"
  SMOKE_REPO=""
  FAKEBIN=""
}

write_deb() {
  local target_arch="${TARGET_ARCH:-amd64}"
  local path="${SMOKE_REPO}/build/debian/trixie/${target_arch}/binary/${1:-ocserv_1.5.0-1~debian13.1_${target_arch}.deb}"
  printf 'fake deb\n' > "${path}"
}

install_fake_dpkg_deb() {
  cat > "${FAKEBIN}/dpkg-deb" <<'SH'
#!/usr/bin/env bash
field="$3"
case "$field" in
  Package) echo ocserv ;;
  Version) echo 1.5.0-1~debian13.1 ;;
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

install_fake_sudo_docker() {
  cat > "${FAKEBIN}/sudo" <<SH
#!/usr/bin/env bash
printf 'sudo %s\n' "\$*" > "${SMOKE_REPO}/sudo-calls"
exit 0
SH
  cat > "${FAKEBIN}/docker" <<'SH'
#!/usr/bin/env bash
echo "unexpected direct docker command: $*" >&2
exit 99
SH
  chmod +x "${FAKEBIN}/sudo" "${FAKEBIN}/docker"
}

run_smoke() {
  run bash -c "cd '${SMOKE_REPO}' && FAKE_DPKG_ARCH='${FAKE_DPKG_ARCH:-}' TARGET_ARCH='${TARGET_ARCH:-}' PATH='${FAKEBIN}:${PATH}' bash scripts/trixie-smoke-test.sh $*"
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

@test "smoke-basic honors TRIXIE_DOCKER_CMD override" {
  setup_smoke_repo
  write_deb
  install_fake_dpkg_deb
  install_fake_sudo_docker
  run bash -c "cd '${SMOKE_REPO}' && TRIXIE_DOCKER_CMD='sudo docker' PATH='${FAKEBIN}:${PATH}' bash scripts/trixie-smoke-test.sh"
  sudo_calls="$(cat "${SMOKE_REPO}/sudo-calls")"
  teardown_smoke_repo
  [ "${status}" -eq 0 ]
  [[ "${sudo_calls}" == *"sudo docker run --rm"* ]]
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
  [[ "${args}" == *"ocserv_1.5.0-1~debian13.1_amd64.deb"* ]]
  [[ "${args}" == *"1.5.0-1~debian13.1"* ]]
  [[ "${args}" == *"amd64"* ]]
}

@test "smoke-basic supports arm64 target deb while ignoring architecture independent debs" {
  TARGET_ARCH=arm64 setup_smoke_repo
  TARGET_ARCH=arm64 write_deb
  printf 'fake all deb\n' > "${SMOKE_REPO}/build/debian/trixie/arm64/binary/ocserv-data_1.5.0-1~debian13.1_all.deb"
  install_fake_docker
  cat > "${FAKEBIN}/dpkg-deb" <<'SH'
#!/usr/bin/env bash
field="$3"
case "$field" in
  Package) echo ocserv ;;
  Version) echo 1.5.0-1~debian13.1 ;;
  Architecture) echo arm64 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "${FAKEBIN}/dpkg-deb"

  FAKE_DPKG_ARCH=arm64 TARGET_ARCH=arm64 run_smoke
  args="$(cat "${SMOKE_REPO}/docker-args")"
  teardown_smoke_repo

  [ "${status}" -eq 0 ]
  [[ "${args}" == *"ocserv_1.5.0-1~debian13.1_arm64.deb"* ]]
  [[ "${args}" == *"arm64"* ]]
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
