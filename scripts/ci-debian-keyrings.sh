#!/usr/bin/env bash
# Download the current debian-archive-keyring and debian-keyring packages
# from Debian sid, unpack them under <workdir>, and print
#   DSCVERIFY_KEYRING_PATHS=<colon-separated keyring paths>
# on stdout for CI to append to $GITHUB_ENV. apt output goes to stderr.
# Requires /usr/share/keyrings/debian-archive-keyring.gpg to trust sid.
set -euo pipefail

workdir="${1:-$(mktemp -d)}"
mkdir -p "${workdir}/lists/partial" "${workdir}/sourceparts"

cat > "${workdir}/sid.sources" <<'SOURCES'
Types: deb
URIs: http://deb.debian.org/debian
Suites: sid
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES

apt_sid() {
  apt-get \
    -o "Dir::Etc::sourcelist=${workdir}/sid.sources" \
    -o "Dir::Etc::sourceparts=${workdir}/sourceparts" \
    -o "Dir::State::lists=${workdir}/lists" \
    -o "APT::Get::List-Cleanup=0" \
    "$@" >&2
}

apt_sid update
(
  cd "${workdir}"
  apt_sid download debian-archive-keyring debian-keyring
)

keyring_root="${workdir}/root"
mkdir -p "${keyring_root}"
for deb in "${workdir}"/*.deb; do
  dpkg-deb -x "${deb}" "${keyring_root}"
done

keyrings="$(
  find "${keyring_root}/usr/share/keyrings" \
    -maxdepth 1 \
    -type f \
    \( -name 'debian-*.gpg' -o -name 'debian-*.pgp' \) \
    -print \
    | sort \
    | paste -sd: -
)"

if [[ -z "${keyrings}" ]]; then
  echo "no Debian keyrings extracted from sid packages" >&2
  exit 1
fi

printf 'DSCVERIFY_KEYRING_PATHS=%s\n' "${keyrings}"
