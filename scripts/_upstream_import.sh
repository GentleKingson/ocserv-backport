#!/usr/bin/env bash
# Import a signed upstream ocserv release under the debian/ packaging of an
# older, dscverify-checked Debian source, for upstream versions Debian has not
# packaged yet. Source after _common.sh and _fetch.sh.
#
# The tarball and its detached signature are pinned by size and sha256 in
# source-lock/<source>/upstream-<version>.tsv; the signature must verify
# against debian/upstream/signing-key.asc of the verified packaging and be
# made by the primary key fingerprint pinned in the same file.
set -euo pipefail

UPSTREAM_RELEASE_URL="${UPSTREAM_RELEASE_URL:-https://www.infradead.org/ocserv/download}"

# read_upstream_lock <file> <source> <version> — set UPSTREAM_SIGNER_FPR and
# UPSTREAM_{TARBALL,SIGNATURE}_{NAME,SIZE,SHA256}.
read_upstream_lock() {
  local file="$1" source="$2" version="$3"
  local rectype f1 f2 f3 rest lineno=0
  [[ -f "${file}" ]] || die "upstream lock not found: ${file}"
  UPSTREAM_SIGNER_FPR=""
  UPSTREAM_TARBALL_NAME=""
  UPSTREAM_SIGNATURE_NAME=""
  while IFS=$'\t' read -r rectype f1 f2 f3 rest || [[ -n "${rectype}" ]]; do
    lineno=$((lineno + 1))
    [[ -z "${rest:-}" ]] || die "upstream lock line ${lineno}: extra fields"
    case "${lineno}:${rectype}" in
      1:UPSTREAM)
        [[ "${f1}" == "${source}" && "${f2}" == "${version}" ]] \
          || die "upstream lock is for ${f1} ${f2}, expected ${source} ${version}"
        [[ "${f3}" =~ ^[0-9A-F]{40}$ ]] || die "upstream lock signer must be a full fingerprint"
        UPSTREAM_SIGNER_FPR="${f3}"
        ;;
      2:TARBALL)
        [[ "${f1}" == "${source}-${version}.tar.xz" ]] || die "unexpected upstream tarball: ${f1}"
        [[ "${f2}" =~ ^[0-9]+$ && "${f3}" =~ ^[0-9a-f]{64}$ ]] || die "bad upstream tarball size/sha256"
        UPSTREAM_TARBALL_NAME="${f1}" UPSTREAM_TARBALL_SIZE="${f2}" UPSTREAM_TARBALL_SHA256="${f3}"
        ;;
      3:SIGNATURE)
        [[ "${f1}" == "${UPSTREAM_TARBALL_NAME}.sig" ]] || die "unexpected upstream signature: ${f1}"
        [[ "${f2}" =~ ^[0-9]+$ && "${f3}" =~ ^[0-9a-f]{64}$ ]] || die "bad upstream signature size/sha256"
        UPSTREAM_SIGNATURE_NAME="${f1}" UPSTREAM_SIGNATURE_SIZE="${f2}" UPSTREAM_SIGNATURE_SHA256="${f3}"
        ;;
      *) die "upstream lock line ${lineno}: unexpected record ${rectype}" ;;
    esac
  done < "${file}"
  [[ -n "${UPSTREAM_SIGNATURE_NAME}" ]] || die "upstream lock incomplete: ${file}"
}

download_upstream_file() {
  local name="$1" dest="$2" size="$3" sha="$4"
  local url="${UPSTREAM_RELEASE_URL%/}/${name}"
  curl --fail --show-error --location \
    --retry 3 --retry-connrefused --connect-timeout 30 \
    --output "${dest}" "${url}" || die "download failed for ${name}: ${url}"
  check_size_sha256 "${dest}" "${name}" "${size}" "${sha}" || die "rejecting ${name} from ${url}"
}

