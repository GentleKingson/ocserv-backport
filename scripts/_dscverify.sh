#!/usr/bin/env bash
# Shared dscverify wrapper. Source after _common.sh.
set -euo pipefail

DSCVERIFY_DEFAULT_KEYRINGS=(
  /usr/share/keyrings/debian-keyring.gpg
  /usr/share/keyrings/debian-maintainers.gpg
  /usr/share/keyrings/debian-nonupload.gpg
  /usr/share/keyrings/debian-tag2upload.pgp
)

dscverify_candidate_keyrings() {
  if [[ -n "${DSCVERIFY_KEYRING_PATHS:-}" ]]; then
    local IFS=':'
    local -a configured_keyrings=()
    read -r -a configured_keyrings <<< "${DSCVERIFY_KEYRING_PATHS}"
    printf '%s\n' "${configured_keyrings[@]}"
    return 0
  fi

  printf '%s\n' "${DSCVERIFY_DEFAULT_KEYRINGS[@]}"
}

dscverify_with_temp_gnupghome() {
  local gpg_home status

  gpg_home="$(mktemp -d)"
  chmod 700 "${gpg_home}"
  if GNUPGHOME="${gpg_home}" "$@"; then
    rm -rf -- "${gpg_home}"
    return 0
  else
    status=$?
  fi

  rm -rf -- "${gpg_home}"
  return "${status}"
}

dscverify_keyring_contains_key() {
  local keyring="$1"
  local key="$2"

  dscverify_with_temp_gnupghome \
    gpg --batch --no-default-keyring --keyring "${keyring}" --list-keys "${key}" \
    >/dev/null 2>&1
}

dscverify_cmd() {
  local dsc="$1"
  local -a args=(dscverify --no-conf --no-default-keyrings)
  local keyring readable_count=0

  while IFS= read -r keyring; do
    [[ -n "${keyring}" ]] || continue
    if [[ -r "${keyring}" ]]; then
      args+=(--keyring "${keyring}")
      readable_count=$((readable_count + 1))
    fi
  done < <(dscverify_candidate_keyrings)

  if [[ "${readable_count}" -eq 0 ]]; then
    echo "no readable Debian dscverify keyrings found." >&2
    echo "Install them with: sudo apt install -y --no-install-recommends debian-keyring" >&2
    return 1
  fi

  args+=("${dsc}")
  dscverify_with_temp_gnupghome "${args[@]}"
}
