#!/usr/bin/env bash
# Shared Debian Trixie backport defaults and path helpers. Source this file.
set -euo pipefail

reject_legacy_trixie_env() {
  local legacy_var

  for legacy_var in DEBIAN_DOCKER_CMD DEBIAN_NATIVE_ARCH OCSERV_SKIP_FETCH_VERIFY_LOCK; do
    if [[ "${!legacy_var+x}" == x ]]; then
      printf 'error: legacy environment variable %s is no longer supported; use the TRIXIE_* name instead\n' "${legacy_var}" >&2
      exit 2
    fi
  done

  while IFS= read -r legacy_var; do
    [[ -n "${legacy_var}" ]] || continue
    printf 'error: legacy environment variable %s is no longer supported; use TRIXIE_AUTO_BUILD_* instead\n' "${legacy_var}" >&2
    exit 2
  done < <(compgen -A variable DEBIAN_AUTO_BUILD_)
}

reject_legacy_trixie_env

TARGET_FAMILY="${TARGET_FAMILY:-debian}"
TARGET_SUITE="${TARGET_SUITE:-trixie}"
TRIXIE_ENV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/_target_arch.sh
. "${TRIXIE_ENV_DIR}/_target_arch.sh"

resolve_target_arch
require_supported_target_arch
require_native_target_arch_or_explicit_override

# shellcheck source=scripts/_target_paths.sh
. "${TRIXIE_ENV_DIR}/_target_paths.sh"

TARGET_DISTRIBUTION="${TARGET_SUITE}"
TRIXIE_NATIVE_ARCH="${HOST_ARCH}"

export TARGET_FAMILY TARGET_SUITE TARGET_DISTRIBUTION TARGET_ARCH
export HOST_ARCH TARGET_ARCH_WAS_EXPLICIT TRIXIE_NATIVE_ARCH
