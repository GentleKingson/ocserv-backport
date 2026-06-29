#!/usr/bin/env bash
# Shared target architecture helpers. Source this from distro env scripts.

_target_arch_fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

_target_arch_print_supported() {
  printf 'Supported architectures: amd64, arm64\n' >&2
}

normalize_target_arch() {
  case "$1" in
    amd64|x86_64)
      printf '%s\n' "amd64"
      ;;
    arm64|aarch64)
      printf '%s\n' "arm64"
      ;;
    *)
      return 1
      ;;
  esac
}

detect_native_arch() {
  local raw_arch=""

  if command -v dpkg >/dev/null 2>&1; then
    raw_arch="$(dpkg --print-architecture 2>/dev/null || true)"
  fi

  if [[ -z "${raw_arch}" ]] && command -v uname >/dev/null 2>&1; then
    raw_arch="$(uname -m 2>/dev/null || true)"
  fi

  [[ -n "${raw_arch}" ]] || return 1
  normalize_target_arch "${raw_arch}"
}

resolve_target_arch() {
  local requested_arch="${TARGET_ARCH:-}"
  local resolved_arch=""

  if [[ -n "${TARGET_ARCH+x}" && -n "${TARGET_ARCH}" ]]; then
    TARGET_ARCH_WAS_EXPLICIT=1
  else
    TARGET_ARCH_WAS_EXPLICIT=0
  fi

  HOST_ARCH="$(detect_native_arch || true)"
  export HOST_ARCH

  if [[ "${TARGET_ARCH_WAS_EXPLICIT}" == 1 ]]; then
    if ! resolved_arch="$(normalize_target_arch "${requested_arch}")"; then
      printf 'Unsupported TARGET_ARCH: %s\n' "${requested_arch}" >&2
      _target_arch_print_supported
      exit 1
    fi
  else
    if [[ -z "${HOST_ARCH}" ]]; then
      printf 'Unable to detect supported native architecture\n' >&2
      _target_arch_print_supported
      exit 1
    fi
    resolved_arch="${HOST_ARCH}"
  fi

  TARGET_ARCH="${resolved_arch}"
  export TARGET_ARCH TARGET_ARCH_WAS_EXPLICIT
}

require_supported_target_arch() {
  local resolved_arch=""

  if ! resolved_arch="$(normalize_target_arch "${TARGET_ARCH:-}")"; then
    printf 'Unsupported TARGET_ARCH: %s\n' "${TARGET_ARCH:-}" >&2
    _target_arch_print_supported
    exit 1
  fi

  TARGET_ARCH="${resolved_arch}"
  export TARGET_ARCH
}

require_native_target_arch_or_explicit_override() {
  if [[ -z "${HOST_ARCH:-}" || -z "${TARGET_ARCH:-}" ]]; then
    _target_arch_fail "TARGET_ARCH and HOST_ARCH must be resolved before native architecture checks"
  fi

  if [[ "${TARGET_ARCH}" == "${HOST_ARCH}" ]]; then
    return 0
  fi

  if [[ "${ALLOW_NON_NATIVE_TARGET_ARCH:-}" == 1 ]]; then
    printf 'WARNING: TARGET_ARCH=%s differs from native architecture %s.\n' \
      "${TARGET_ARCH}" "${HOST_ARCH}" >&2
    printf 'ALLOW_NON_NATIVE_TARGET_ARCH=1 only bypasses the native-architecture guard.\n' >&2
    printf 'It does not configure cross-build, QEMU, binfmt, or foreign-arch chroots.\n' >&2
    printf 'This path is unsupported by this project.\n' >&2
    return 0
  fi

  printf 'TARGET_ARCH=%s differs from native architecture %s.\n' \
    "${TARGET_ARCH}" "${HOST_ARCH}" >&2
  printf 'This project defaults to native amd64/arm64 builds only.\n' >&2
  printf 'Set ALLOW_NON_NATIVE_TARGET_ARCH=1 to bypass this guard for manually prepared unsupported environments.\n' >&2
  printf 'ALLOW_NON_NATIVE_TARGET_ARCH=1 does not configure cross-build, QEMU, binfmt, or foreign-arch chroots.\n' >&2
  exit 1
}
