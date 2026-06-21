#!/usr/bin/env bats
load helpers/bats-helper.bash

@test ".env.example has valid FETCH_SOURCE and no DEBIAN_SNAPSHOT_TIMESTAMP" {
  [[ -f "${REPO_ROOT}/.env.example" ]]
  grep -qE '^FETCH_SOURCE=(pool|cache)' "${REPO_ROOT}/.env.example"
  ! grep -q 'DEBIAN_SNAPSHOT_TIMESTAMP' "${REPO_ROOT}/.env.example"
}

@test "runbook never instructs 'FETCH_SOURCE=cache make dry-run' as a runnable command (contradicts .env precedence)" {
  # fetch-source.sh sources repo-root .env, which OVERWRITES a pre-exported
  # FETCH_SOURCE. So a shell prefix like 'FETCH_SOURCE=cache make dry-run' would
  # NOT take effect when .env still says pool. The runbook must instead instruct
  # editing .env. This guards against a RUNNABLE command example (a line whose
  # command token starts with 'FETCH_SOURCE=cache make') returning — it must NOT
  # appear inside a ```bash runnable block. Explanatory prose mentioning the
  # anti-pattern is allowed (and present, to teach operators why it's wrong).
  rb="${REPO_ROOT}/docs/trixie-builder-dryrun-runbook.md"
  [[ -f "$rb" ]] || skip "runbook absent"
  # Match only lines that look like a runnable command: leading optional whitespace,
  # then 'FETCH_SOURCE=cache' immediately followed by spaces then 'make'. Exclude
  # lines inside a `>` blockquote (explanatory prose) by also requiring the line
  # NOT start with '>'.
  bad="$(grep -nE '^[[:space:]]*FETCH_SOURCE=cache[[:space:]]+make' "$rb" | grep -vE '^[0-9]+:>' || true)"
  [[ -z "$bad" ]] || { echo "runbook shows runnable 'FETCH_SOURCE=cache make' (contradicts .env precedence):"; echo "$bad"; false; }
}
