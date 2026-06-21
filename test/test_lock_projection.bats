#!/usr/bin/env bats
load helpers/bats-helper.bash

@test "every committed .lock.tsv matches its YAML projection (no drift)" {
  [[ -d "${REPO_ROOT}/source-lock" ]] || skip "no source-lock dir"
  while IFS= read -r -d '' yaml; do
    tsv="${yaml%.yaml}.lock.tsv"
    [[ -f "$tsv" ]] || { echo "MISSING projection: $tsv"; false; }
    run python3 "${REPO_ROOT}/scripts/read-source-lock.py" --lock "$yaml"
    [ "$status" -eq 0 ] || { echo "parser failed on $yaml"; false; }
    echo "$output" | cmp -s - "$tsv" || { echo "DRIFT: $yaml vs $tsv"; false; }
  done < <(find "${REPO_ROOT}/source-lock" -type f -name '*.yaml' -print0)
}

@test "no orphan .lock.tsv (every tsv has a matching yaml)" {
  [[ -d "${REPO_ROOT}/source-lock" ]] || skip "no source-lock dir"
  while IFS= read -r -d '' tsv; do
    [[ -f "${tsv%.lock.tsv}.yaml" ]] || { echo "ORPHAN: $tsv"; false; }
  done < <(find "${REPO_ROOT}/source-lock" -type f -name '*.lock.tsv' -print0)
}
