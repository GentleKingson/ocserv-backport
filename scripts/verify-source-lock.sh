#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
LOCK_ROOT="${REPO_ROOT}/source-lock"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-lock.XXXXXX")"

cleanup() {
  rm -rf -- "${TMP_ROOT}"
}
trap cleanup EXIT

die() {
  echo "verify-lock: ERROR: $*" >&2
  exit 1
}

[[ -d "${LOCK_ROOT}" ]] || die "source-lock directory missing"

found_yaml=0
while IFS= read -r -d '' yaml; do
  found_yaml=1
  tsv="${yaml%.yaml}.lock.tsv"
  [[ -f "${tsv}" ]] || die "missing lock.tsv for ${yaml}"

  generated="${TMP_ROOT}/$(basename "${yaml%.yaml}").lock.tsv"
  if ! python3 "${SCRIPT_DIR}/read-source-lock.py" --lock "${yaml}" > "${generated}"; then
    die "parser failed for ${yaml}"
  fi

  if ! cmp -s "${generated}" "${tsv}"; then
    echo "verify-lock: ERROR: lock.tsv drift: ${yaml} -> ${tsv}" >&2
    diff -u "${generated}" "${tsv}" || true
    exit 1
  fi
done < <(find "${LOCK_ROOT}" -type f -name '*.yaml' -print0)

[[ "${found_yaml}" -eq 1 ]] || die "no YAML locks found under source-lock"

while IFS= read -r -d '' tsv; do
  [[ -f "${tsv%.lock.tsv}.yaml" ]] || die "orphan lock.tsv: ${tsv}"
done < <(find "${LOCK_ROOT}" -type f -name '*.lock.tsv' -print0)

echo "verify-lock: source locks verified"
