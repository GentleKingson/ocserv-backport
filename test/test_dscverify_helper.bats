#!/usr/bin/env bats
load helpers/bats-helper.bash

setup() {
  cd "${REPO_ROOT}"
  TMP_ROOT="$(mktemp -d)"
  FAKEBIN="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP_ROOT}" "${FAKEBIN}"
}

install_fake_dscverify() {
  cat > "${FAKEBIN}/dscverify" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" > "${TMP_ROOT}/dscverify-args"
printf '%s\n' "\${GNUPGHOME:-}" > "${TMP_ROOT}/dscverify-gnupghome"
if [[ -n "\${DSCVERIFY_FAKE_STATUS:-}" ]]; then
  exit "\${DSCVERIFY_FAKE_STATUS}"
fi
SH
  chmod +x "${FAKEBIN}/dscverify"
}

call_dscverify_helper() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/_common.sh'; source '${REPO_ROOT}/scripts/_dscverify.sh'; $*"
}

@test "dscverify_cmd passes only readable keyrings to dscverify" {
  install_fake_dscverify
  keyring_one="${TMP_ROOT}/debian-keyring.gpg"
  keyring_two="${TMP_ROOT}/debian-maintainers.gpg"
  missing_keyring="${TMP_ROOT}/missing-tag2upload.pgp"
  dsc="${TMP_ROOT}/source.dsc"
  touch "${keyring_one}" "${keyring_two}" "${dsc}"

  call_dscverify_helper "PATH='${FAKEBIN}':\"\$PATH\" DSCVERIFY_KEYRING_PATHS='${keyring_one}:${missing_keyring}:${keyring_two}' dscverify_cmd '${dsc}'; cat '${TMP_ROOT}/dscverify-args'"

  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "--no-conf" ]
  [ "${lines[1]}" = "--no-default-keyrings" ]
  [ "${lines[2]}" = "--keyring" ]
  [ "${lines[3]}" = "${keyring_one}" ]
  [ "${lines[4]}" = "--keyring" ]
  [ "${lines[5]}" = "${keyring_two}" ]
  [ "${lines[6]}" = "${dsc}" ]
  [ "${#lines[@]}" -eq 7 ]
  gpg_home="$(cat "${TMP_ROOT}/dscverify-gnupghome")"
  [ -n "${gpg_home}" ]
  [ ! -d "${gpg_home}" ]
}

@test "dscverify_cmd fails early with install hint when no keyrings are readable" {
  install_fake_dscverify
  dsc="${TMP_ROOT}/source.dsc"
  touch "${dsc}"

  call_dscverify_helper "PATH='${FAKEBIN}':\"\$PATH\" DSCVERIFY_KEYRING_PATHS='${TMP_ROOT}/missing-one:${TMP_ROOT}/missing-two' dscverify_cmd '${dsc}'"

  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no readable Debian dscverify keyrings"* ]]
  [[ "${output}" == *"sudo apt install -y --no-install-recommends debian-keyring"* ]]
  [ ! -e "${TMP_ROOT}/dscverify-args" ]
}

@test "dscverify_cmd propagates dscverify failures" {
  install_fake_dscverify
  keyring="${TMP_ROOT}/debian-keyring.gpg"
  dsc="${TMP_ROOT}/source.dsc"
  touch "${keyring}" "${dsc}"

  call_dscverify_helper "export DSCVERIFY_FAKE_STATUS=8; PATH='${FAKEBIN}':\"\$PATH\" DSCVERIFY_KEYRING_PATHS='${keyring}' dscverify_cmd '${dsc}'"

  [ "${status}" -eq 8 ]
  gpg_home="$(cat "${TMP_ROOT}/dscverify-gnupghome")"
  [ -n "${gpg_home}" ]
  [ ! -d "${gpg_home}" ]
}

@test "dscverify_cmd allows DSCVERIFY_KEYRING_PATHS to override default candidates" {
  install_fake_dscverify
  custom_keyring="${TMP_ROOT}/custom-keyring.gpg"
  dsc="${TMP_ROOT}/source.dsc"
  touch "${custom_keyring}" "${dsc}"

  call_dscverify_helper "PATH='${FAKEBIN}':\"\$PATH\" DSCVERIFY_KEYRING_PATHS='${custom_keyring}' dscverify_cmd '${dsc}'; cat '${TMP_ROOT}/dscverify-args'"

  [ "${status}" -eq 0 ]
  [ "${lines[2]}" = "--keyring" ]
  [ "${lines[3]}" = "${custom_keyring}" ]
  [ "${lines[4]}" = "${dsc}" ]
  [ "${#lines[@]}" -eq 5 ]
}
