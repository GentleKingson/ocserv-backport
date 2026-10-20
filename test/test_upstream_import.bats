#!/usr/bin/env bats
load helpers/bats-helper.bash

# Fixtures: an upstream tarball signed by a throwaway key, a packaging tree
# whose debian/upstream/signing-key.asc holds that key, and a lock pinning both.
setup_import() {
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/release" "${WORK}/packaging/debian/upstream" "${WORK}/staging" "${WORK}/bin"
  export GNUPGHOME="${WORK}/gnupg"
  mkdir -m 700 "${GNUPGHOME}"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Upstream <up@example.invalid>' ed25519 sign never
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Other <other@example.invalid>' ed25519 sign never
  SIGNER="$(gpg --with-colons --fingerprint up@example.invalid | awk -F: '$1 == "fpr" { print $10; exit }')"
  OTHER="$(gpg --with-colons --fingerprint other@example.invalid | awk -F: '$1 == "fpr" { print $10; exit }')"

  mkdir -p "${WORK}/src/ocserv-9.9.9"
  printf "project('ocserv')\n" > "${WORK}/src/ocserv-9.9.9/meson.build"
  tar -C "${WORK}/src" -cJf "${WORK}/release/ocserv-9.9.9.tar.xz" ocserv-9.9.9
  gpg --batch --quiet --local-user "${SIGNER}" --detach-sign \
    --output "${WORK}/release/ocserv-9.9.9.tar.xz.sig" "${WORK}/release/ocserv-9.9.9.tar.xz"
  gpg --batch --armor --export "${SIGNER}" "${OTHER}" > "${WORK}/packaging/debian/upstream/signing-key.asc"
  write_lock "${SIGNER}"

  # curl serves files from release/; the packaging tools are stubbed.
  cat > "${WORK}/bin/curl" <<'SH'
#!/usr/bin/env bash
dest=""; prev=""; url=""
for arg in "$@"; do [[ "${prev}" == "--output" ]] && dest="${arg}"; prev="${arg}"; url="${arg}"; done
cp -- "${RELEASE_DIR}/${url##*/}" "${dest}"
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "${WORK}/bin/dpkg-source"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "${WORK}/dch-args"\n' > "${WORK}/bin/dch"
  printf '#!/usr/bin/env bash\necho 1.5.0-1\n' > "${WORK}/bin/dpkg-parsechangelog"
  chmod +x "${WORK}/bin/"*
}

write_lock() {
  local fpr="$1" tsha ssha
  tsha="$(sha256sum "${WORK}/release/ocserv-9.9.9.tar.xz" | awk '{print $1}')"
  ssha="$(sha256sum "${WORK}/release/ocserv-9.9.9.tar.xz.sig" | awk '{print $1}')"
  printf 'UPSTREAM\tocserv\t9.9.9\t%s\nTARBALL\tocserv-9.9.9.tar.xz\t%s\t%s\nSIGNATURE\tocserv-9.9.9.tar.xz.sig\t%s\t%s\n' \
    "${fpr}" "$(wc -c < "${WORK}/release/ocserv-9.9.9.tar.xz")" "${tsha}" \
    "$(wc -c < "${WORK}/release/ocserv-9.9.9.tar.xz.sig")" "${ssha}" > "${WORK}/lock.tsv"
}

run_import() {
  run env PATH="${WORK}/bin:${PATH}" RELEASE_DIR="${WORK}/release" WORK="${WORK}" bash -c '
    set -euo pipefail
    . scripts/_common.sh; . scripts/_fetch.sh; . scripts/_upstream_import.sh
    import_upstream_release "$1/packaging" "$1/staging" "$1/lock.tsv" ocserv 9.9.9 9.9.9-0local1
  ' bash "${WORK}"
}

teardown() {
  [[ -n "${WORK:-}" ]] && rm -rf -- "${WORK}"
  return 0
}

@test "upstream import verifies the pinned signer and assembles the source tree" {
  setup_import
  run_import
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"signed by ${SIGNER}"* ]]
  [ -f "${WORK}/staging/ocserv-9.9.9/meson.build" ]
  [ -f "${WORK}/staging/ocserv-9.9.9/debian/upstream/signing-key.asc" ]
  cmp "${WORK}/release/ocserv-9.9.9.tar.xz" "${WORK}/staging/ocserv_9.9.9.orig.tar.xz"
  grep -qx -- 9.9.9-0local1 "${WORK}/dch-args"
}

@test "upstream import rejects a tarball that does not match the lock" {
  setup_import
  printf 'x' >> "${WORK}/release/ocserv-9.9.9.tar.xz"
  run_import
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"rejecting ocserv-9.9.9.tar.xz"* ]]
  [ ! -e "${WORK}/staging/ocserv-9.9.9" ]
}

@test "upstream import rejects a bad signature even when the lock matches" {
  setup_import
  printf 'x' >> "${WORK}/release/ocserv-9.9.9.tar.xz"
  write_lock "${SIGNER}"
  run_import
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"upstream signature verification failed"* ]]
  [ ! -e "${WORK}/staging/ocserv-9.9.9" ]
}

@test "upstream import rejects a valid signature when the lock pins another key" {
  setup_import
  write_lock "${OTHER}"
  run_import
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not from pinned key ${OTHER}"* ]]
  [ ! -e "${WORK}/staging/ocserv-9.9.9" ]
}

@test "committed upstream lock matches the packaged upstream version" {
  run bash -c '
    set -euo pipefail
    unset OCSERV_DEBIAN_VERSION
    . scripts/_common.sh; . scripts/_versions.sh; . scripts/_upstream_import.sh
    read_upstream_lock "source-lock/ocserv/upstream-${OCSERV_UPSTREAM_VERSION}.tsv" ocserv "${OCSERV_UPSTREAM_VERSION}"
    printf "%s\n" "${UPSTREAM_SIGNER_FPR}" "${UPSTREAM_TARBALL_NAME}"
  '
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "1F42418905D8206AA754CCDC29EE58B996865171" ]
  [ "${lines[1]}" = "ocserv-1.6.0.tar.xz" ]
}
