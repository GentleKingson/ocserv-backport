#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §2.4. dget from snapshot.debian.org fixed timestamp; chroot never sees sid.
UPSTREAM="${OCSERV_UPSTREAM_VERSION:-1.5.0}"
REVISION="${OCSERV_DEBIAN_REVISION:-1}"
SRC_VER="${UPSTREAM}-${REVISION}"

# Load timestamp: .env first, then environment.
if [[ -f .env ]]; then set -a; source .env; set +a; fi
TS="${DEBIAN_SNAPSHOT_TIMESTAMP:?DEBIAN_SNAPSHOT_TIMESTAMP must be set (.env or env)}"
BASE="https://snapshot.debian.org/archive/debian/${TS}"
DSC_URL="${BASE}/pool/main/o/ocserv/ocserv_${SRC_VER}.dsc"

mkdir -p build/source
cd build/source
log "dget ${DSC_URL}"
dget -x -u "${DSC_URL}"   # -u: do not verify with GnuPG at fetch (we trust archive)
log "source tree ready: $(pwd)/ocserv-${UPSTREAM}"
