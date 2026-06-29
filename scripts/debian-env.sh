#!/usr/bin/env bash
# Shared Debian Trixie backport defaults and path helpers. Source this file.
set -euo pipefail

TARGET_FAMILY="${TARGET_FAMILY:-debian}"
TARGET_SUITE="${TARGET_SUITE:-trixie}"
DEBIAN_ENV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/_target_arch.sh
. "${DEBIAN_ENV_DIR}/_target_arch.sh"

resolve_target_arch
require_supported_target_arch
require_native_target_arch_or_explicit_override

# shellcheck source=scripts/_target_paths.sh
. "${DEBIAN_ENV_DIR}/_target_paths.sh"

TARGET_DISTRIBUTION="${TARGET_SUITE}"
DEBIAN_NATIVE_ARCH="${HOST_ARCH}"

export TARGET_FAMILY TARGET_SUITE TARGET_DISTRIBUTION TARGET_ARCH
export HOST_ARCH TARGET_ARCH_WAS_EXPLICIT DEBIAN_NATIVE_ARCH
