load helpers/bats-helper.bash
PROVISIONER="${REPO_ROOT}/scripts/runner-provisioner.sh"
DIG64="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NAME26="0123456789ABCDEFGHJKMNPQRS"

@test "provisioner is self-contained (sources without _common.sh)" {
  run bash -c "set +e; cd /tmp; source '${PROVISIONER}'; echo sourced-ok"
  echo "$output" | grep -q sourced-ok
}

@test "load_provisioner_config: clears inherited RUNNER_* env; only config provides values" {
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<EOF
RUNNER_URL=https://github.com/GentleKingson/ocserv-backport
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  # Pre-set a BOGUS inherited value; load must clear it (not inherit).
  run bash -c "set +e; source '${PROVISIONER}'; RUNNER_MEMORY=bogus-inherited; load_provisioner_config '${tmpcfg}'; echo \"MEM=[\${RUNNER_MEMORY}]\""
  echo "$output" | grep -q 'MEM=\[6g\]'
  rm -f "$tmpcfg"
}

@test "load_provisioner_config: rejects unknown RUNNER_* key" {
  tmpcfg="$(mktemp)"; printf 'RUNNER_URL=x\nRUNNER_EVIL=injected\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: rejects duplicate key" {
  tmpcfg="$(mktemp)"; printf 'RUNNER_URL=x\nRUNNER_URL=y\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: one-key-per-line; rejects whitespace in value" {
  tmpcfg="$(mktemp)"; printf 'RUNNER_CPUS=2 RUNNER_MEMORY=6g\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: dies on missing file / missing required key" {
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config /nope.conf; echo rc=\$?"
  [ "$status" -ne 0 ]
  tmpcfg="$(mktemp)"; printf 'RUNNER_URL=x\n' >"$tmpcfg"
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]; rm -f "$tmpcfg"
}

@test "load_provisioner_config: enforces fixed URL/LABEL/NETWORK values" {
  tmpcfg="$(mktemp)"
  cat >"$tmpcfg" <<EOF
RUNNER_URL=https://evil.example.com
RUNNER_LABEL=ci-build
RUNNER_IMAGE=ghcr.io/owner/img@sha256:${DIG64}
RUNNER_NETWORK=ci-build-egress
RUNNER_CPUS=2
RUNNER_MEMORY=6g
RUNNER_PIDS_LIMIT=512
RUNNER_TMPFS_WORK_SIZE=16g
RUNNER_TMPFS_RUNNER_SIZE=1g
RUNNER_TMPFS_TMP_SIZE=1g
RUNNER_WAIT_TIMEOUT=45m
EOF
  run bash -c "set +e; source '${PROVISIONER}'; load_provisioner_config '${tmpcfg}'; echo rc=\$?"
  [ "$status" -ne 0 ]   # URL not the fixed repo URL -> rejected
  rm -f "$tmpcfg"
}

@test "generate_runner_name: ci-build-<26 Crockford Base32 incl S/Z>; two differ" {
  run bash -c "set +e; source '${PROVISIONER}'; generate_runner_name"
  echo "$output" | grep -qE '^ci-build-[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$'
  run bash -c "set +e; source '${PROVISIONER}'; printf '%s\n%s\n' \"\$(generate_runner_name)\" \"\$(generate_runner_name)\""
  [ "$(sed -n 1p <<<"$output")" != "$(sed -n 2p <<<"$output")" ]
}

@test "valid_runner_name + parse_timeout_to_seconds bounds [5m,60m]" {
  run bash -c "set +e; source '${PROVISIONER}'; valid_runner_name ci-build-${NAME26} && echo ok"; echo "$output" | grep -q ok
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 45m"; [ "$output" = "2700" ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 1m; echo rc=\$?"; [ "$status" -ne 0 ]
  run bash -c "set +e; source '${PROVISIONER}'; parse_timeout_to_seconds 90m; echo rc=\$?"; [ "$status" -ne 0 ]
}

# ---- Task 2: parse_args ----

@test "parse_args: --registration-token-stdin / --dry-run" {
  run bash -c "set +e; source '${PROVISIONER}'; TOKEN_STDIN=0; parse_args --registration-token-stdin --dry-run; printf 'T=%s D=%s\n' \"\$TOKEN_STDIN\" \"\$BOOTSTRAP_DRY_RUN\""
  echo "$output" | grep -q 'T=1 D=1'
}

@test "parse_args: --runner-name DRY-RUN only; live FORBIDDEN" {
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=1; parse_args --runner-name ci-build-DRYTEST; printf 'N=%s\n' \"\$RUNNER_NAME\""
  echo "$output" | grep -q 'N=ci-build-DRYTEST'
  # live mode rejects ANY --runner-name, even valid-shape (CSPRNG-only in live)
  run bash -c "set +e; source '${PROVISIONER}'; BOOTSTRAP_DRY_RUN=0; parse_args --runner-name ci-build-${NAME26}; echo rc=\$?"
  [ "$status" -ne 0 ]
}

@test "parse_args: REJECTS all container-weakening flags" {
  for bad in --docker-arg --privileged --mount /x --cap-add SYS_ADMIN --pid host --ipc host --uts host --userns host --network host --image evil --label x --env SECRET --device /dev/sda -v /etc:/etc --volume /root:/root; do
    run bash -c "set +e; source '${PROVISIONER}'; parse_args '$bad'; echo rc=\$?"
    [ "$status" -ne 0 ] || { echo "FAIL: accepted $bad"; exit 1; }
  done
}

@test "parse_args: rejects unknown flag" {
  run bash -c "set +e; source '${PROVISIONER}'; parse_args --bogus; echo rc=\$?"
  [ "$status" -ne 0 ]
}
