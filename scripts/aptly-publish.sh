#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"
source "$(dirname "$0")/_manifest.sh"

# Spec §3.7 / §3.8. Usage: aptly-publish.sh <testing|production> <snapshot> [version]
channel="$1"; snapshot="$2"; version="${3:-}"
require_channel "${channel}"

# Map channel -> aptly distribution
case "${channel}" in
  testing)    dist=trixie-testing ;;
  production) dist=trixie-production ;;
esac

acquire_repo_publish_lock

# Detect first-publish vs subsequent-switch. Spec §3.8.
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

# Version for manifest: prefer explicit, else read from snapshot if resolvable.
if [[ -z "${version}" ]]; then
  version="$(aptly snapshot show -json "${snapshot}" 2>/dev/null \
    | jq -r '.Packages[]? | select(.Name=="ocserv") | .Version' | head -n1 || true)"
fi
[[ -n "${version}" ]] || die "could not determine ocserv version for manifest (pass as \$3)"
manifest_update "${channel}" "${snapshot}" "${version}"
log "published ${channel} -> ${snapshot} (version ${version})"
