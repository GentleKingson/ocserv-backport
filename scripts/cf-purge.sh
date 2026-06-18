#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_common.sh"

# Spec §3.5. Purge /dists/* after publish. Idempotent.
channel="$1"; require_channel "${channel}"
: "${CF_API_TOKEN:?CF_API_TOKEN required}"
: "${CF_ZONE_ID:?CF_ZONE_ID required}"

base="${APT_BASE_URL:-https://apt.example.com}"
curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/purge_cache" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{\"prefixes\":[\"${base#https://}/${channel}/dists/\"]}" \
  | jq .
log "purged ${channel}/dists/*"
