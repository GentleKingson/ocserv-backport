# IPv4-only Plan Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Phase 1 ephemeral-runner plan consistently define IPv4-only as a managed runner-path constraint without imposing host-global Docker daemon IPv6 requirements.

**Architecture:** This is a documentation-only correction to the existing Phase 1 implementation plan. The updated plan keeps per-network `EnableIPv6=false`, exact single-entry IPv4 IPAM validation, and runtime checks for global IPv6 addresses and IPv6 default routes, while explicitly excluding host-global IPv6 and unrelated Docker workloads from scope.

**Tech Stack:** Markdown, ripgrep, Git.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md` | Authoritative Phase 1 plan; define runner-path IPv4-only consistently in overview, tasks, embedded examples, and acceptance criteria. | Modify |

No source code, tests, parent specification, runbook, or other plan files are changed.

### Task 1: Record the current semantic failures

**Files:**
- Inspect: `docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md`

- [ ] **Step 1: Run the stale-wording scan**

```bash
rg -n -i 'fixed-cidr-v6|daemon-IPv4-only|daemon IPv4-only|reject global daemon IPv6|reject daemon global IPv6|IPv6-absence|runtime verifies IPv6 is absent|no IPv6 IPAM' \
  docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md
```

Expected: output identifies stale or overly broad wording; this is the expected failing baseline.

- [ ] **Step 2: Run the host/daemon semantic scan**

```bash
rg -n -i '(host|daemon).*(ipv6|fixed-cidr-v6)|(ipv6|fixed-cidr-v6).*(host|daemon)' \
  docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md
```

Expected: at least one result still requires or rejects host-global Docker daemon IPv6 configuration.

### Task 2: Correct the plan overview and scope

**Files:**
- Modify: `docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md:1-39`

- [ ] **Step 1: Increment the revision and add the scope correction**

Set the title and insert the v1.7 paragraph before the existing v1.6 history:

```markdown
# Phase 1 — Ephemeral Runner Foundation Implementation Plan (v1.7)

> **v1.7 revision (runner-path IPv4-only boundary):** Phase 1's managed runner path does not use or support IPv6. The authoritative checks are scoped to `ci-build-egress` and the runner container: `EnableIPv6=false`; exactly one `IPAM.Config` entry whose `Subnet` and `Gateway` equal the expected IPv4 values; no global IPv6 address; and no IPv6 default route. Host-level IPv6 configuration and IPv6 used by unrelated Docker workloads are outside this plan's security boundary. No project-managed IPv6 equivalents of `OCSERV_CI_EGRESS` or `OCSERV_CI_HOST_GUARD` are created or maintained.
>
```

- [ ] **Step 2: Narrow the v1.6 history wording**

Replace v1.6 numbered item (1) with this text; keep items (2)-(6) unchanged:

```markdown
(1) IPv4-only IPAM check fixed — uses real `.Subnet`/`.Gateway` IPAM fields (Docker has no reliable `.IPv6Subnet`); removed the false host-global Docker IPv6 prerequisite (security boundary is the `ci-build-egress` network and runner container: `EnableIPv6=false` + exactly one expected IPv4 IPAM entry + no global IPv6 address/default route);
```

- [ ] **Step 3: Replace broad overview terminology**

Use these exact paragraphs:

```markdown
**Tech Stack:** Bash (self-contained provisioner + entrypoint + host-install), Docker (iptables backend verified), Debian trixie (digest-pinned base), GitHub Actions runner (tarball `ADD --checksum=`, `libicu76`), `util-linux` (findmnt), `iproute2` (global IPv6 address/default-route checks), `curl` (integration test), bats, shellcheck, iptables managed chains (IPv4 only).

**Phase 1 scope (hard boundary):** provisioner (self-contained, flock, orphan preflight `ps -aq`, CSPRNG name, strict audit sink, image preflight, timeout, root-owned config + env-clear + parent-path verify, label-verified cleanup, audit events) + non-root ephemeral image (digest base, checksum payload, libicu76, python3-yaml, util-linux, iproute2, curl, no runtime pip) + `--ephemeral`/`--rm`/`-i` + read-only rootfs + tmpfs + no socket + no privileged + cap-drop=ALL + no-new-privileges + no bind mount + resource limits + **IPv4-only Docker network + runner-path routed-IPv6 exclusion checks + real persistent IPv4 managed-chain firewall (egress + host-guard + hard-fail persist)** + migrate `lock-projection` (image-baked, trusted-event, contents:read, no secrets) + automated acceptance + lifecycle audit.

