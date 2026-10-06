#!/usr/bin/env bash
# Shared locked-source download and install helpers. Source after _common.sh
# and _lock_tsv.sh; read_lock_tsv must have filled META_* and ARTIFACT_*.
set -euo pipefail

# Space-separated Debian archive roots tried in order. Each root must serve
# pool/<pool_path>/<file>. Every download is checked against the locked size
# and sha256, so a fallback mirror cannot change what gets built. Example
# fallback for sources that have left the live pool:
#   DEBIAN_SOURCE_MIRRORS="https://deb.debian.org/debian https://snapshot.debian.org/archive/debian/20260616T083027Z"
DEBIAN_SOURCE_MIRRORS="${DEBIAN_SOURCE_MIRRORS:-https://deb.debian.org/debian}"

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

file_size() {
  wc -c < "$1" | tr -d ' '
}

# check_size_sha256 <file> <name> <size> <sha256> — print reason and fail on mismatch.
check_size_sha256() {
  local file="$1" name="$2" expected_size="$3" expected_sha="$4"
  local actual_size actual_sha
  actual_size="$(file_size "${file}")"
  [[ "${actual_size}" == "${expected_size}" ]] || {
    log "${name} size ${actual_size} != expected ${expected_size}"
    return 1
  }
  actual_sha="$(sha256_file "${file}")"
  [[ "${actual_sha}" == "${expected_sha}" ]] || {
    log "${name} sha256 mismatch"
    return 1
  }
}

# download_locked_file <name> <dest> <size> <sha256>
# Try each mirror in DEBIAN_SOURCE_MIRRORS until one serves a file matching
# the locked size and sha256.
download_locked_file() {
  local name="$1" dest="$2" expected_size="$3" expected_sha="$4"
  local -a mirrors=()
  local mirror url

  read -r -a mirrors <<< "${DEBIAN_SOURCE_MIRRORS}"
  [[ "${#mirrors[@]}" -gt 0 ]] || die "DEBIAN_SOURCE_MIRRORS must not be empty"

  for mirror in "${mirrors[@]}"; do
    url="${mirror%/}/pool/${META_POOL_PATH}/${name}"
    rm -f -- "${dest}"
    if ! curl --fail --show-error --location \
      --retry 3 --retry-connrefused --connect-timeout 30 \
      --output "${dest}" "${url}"; then
      log "download failed for ${name}: ${url}"
      continue
    fi
    if check_size_sha256 "${dest}" "${name}" "${expected_size}" "${expected_sha}"; then
      return 0
    fi
    log "rejecting ${name} from ${url}"
  done

  rm -f -- "${dest}"
  die "no mirror provided a valid ${name} (tried: ${DEBIAN_SOURCE_MIRRORS})"
}

install_source_tree() {
  local staging_tree="$1" target="$2"
  [[ -d "${staging_tree}" ]] || die "validated source tree missing: ${staging_tree}"
  find "${staging_tree}" -mindepth 1 -maxdepth 1 -print -quit | grep -q . \
    || die "validated source tree empty: ${staging_tree}"

  mkdir -p "$(dirname "${target}")"
  if [[ ! -e "${target}" ]]; then
    mv -- "${staging_tree}" "${target}"
    return 0
  fi

  local backup="${target}.old.$$"
  mv -- "${target}" "${backup}"
  if ! mv -- "${staging_tree}" "${target}"; then
    mv -- "${backup}" "${target}"
    die "source tree install failed; restored old tree"
  fi
  rm -rf -- "${backup}"
}
