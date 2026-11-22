#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SUITE=resolute exec "${SCRIPT_DIR}/ubuntu-auto-build.sh" "$@"
