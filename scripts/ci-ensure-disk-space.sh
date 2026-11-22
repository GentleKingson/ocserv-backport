#!/usr/bin/env bash
# Ensure at least <min_free_gib> GiB (default: 8) is free on / on a CI runner,
# cleaning heavy preinstalled payloads and Docker cache when below the threshold.
set -euo pipefail

min_free_gib="${1:-8}"
if ! [[ "${min_free_gib}" =~ ^[0-9]+$ ]] || ((min_free_gib < 1)); then
  echo "::error::Invalid minimum free disk size (GiB): ${min_free_gib}" >&2
  exit 2
fi
min_free_kb=$((min_free_gib * 1024 * 1024))

workspace="${GITHUB_WORKSPACE:-.}"

echo "== Disk before cleanup =="
df -h / "${workspace}" /tmp

avail_kb="$(df --output=avail / | tail -n1 | tr -d '[:space:]')"
if ! [[ "${avail_kb}" =~ ^[0-9]+$ ]]; then
  echo "::error::Unable to determine free disk space on /."
  exit 1
fi

if ((avail_kb < min_free_kb)); then
  echo "Free disk below ${min_free_gib} GiB; cleaning payloads."

  sudo rm -rf \
    /usr/share/dotnet \
    /usr/local/lib/android \
    /usr/local/share/boost \
    /usr/local/.ghcup \
    /opt/ghc \
    /opt/hostedtoolcache/CodeQL || true

  docker system prune -af || true
else
  echo "Free disk >= ${min_free_gib} GiB; skipping cleanup."
fi

echo "== Disk after cleanup check =="
df -h / "${workspace}" /tmp

avail_kb="$(df --output=avail / | tail -n1 | tr -d '[:space:]')"
if ! [[ "${avail_kb}" =~ ^[0-9]+$ ]]; then
  echo "::error::Unable to determine free disk after cleanup."
  exit 1
fi

if ((avail_kb < min_free_kb)); then
  echo "::error::Insufficient free disk; need ${min_free_gib} GiB."
  exit 1
fi