**IPv6 policy (final):** Phase 1's managed runner path does NOT use or support IPv6 as a routed traffic path. `ci-build-egress` must report `EnableIPv6=false` and exactly one `IPAM.Config` entry whose `Subnet` and `Gateway` equal the expected IPv4 values. At runtime, the runner must have no global IPv6 address and no IPv6 default route; loopback or link-local IPv6 presence alone is not a failure. Host-level IPv6 configuration and IPv6 used by unrelated Docker workloads are outside this plan's security boundary. **No project-managed `ip6tables` chains are created or maintained.**
```

Replace the final IPv6 exclusion phrase with:

```markdown
**IPv6 support on the managed runner path / project-managed IPv6 firewall chains**.
```

- [ ] **Step 4: Correct the file table**

Use these row descriptions:

```markdown
| `scripts/runner-host-install.sh` | One-time install from audited root clone: verify netfilter-persistent installed+enabled + Docker iptables backend FIRST; install provisioner + verify source files + parent owner/mode/kind; create+verify **IPv4-only** bridge (`EnableIPv6=false`; exactly one expected IPv4 `IPAM.Config` entry); build two **IPv4** managed chains; save+verify ruleset (rollback on failure); jump dedup with comment. Host-global Docker IPv6 is out of scope. | New |
| `docs/runner-ephemeral.md` | Runbook: audited-clone install, IPv4-only runner network, firewall integration, runtime checks for no global IPv6 address/default route, sudo -n token, audit, offline cleanup. | New |
```

### Task 3: Correct Tasks 6-7 and embedded examples

**Files:**
- Modify: `docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md:854-1213`

- [ ] **Step 1: Correct Task 6 boundary wording**

Use:

```markdown
IPv4-only. No project-managed `ip6tables` chains. Routed IPv6 is excluded by `EnableIPv6=false`, exact single-entry IPv4 IPAM validation, and runtime checks for no global IPv6 address/default route in Tasks 7-8.
```

In the policy example use:

```text
# IPv4-ONLY managed runner path (`EnableIPv6=false`; exactly one expected IPv4
# IPAM entry; runtime has no global IPv6 addr / no IPv6 default route).
# No project-managed ip6tables chains are created or maintained.
```

Replace the acceptance boundary with:

```markdown
> **Acceptance boundary:** pure tests verify policy logic only. Network isolation is accepted ONLY by the runner-host IPv4 integration test plus the runtime checks for no global IPv6 address/default route. Pure tests do NOT claim isolation.
```

- [ ] **Step 2: Correct the Task 7 title and heading**

```markdown
## Task 7: Host install (verify-first; libexec create-before-stat; IPv4-only bridge verify new+existing; IPv4 managed chains; save+verify+rollback; jump dedup) + Makefile + runbook

