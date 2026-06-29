#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  ARCH_REPO="$(mktemp -d)"
  FAKEBIN="$(mktemp -d)"
  mkdir -p "${ARCH_REPO}/scripts"
  cp "${REPO_ROOT}/scripts/_target_arch.sh" "${ARCH_REPO}/scripts/_target_arch.sh"
}

teardown() {
  [[ -n "${ARCH_REPO:-}" ]] && rm -rf "${ARCH_REPO}"
  [[ -n "${FAKEBIN:-}" ]] && rm -rf "${FAKEBIN}"
}

install_fake_arch_tools() {
  ln -s /bin/bash "${FAKEBIN}/bash"
  cat > "${FAKEBIN}/dpkg" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --print-architecture)
    if [[ "${FAKE_DPKG_STATUS:-0}" != "0" ]]; then
      exit "${FAKE_DPKG_STATUS}"
    fi
    printf '%s\n' "${FAKE_DPKG_ARCH:-amd64}"
    ;;
  *)
    exit 99
    ;;
esac
SH
  cat > "${FAKEBIN}/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -m)
    if [[ "${FAKE_UNAME_STATUS:-0}" != "0" ]]; then
      exit "${FAKE_UNAME_STATUS}"
    fi
    printf '%s\n' "${FAKE_UNAME_M:-x86_64}"
    ;;
  *)
    exit 99
    ;;
esac
SH
  chmod +x "${FAKEBIN}/dpkg" "${FAKEBIN}/uname"
}

run_arch_script() {
  run env "PATH=${FAKEBIN}" "$@" /bin/bash -c '
    cd "$1" || exit
    shift
    . scripts/_target_arch.sh
    resolve_target_arch
    require_supported_target_arch
    printf "%s\t%s\t%s\n" \
      "${TARGET_ARCH}" "${HOST_ARCH}" "${TARGET_ARCH_WAS_EXPLICIT}"
  ' _ "${ARCH_REPO}"
}

@test "_target_arch detects native amd64 from dpkg" {
  install_fake_arch_tools

  run_arch_script FAKE_DPKG_ARCH=amd64

  [ "${status}" -eq 0 ]
  [ "${output}" = $'amd64\tamd64\t0' ]
}

@test "_target_arch detects native arm64 from dpkg" {
  install_fake_arch_tools

  run_arch_script FAKE_DPKG_ARCH=arm64

  [ "${status}" -eq 0 ]
  [ "${output}" = $'arm64\tarm64\t0' ]
}

@test "_target_arch falls back to uname aliases" {
  install_fake_arch_tools

  run_arch_script FAKE_DPKG_STATUS=1 FAKE_UNAME_M=aarch64
  [ "${status}" -eq 0 ]
  [ "${output}" = $'arm64\tarm64\t0' ]

  run_arch_script FAKE_DPKG_STATUS=1 FAKE_UNAME_M=x86_64
  [ "${status}" -eq 0 ]
  [ "${output}" = $'amd64\tamd64\t0' ]
}

@test "_target_arch normalizes explicit architecture aliases" {
  install_fake_arch_tools

  run_arch_script FAKE_DPKG_ARCH=amd64 TARGET_ARCH=x86_64
  [ "${status}" -eq 0 ]
  [ "${output}" = $'amd64\tamd64\t1' ]

  run_arch_script FAKE_DPKG_ARCH=arm64 TARGET_ARCH=aarch64
  [ "${status}" -eq 0 ]
  [ "${output}" = $'arm64\tarm64\t1' ]
}

@test "_target_arch rejects unsupported explicit architectures" {
  install_fake_arch_tools

  for arch in i386 armhf riscv64 unknown; do
    run_arch_script FAKE_DPKG_ARCH=amd64 TARGET_ARCH="${arch}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unsupported TARGET_ARCH: ${arch}"* ]]
    [[ "${output}" == *"Supported architectures: amd64, arm64"* ]]
  done
}

@test "_target_arch treats empty TARGET_ARCH like unset" {
  install_fake_arch_tools

  run_arch_script FAKE_DPKG_ARCH=arm64 TARGET_ARCH=

  [ "${status}" -eq 0 ]
  [ "${output}" = $'arm64\tarm64\t0' ]
}

@test "_target_arch rejects non-native targets unless explicitly overridden" {
  install_fake_arch_tools

  run env "PATH=${FAKEBIN}" FAKE_DPKG_ARCH=amd64 TARGET_ARCH=arm64 /bin/bash -c '
    cd "$1" || exit
    . scripts/_target_arch.sh
    resolve_target_arch
    require_native_target_arch_or_explicit_override
  ' _ "${ARCH_REPO}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"TARGET_ARCH=arm64 differs from native architecture amd64"* ]]
  [[ "${output}" == *"ALLOW_NON_NATIVE_TARGET_ARCH=1"* ]]

  run env "PATH=${FAKEBIN}" FAKE_DPKG_ARCH=amd64 TARGET_ARCH=arm64 \
    ALLOW_NON_NATIVE_TARGET_ARCH=1 /bin/bash -c '
    cd "$1" || exit
    . scripts/_target_arch.sh
    resolve_target_arch
    require_native_target_arch_or_explicit_override
    printf "%s/%s/%s\n" \
      "${TARGET_ARCH}" "${HOST_ARCH}" "${TARGET_ARCH_WAS_EXPLICIT}"
  ' _ "${ARCH_REPO}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ALLOW_NON_NATIVE_TARGET_ARCH=1 only bypasses"* ]]
  [[ "${output}" == *"This path is unsupported by this project."* ]]
  [[ "${output}" == *"arm64/amd64/1"* ]]
}
