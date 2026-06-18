#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §6.3–§6.5. Runs locally, touches NO real state.
# Prereqs (builder host): sbuild, schroot trixie-amd64-sbuild, dget (devscripts), jq, docker.

fail() { log "DRY-RUN FAILED at: $*"; exit 1; }

log "== 1. fetch ==";        make fetch   || fail fetch
log "== 2. rewrap ==";       make rewrap  || fail rewrap
log "== 3. src-pkg ==";      make src-pkg || fail src-pkg
log "== 4. binary ==";       make binary  || fail binary
log "== 5. lint ==";         make lint    || fail lint
log "== 6. smoke-basic ==";  make smoke-basic || fail smoke-basic

log "== 7. aptly add+snapshot in TEMP DB (no real /var/aptly) =="
TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT
APTLY_ROOT_DIR="${TMPROOT}" aptly repo create ocserv-backports-dryrun >/dev/null
APTLY_ROOT_DIR="${TMPROOT}" aptly repo add ocserv-backports-dryrun build/binary/*.deb >/dev/null
SNAP="$(scripts/snapshot-name.sh)-dryrun"
APTLY_ROOT_DIR="${TMPROOT}" aptly snapshot create "${SNAP}" from repo ocserv-backports-dryrun >/dev/null
APTLY_ROOT_DIR="${TMPROOT}" aptly snapshot show "${SNAP}" | grep -q ocserv || fail "snapshot missing ocserv"
log "temp snapshot OK (in ${TMPROOT})"

log "== 8. snapshot-name consistency =="
OUT="$(scripts/snapshot-name.sh)"
[[ "${OUT}" =~ ^ocserv-1\.5\.0-1~bpo13\+1-build-(gh[0-9]+|local-[0-9]{8}T[0-9]{6})$ ]] \
  || fail "snapshot-name shape: ${OUT}"
log "snapshot-name OK: ${OUT}"

log "DRY-RUN PASSED — no real aptly/R2/staging/prod touched."
