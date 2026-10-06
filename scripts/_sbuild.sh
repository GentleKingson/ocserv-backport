#!/usr/bin/env bash
# sbuild wrapper that keeps the console quiet on success and, on failure,
# prints sbuild's output plus the tail of the newest build log.

sbuild_build_dir_from_args() {
  local arg previous=""

  for arg in "$@"; do
    if [[ "${previous}" == "--build-dir" ]]; then
      printf '%s\n' "${arg}"
      return 0
    fi

    case "${arg}" in
      --build-dir=*)
        printf '%s\n' "${arg#--build-dir=}"
        return 0
        ;;
    esac

    previous="${arg}"
  done
}

print_latest_sbuild_log_tail() {
  local build_dir="$1"
  local latest_log tail_lines log_path
  local -a logs

  [[ -n "${build_dir}" && -d "${build_dir}" ]] || return 0

  shopt -s nullglob
  logs=("${build_dir}"/*.build "${build_dir}"/*.buildlog "${build_dir}"/*.log)
  shopt -u nullglob
  [[ "${#logs[@]}" -gt 0 ]] || return 0

  latest_log="${logs[0]}"
  for log_path in "${logs[@]}"; do
    if [[ "${log_path}" -nt "${latest_log}" ]]; then
      latest_log="${log_path}"
    fi
  done

  tail_lines="${SBUILD_LOG_TAIL_LINES:-${NOBLE_SBUILD_LOG_TAIL_LINES:-260}}"
  printf '\nlatest sbuild build log: %s\n' "${latest_log}" >&2
  tail -n "${tail_lines}" "${latest_log}" >&2 || true
}

run_sbuild() {
  local build_dir log_file status

  log_file="$(mktemp)"
  build_dir="$(sbuild_build_dir_from_args "$@")"

  if sbuild "$@" >"${log_file}" 2>&1; then
    rm -f -- "${log_file}"
    return 0
  else
    status=$?
  fi

  cat "${log_file}" >&2 || true
  rm -f -- "${log_file}"
  print_latest_sbuild_log_tail "${build_dir}"
  return "${status}"
}
