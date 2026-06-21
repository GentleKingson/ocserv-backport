load helpers/bats-helper.bash
POLICY="${REPO_ROOT}/docker/runner/ci-build-egress.policy"
LIB="${REPO_ROOT}/docker/runner/ci-build-egress.policy.lib"

@test "policy: two IPv4 managed chains + ipv6=disabled" {
  grep -q 'OCSERV_CI_EGRESS' "${POLICY}"
  grep -q 'OCSERV_CI_HOST_GUARD' "${POLICY}"
  grep -q 'ipv6 = disabled' "${POLICY}"
}

@test "policy: denies RFC1918/link-local/metadata/CGNAT; allows only public 443/80; no GitHub IP allowlist" {
  grep -q '10.0.0.0/8' "${POLICY}"
  grep -q '169.254.0.0/16' "${POLICY}"
  grep -q '100.64.0.0/10' "${POLICY}"
  grep -q '0.0.0.0/8' "${POLICY}"
  grep -q 'dport=443' "${POLICY}"
  grep -q 'dport=80' "${POLICY}"
  ! grep -qi '140.82' "${POLICY}"
  ! grep -qi '185.199' "${POLICY}"
}

@test "egress_dest_allowed: private denied (rc=1); public 443 ok (rc=0); public 22 denied (rc=1)" {
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 10.20.0.5 443; printf 'rc=%s\n' \"\$?\""
  [ "$status" -eq 0 ]; [[ "$output" == *"rc=1"* ]]
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 1.2.3.4 443; printf 'rc=%s\n' \"\$?\""
  [ "$status" -eq 0 ]; [[ "$output" == *"rc=0"* ]]
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 1.2.3.4 22; printf 'rc=%s\n' \"\$?\""
  [ "$status" -eq 0 ]; [[ "$output" == *"rc=1"* ]]
}

@test "egress_dest_allowed: CGNAT (100.64/10) denied; loopback denied; 0.0.0.0/8 denied" {
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 100.64.0.1 443; printf 'rc=%s\n' \"\$?\""
  [ "$status" -eq 0 ]; [[ "$output" == *"rc=1"* ]]
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 127.0.0.1 443; printf 'rc=%s\n' \"\$?\""
  [ "$status" -eq 0 ]; [[ "$output" == *"rc=1"* ]]
  run bash -c "set +e; source '${LIB}'; egress_dest_allowed 0.0.0.1 443; printf 'rc=%s\n' \"\$?\""
  [ "$status" -eq 0 ]; [[ "$output" == *"rc=1"* ]]
}
