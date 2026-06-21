# IPv4-only Plan Consistency Design

## Purpose

Update only `docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md` so its IPv6 policy is internally consistent.

Phase 1's managed runner path does not use or support IPv6. Host-level IPv6 configuration and IPv6 used by unrelated Docker workloads are outside this plan's security boundary. Phase 1 runner networking is IPv4-only, and all routed runner traffic is governed by the IPv4 Docker network and IPv4 managed firewall chains.

## Scope

The implementation-plan update will:

- state consistently that Phase 1's managed runner path does not use or support IPv6;
- retain `EnableIPv6=false` validation for `ci-build-egress`;
- require exactly one `IPAM.Config` entry whose `Subnet` and `Gateway` equal the expected IPv4 values;
- retain runtime validation that the runner has no global IPv6 address and no IPv6 default route;
- retain the decision not to create or maintain project-managed `ip6tables` chains;
- remove requirements to inspect, reject, or constrain host-global Docker daemon IPv6 configuration;
- remove stale `fixed-cidr-v6`, `daemon-IPv4-only`, and “reject global daemon IPv6” wording;
- keep `iproute2` in the runner image because runtime checks for global IPv6 addresses and IPv6 default routes require it.

No source code, tests, parent specification, runbook, or other plan files will be changed in this update.

## Security Boundary

The security boundary is per network and per runner container, not host-global:

1. `ci-build-egress` must report `EnableIPv6=false`.
2. It must have exactly one `IPAM.Config` entry, and that entry's `Subnet` and `Gateway` must equal the expected IPv4 values.
3. The runner must have neither a global IPv6 address nor an IPv6 default route at runtime.
4. IPv4 egress remains controlled by `OCSERV_CI_EGRESS` and `OCSERV_CI_HOST_GUARD`.

A host may have IPv6 enabled for unrelated workloads, and Docker may manage host IPv6 firewall state for those workloads. That does not violate this plan as long as the dedicated runner network and runner container satisfy the checks above. No project-managed IPv6 equivalents of `OCSERV_CI_EGRESS` or `OCSERV_CI_HOST_GUARD` are created or maintained.

## Plan Sections to Update

The plan revision will update all stale or contradictory wording in:

- the revision summary and architecture overview;
- Phase 1 scope and final IPv6 policy;
- the file-structure responsibilities;
- Task 6 and Task 7 headings, descriptions, code comments, and checkpoints;
- the embedded runbook example;
- the final acceptance checklist.

The resulting text will use one consistent formulation: “IPv4-only; IPv6 is unsupported as a routed runner traffic path. The runner has no global IPv6 address and no IPv6 default route. Per-network and runtime checks are authoritative; no host-global Docker daemon IPv6 requirement applies.”

## Verification

After editing the plan:

1. Search the plan for `fixed-cidr-v6`, `daemon-IPv4-only`, `daemon IPv4-only`, and `reject global daemon IPv6`; all matches must be removed.
2. Run `rg -n -i '(host|daemon).*(ipv6|fixed-cidr-v6)|(ipv6|fixed-cidr-v6).*(host|daemon)' docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md`. Any match must only state that host-global IPv6 is outside the plan's security boundary; no match may require, reject, or disable host-global daemon IPv6.
3. Confirm the plan still contains `EnableIPv6=false`, exactly one `IPAM.Config` entry with the expected IPv4 `Subnet` and `Gateway`, runtime global-address/default-route absence checks, and the no-project-managed-`ip6tables` policy.
4. Review the surrounding sections to ensure headings, examples, checkpoints, and acceptance criteria express the same policy without treating loopback or link-local IPv6 presence as a failure.
5. Run `git diff --check`.

Because this change updates documentation requirements only, no product test suite or implementation change is required at this stage.
