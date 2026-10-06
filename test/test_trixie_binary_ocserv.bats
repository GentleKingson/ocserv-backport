#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}" || return
  BIN_REPO="$(mktemp -d)"
  FAKEBIN="$(mktemp -d)"
  mkdir -p "${BIN_REPO}/scripts"
  local file
  for file in _common.sh _target_arch.sh _target_paths.sh trixie-env.sh _sbuild.sh trixie-build-binary-ocserv.sh; do
    cp "${REPO_ROOT}/scripts/${file}" "${BIN_REPO}/scripts/${file}"
  done
  if [[ -f "${REPO_ROOT}/scripts/_versions.sh" ]]; then
    cp "${REPO_ROOT}/scripts/_versions.sh" "${BIN_REPO}/scripts/_versions.sh"
  fi
  mkdir -p "${BIN_REPO}/build/debian/trixie/amd64/source"
  : > "${BIN_REPO}/build/debian/trixie/amd64/source/ocserv_1.5.0-1~debian13.1.dsc"

  cat > "${FAKEBIN}/dpkg" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == --print-architecture ]] && { echo amd64; exit 0; }
exit 99
SH
  # Fake sbuild: chatty on stdout, writes a build log, and either produces
  # the expected artifacts or fails with FAKE_SBUILD_STATUS.
  cat > "${FAKEBIN}/sbuild" <<'SH'
#!/usr/bin/env bash
build_dir=""
prev=""
for arg in "$@"; do
  [[ "${prev}" == "--build-dir" ]] && build_dir="${arg}"
  prev="${arg}"
done
echo "Installing build dependencies"
printf 'compile line\nfatal: undefined reference to gnutls_init\n' \
  > "${build_dir}/ocserv_1.5.0-1~debian13.1_amd64.build"
if [[ "${FAKE_SBUILD_STATUS:-0}" != 0 ]]; then
  echo "E: Build failure (dpkg-buildpackage died)"
  exit "${FAKE_SBUILD_STATUS}"
fi
for ext in deb changes buildinfo; do
  : > "${build_dir}/ocserv_1.5.0-1~debian13.1_amd64.${ext}"
done
SH
  chmod +x "${FAKEBIN}/dpkg" "${FAKEBIN}/sbuild"
}

teardown() {
  rm -rf "${BIN_REPO}" "${FAKEBIN}"
}

run_binary() {
  run env "PATH=${FAKEBIN}:${PATH}" "$@" bash -c "cd '${BIN_REPO}' && bash scripts/trixie-build-binary-ocserv.sh"
}

@test "trixie-binary-ocserv hides sbuild output on success" {
  run_binary
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Installing build dependencies"* ]]
  [[ "${output}" == *"trixie binary built:"* ]]
}

@test "trixie-binary-ocserv prints sbuild output and build log tail on failure" {
  run_binary FAKE_SBUILD_STATUS=42 SBUILD_LOG_TAIL_LINES=1
  [ "${status}" -eq 42 ]
  [[ "${output}" == *"E: Build failure (dpkg-buildpackage died)"* ]]
  [[ "${output}" == *"latest sbuild build log:"*"ocserv_1.5.0-1~debian13.1_amd64.build"* ]]
  [[ "${output}" == *"fatal: undefined reference to gnutls_init"* ]]
  [[ "${output}" != *"compile line"* ]]
}
