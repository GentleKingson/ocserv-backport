#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/_common.sh"

# Spec §2.4. dget from snapshot.debian.org fixed timestamp; chroot never sees sid.
UPSTREAM="${OCSERV_UPSTREAM_VERSION:-1.5.0}"
REVISION="${OCSERV_DEBIAN_REVISION:-1}"
SRC_VER="${UPSTREAM}-${REVISION}"

fetch_via_snapshot() {
  # Load timestamp: .env first, then environment.
  if [[ -f .env ]]; then set -a; source .env; set +a; fi
  local ts="${DEBIAN_SNAPSHOT_TIMESTAMP:?DEBIAN_SNAPSHOT_TIMESTAMP must be set (.env or env)}"
  local base="https://snapshot.debian.org/archive/debian/${ts}"
  local dsc_url="${base}/pool/main/o/ocserv/ocserv_${SRC_VER}.dsc"
  log "dget ${dsc_url}"
  dget -x -u "${dsc_url}"   # -u: do not verify with GnuPG at fetch (we trust archive)
}

# Spec §3.3. Detect explicit HTTP 509 in dget's captured log text.
# Returns 0 (true) if any 509 marker matches; 1 otherwise.
# Arg 1: the log text (stdout+stderr) from dget.
is_509_failure() {
  local log_text="$1"
  # Match explicit 509 markers as they appear in real curl/wget output.
  # Do NOT match bare '22' (covers 404/403/500) or generic 'error'/'failed'.
  if printf '%s' "$log_text" | grep -qE 'curl: \(22\) The requested URL returned error: 509|HTTP Error 509|HTTP/1\.1 509|HTTP/2 509'; then
    return 0
  fi
  return 1
}

main() {
  mkdir -p build/source
  cd build/source
  fetch_via_snapshot
  log "source tree ready: $(pwd)/ocserv-${UPSTREAM}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
