#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"
source "$(dirname "$0")/_manifest.sh"

# Spec §3.7 / §3.8 / §4.2 (publish-testing step). Usage:
#   aptly-publish.sh <testing|production> <snapshot> [version]
channel="$1"; snapshot="$2"; version="${3:-}"
require_channel "${channel}"

case "${channel}" in
  testing)    dist=trixie-testing ;;
  production) dist=trixie-production ;;
esac

acquire_repo_publish_lock

# 1. Add freshly built deb(s) to the pool, then cut an immutable snapshot.
#    (Spec §4.2 step 3: flock + repo add + snapshot create.)
shopt -s nullglob
debs=( build/binary/*.deb )
[[ "${#debs[@]}" -gt 0 ]] || die "no deb in build/binary/ (run 'make binary' first)"
log "aptly repo add ocserv-backports ${debs[*]}"
aptly repo add ocserv-backports "${debs[@]}"
log "aptly snapshot create ${snapshot} from repo ocserv-backports"
aptly snapshot create "${snapshot}" from repo ocserv-backports

# 2. Publish: first-publish uses 'publish snapshot'; subsequent updates use 'publish switch'.
if aptly publish list -raw 2>/dev/null | grep -Fx "${dist}" >/dev/null; then
  log "channel ${dist} exists -> publish switch"
  aptly publish switch "${dist}" "${snapshot}"
else
  log "channel ${dist} absent -> publish snapshot (first publish)"
  aptly publish snapshot \
    -origin=THEHKUS-Backports \
    -distribution="${dist}" \
    -component=main \
    "${snapshot}"
fi

# 3. Version for manifest: prefer explicit arg, else resolve from the snapshot.
if [[ -z "${version}" ]]; then
  version="$(aptly snapshot show -json "${snapshot}" 2>/dev/null \
    | jq -r '.Packages[]? | select(.Name=="ocserv") | .Version' | head -n1 || true)"
fi
[[ -n "${version}" ]] || die "could not determine ocserv version for manifest (pass as \$3)"
manifest_update "${channel}" "${snapshot}" "${version}"
log "published ${channel} -> ${snapshot} (version ${version})"