# verify_upstream_signature <signing-key.asc> <sig> <file> <workdir>
verify_upstream_signature() {
  local key_asc="$1" sig="$2" file="$3" workdir="$4"
  local keyring="${workdir}/upstream-signing-key.gpg" status
  [[ -f "${key_asc}" ]] || die "missing upstream signing key: ${key_asc}"
  mkdir -m 700 "${workdir}/gnupg"
  GNUPGHOME="${workdir}/gnupg" gpg --batch --quiet --dearmor --output "${keyring}" < "${key_asc}" \
    || die "cannot read upstream signing key: ${key_asc}"
  status="$(GNUPGHOME="${workdir}/gnupg" gpgv --status-fd 1 --keyring "${keyring}" "${sig}" "${file}" 2>/dev/null)" \
    || die "upstream signature verification failed for ${file##*/}"
  # VALIDSIG ends with the primary key fingerprint of the signing key.
  awk -v fpr="${UPSTREAM_SIGNER_FPR}" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }' \
    <<< "${status}" || die "upstream signature is not from pinned key ${UPSTREAM_SIGNER_FPR}"
  log "upstream signature OK: ${file##*/} signed by ${UPSTREAM_SIGNER_FPR}"
}

# import_upstream_release <packaging-tree> <staging> <lock> <source> <upstream-version> <debian-version>
# Create <staging>/<source>-<upstream-version> (patches applied, changelog at
# <debian-version>) and <staging>/<source>_<upstream-version>.orig.tar.xz.
import_upstream_release() {
  local packaging="$1" staging="$2" lock="$3" source="$4" version="$5" debian_version="$6"
  local work="${staging}/upstream" tree="${staging}/${source}-${version}"
  local packaging_version

  read_upstream_lock "${lock}" "${source}" "${version}"
  mkdir -p "${work}"
  download_upstream_file "${UPSTREAM_TARBALL_NAME}" "${work}/${UPSTREAM_TARBALL_NAME}" \
    "${UPSTREAM_TARBALL_SIZE}" "${UPSTREAM_TARBALL_SHA256}"
  download_upstream_file "${UPSTREAM_SIGNATURE_NAME}" "${work}/${UPSTREAM_SIGNATURE_NAME}" \
    "${UPSTREAM_SIGNATURE_SIZE}" "${UPSTREAM_SIGNATURE_SHA256}"
  verify_upstream_signature "${packaging}/debian/upstream/signing-key.asc" \
    "${work}/${UPSTREAM_SIGNATURE_NAME}" "${work}/${UPSTREAM_TARBALL_NAME}" "${work}"

  tar -xf "${work}/${UPSTREAM_TARBALL_NAME}" -C "${work}" || die "cannot unpack ${UPSTREAM_TARBALL_NAME}"
  [[ -f "${work}/${source}-${version}/meson.build" ]] || die "unexpected layout in ${UPSTREAM_TARBALL_NAME}"
  [[ ! -e "${tree}" ]] || die "import target already exists: ${tree}"
  mv -- "${work}/${source}-${version}" "${tree}"
  cp -a -- "${packaging}/debian" "${tree}/debian"
  cp -- "${work}/${UPSTREAM_TARBALL_NAME}" "${staging}/${source}_${version}.orig.tar.xz"

  packaging_version="$(cd "${tree}" && dpkg-parsechangelog -SVersion)"
  (
    cd "${tree}"
    # Applies debian/patches with fuzz 0; any patch that no longer fits fails.
    dpkg-source --before-build . || die "debian/patches from ${packaging_version} do not apply to ${source} ${version}"
    # A released distribution keeps the next dch from merging into this entry.
    DEBEMAIL="${MAINTAINER_EMAIL:-master@thehkus.com}" DEBFULLNAME="${MAINTAINER_NAME:-Thehkus Admin}" \
      dch --preserve --distribution unstable --force-distribution -v "${debian_version}" \
      "Local import of upstream ${source} ${version} (signed by ${UPSTREAM_SIGNER_FPR}), packaged with Debian ${packaging_version} debian/; not an official Debian upload."
  ) || die "upstream import failed for ${source} ${version}"
  log "imported upstream ${source} ${version} as ${debian_version}"
}