- [ ] **Step 1: `scripts/runner-host-install.sh`** (managed runner path is IPv4-only; no project-managed `ip6tables` chains; host-global Docker IPv6 is out of scope)
```

- [ ] **Step 3: Make IPAM validation mechanically precise**

Retain the existing `EnableIPv6=false` check and replace the IPAM block with:

```bash
  # IPAM: exactly one entry whose subnet+gateway equal the expected IPv4 values.
  local -a ipam_lines=()
  mapfile -t ipam_lines < <(docker network inspect ci-build-egress \
    -f '{{range .IPAM.Config}}{{printf "%s\t%s\n" .Subnet .Gateway}}{{end}}')
  [[ ${#ipam_lines[@]} -eq 1 ]] || die "ci-build-egress must have exactly one IPAM config (got ${#ipam_lines[@]})"
  [[ "${ipam_lines[0]}" == "${SUBNET}"$'\t'"${GW}" ]] \
    || die "ci-build-egress IPAM must be ${SUBNET} / ${GW} (got '${ipam_lines[0]}')"
```

Remove the colon-based IPv6-data check. Exact cardinality and exact IPv4 values already exclude a second IPv6 IPAM entry.

- [ ] **Step 4: Replace the security-boundary comments**

```bash
# Phase 1's security boundary is the ci-build-egress network and runner container,
# not host-global Docker IPv6 configuration. EnableIPv6=false + exactly one expected
# IPv4 IPAM entry + runtime checks for no global IPv6 address/default route are
# authoritative for the managed runner path. Unrelated host workloads are out of scope.
```

Keep the prerequisite comment limited to persistence and the Docker iptables backend.

- [ ] **Step 5: Correct the embedded runbook wording**

Use:

```markdown
- [ ] **Step 3: runbook (`docs/runner-ephemeral.md`) — IPv4 integration + routed-IPv6 exclusion checks**

bash scripts/runner-host-install.sh   # verify-first (persist+backend+runner-network IPv4-only); root-owned provisioner; IPv4 managed chains; hard-fail save+verify

## Firewall + routed-IPv6 exclusion integration acceptance (RUNNER HOST — ONLY network-isolation acceptance; IPv4-only runner path)
```

Keep the two existing `ip -6` commands and replace their comment with:

```bash
  # Routed-IPv6 exclusion: loopback/link-local presence is allowed; global address/default route are not.
```

- [ ] **Step 6: Correct the Task 7 commit and checkpoint text**

```markdown
- [ ] **Step 4: `shellcheck scripts/runner-host-install.sh` + commit** `feat(phase1): host install (IPv4-only runner network, IPv4 managed chains, verify-first, rollback)`.

**Checkpoint review (Task 6-7):** IPv4-only managed runner path (`EnableIPv6=false`; exactly one expected IPv4 IPAM entry; runtime has no global IPv6 address/default route), no host-global Docker IPv6 requirement, no project-managed `ip6tables` chains, IPv4 managed chains (egress+host-guard, jump dedup, save+verify exactly-1, rollback), root-owned install + source-file + parent-path verify, runbook.
```

### Task 4: Correct final lifecycle and acceptance wording

**Files:**
- Modify: `docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md:1368-1400`

- [ ] **Step 1: Correct the lifecycle prerequisite**

```markdown
> Real runner-host lifecycle drill (real short-lived token) ONLY after Steps 1-4 + runbook IPv4 integration + routed-IPv6 exclusion checks + image smoke pass. Runner must be repository-scoped (not org-level).
```

- [ ] **Step 2: Replace the Network acceptance block**

```text
Network (managed runner path is IPv4-only; pure=logic; isolation accepted ONLY via runbook integration):
  policy two IPv4 managed chains + ipv6=disabled; deny private/link-local/metadata; allow public 443/80; no GitHub IP allowlist; no project-managed ip6tables chains.
  installer: verify persistence+iptables backend FIRST; create libexec before stat; verify new+existing network (EnableIPv6=false; exactly one IPAM.Config entry with expected IPv4 Subnet/Gateway); host-global Docker IPv6 is out of scope.
  build IPv4 chains; dedup jumps (comment); save+verify (exactly 1 jump each); rollback on failure.
```

- [ ] **Step 3: Replace the IPv6 acceptance line**

```text
IPv6 on managed runner path: unsupported as routed traffic; EnableIPv6=false; exactly one expected IPv4 IPAM.Config entry; no global IPv6 addr; no IPv6 default route; loopback/link-local presence alone is allowed; no host-global Docker IPv6 requirement.
```

### Task 5: Verify and commit the target-plan update

**Files:**
- Verify: `docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md`

- [ ] **Step 1: Verify forbidden wording is gone**

```bash
if rg -n -i 'fixed-cidr-v6|daemon-IPv4-only|daemon IPv4-only|reject global daemon IPv6|reject daemon global IPv6|IPv6-absence|runtime verifies IPv6 is absent|no IPv6 IPAM' \
  docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md; then
  echo 'FAIL: stale IPv6 wording remains' >&2
  exit 1
fi
```

Expected: exit 0 with no matches.

- [ ] **Step 2: Review all host/daemon IPv6 mentions**

```bash
rg -n -i '(host|daemon).*(ipv6|fixed-cidr-v6)|(ipv6|fixed-cidr-v6).*(host|daemon)' \
  docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md
```

Expected: every match says host-global IPv6 is outside the boundary or no host-global requirement applies. No match requires, rejects, disables, or inspects host-global daemon IPv6.

- [ ] **Step 3: Verify required controls remain**

```bash
plan=docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md
grep -q 'EnableIPv6=false' "$plan"
grep -q 'exactly one `IPAM.Config` entry' "$plan"
grep -q 'no global IPv6 address' "$plan"
grep -q 'no IPv6 default route' "$plan"
grep -q 'No project-managed `ip6tables` chains' "$plan"
grep -q 'loopback or link-local IPv6 presence alone is not a failure' "$plan"
```

Expected: exit 0.

- [ ] **Step 4: Verify formatting and scope**

```bash
git diff --check
git diff --name-only
```

Expected output from `git diff --name-only`:

```text
docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md
```

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md
git commit -m "docs(phase1): scope IPv4-only policy to runner path"
```
