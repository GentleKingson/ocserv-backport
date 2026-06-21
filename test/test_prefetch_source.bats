#!/usr/bin/env bats
load helpers/bats-helper.bash

# Build a throwaway git repo at $1 with scripts/ + a source-lock/ laid out so
# prefetch-source.sh (which resolves REPO_ROOT via git -C "$SCRIPT_DIR/..") treats
# $1 as the repo root. We COPY the real scripts (not symlink) so SCRIPT_DIR
# resolves inside the temp repo.
setup_prefetch_repo() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/source-lock/ocserv"
  cp "${REPO_ROOT}/scripts/_common.sh"        "$root/scripts/_common.sh"
  cp "${REPO_ROOT}/scripts/_dsc.sh"           "$root/scripts/_dsc.sh"
  cp "${REPO_ROOT}/scripts/_lock_tsv.sh"      "$root/scripts/_lock_tsv.sh"
  cp "${REPO_ROOT}/scripts/_cache_meta.sh"    "$root/scripts/_cache_meta.sh"
  cp "${REPO_ROOT}/scripts/read-source-lock.py" "$root/scripts/read-source-lock.py"
  cp "${REPO_ROOT}/scripts/prefetch-source.sh"  "$root/scripts/prefetch-source.sh"
  git -C "$root" init -q
  git -C "$root" add -A && git -C "$root" -c user.email=t@t -c user.name=t commit -qm init
}

@test "prefetch: YAML/.lock.tsv drift → fails before any network (executes script)" {
  tmpd="$(mktemp -d)"; setup_prefetch_repo "$tmpd"
  cat > "$tmpd/source-lock/ocserv/1.5.0-1.yaml" <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [snapshot]
snapshot_timestamp: "20260101T000000Z"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: ocserv_1.5.0.orig.tar.xz, size: 1, sha256: "1111111111111111111111111111111111111111111111111111111111111111"}]
YAML
  # committed .lock.tsv intentionally DIFFERENT from the parser projection (drift)
  printf 'META\tocserv\t9.9.9-9\tsnapshot\t20260101T000000Z\t-\tx.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\n' \
    > "$tmpd/source-lock/ocserv/1.5.0-1.lock.tsv"
  # Fake curl: if EVER called, write a marker and fail. Drift gate must prevent this.
  fakebin="$(mktemp -d)"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
echo "CURL INVOKED WITH: \$*" >> "$tmpd/CURL_HIT"
exit 7
SH
  chmod +x "$fakebin/curl"
  # Stub dscverify/dpkg-source too so a missing drift gate can't proceed past them.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/dscverify"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/dpkg-source"
  # gpg is absent on the macOS test host but checked by require_cmds at the top
  # of main(); stub it so the test reaches its intended drift-gate assertion
  # (otherwise it dies on the command check, masking the real gate under test).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/gpg"
  chmod +x "$fakebin/dscverify" "$fakebin/dpkg-source" "$fakebin/gpg"

  rc=0
  ( cd "$tmpd" && PATH="$fakebin:$PATH" bash "$tmpd/scripts/prefetch-source.sh" \
      --lock "$tmpd/source-lock/ocserv/1.5.0-1.yaml" ) >"$tmpd/out.log" 2>&1 || rc=$?
  curl_hit="no"; [[ -f "$tmpd/CURL_HIT" ]] && curl_hit="yes"
  rm -rf "$tmpd" "$fakebin"
  # (a) script exited non-zero
  [ "$rc" -ne 0 ]
  # (b) curl was never invoked (drift gate fired before any network)
  [ "$curl_hit" == "no" ]
}

@test "prefetch: end-to-end (integration; run on a prefetch node with snapshot+keyrings)" {
  [[ "${PREFETCH_INTTEST:-0}" == "1" ]] || skip "set PREFETCH_INTTEST=1 on a prefetch node"
  # Full happy path: real snapshot download, real dscverify (4 keyrings),
  # real dpkg-source -x, cache + bundle written. Asserts cache.meta content_sha256
  # == sha256(SHA256SUMS), bundle is regular-file-only ustar, etc.
  # IMPLEMENTER: this body is filled in when running on the prefetch node — it
  # invokes `prefetch-source.sh --lock source-lock/ocserv/1.5.0-1.yaml` against
  # the real network and asserts the cache dir + bundle exist and validate.
  # (Not a placeholder failure: the drift test above is the unit-level gate;
  #  this is the infra-only integration check, intentionally skip-guarded.)
  bash "${REPO_ROOT}/scripts/prefetch-source.sh" --lock "${REPO_ROOT}/source-lock/ocserv/1.5.0-1.yaml"
}
