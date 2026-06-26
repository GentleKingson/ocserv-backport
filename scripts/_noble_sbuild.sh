#!/usr/bin/env bash

run_noble_sbuild() {
  local log_file status

  log_file="$(mktemp)"

  if sbuild "$@" >"${log_file}" 2>&1; then
    rm -f -- "${log_file}"
    return 0
  else
    status=$?
  fi

  cat "${log_file}" >&2 || true
  rm -f -- "${log_file}"
  return "${status}"
}
