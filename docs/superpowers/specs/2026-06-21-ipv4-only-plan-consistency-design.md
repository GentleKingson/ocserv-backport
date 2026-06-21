# IPv4-only Plan Consistency Design

## Purpose

Update only `docs/superpowers/plans/2026-06-21-phase1-ephemeral-runner-foundation.md` so its IPv6 policy is internally consistent.

The project does not use or support IPv6. Phase 1 networking is IPv4-only, and all runner traffic is governed by the IPv4 Docker network and IPv4 managed firewall chains.

## Scope

The implementation-plan update will:

- state consistently that Phase 1 does not use or support IPv6;
- retain `EnableIPv6=false` validation for `ci-build-egress`;
- retain validation that the network has exactly one IPv4 IPAM entry and no IPv6 IPAM data;
- retain runtime validation that the runner has no global IPv6 address and no IPv6 default route;
- retain the decision not to create or maintain `ip6tables` managed chains;
- remove requirements to inspect, reject, or constrain host-global Docker daemon IPv6 configuration;
- remove stale `fixed-cidr-v6`, `daemon-IPv4-only`, and “reject global daemon IPv6” wording;
- keep `iproute2` in the runner image because runtime IPv6-absence checks require it.

No source code, tests, parent specification, runbook, or other plan files will be changed in this update.

## Security Boundary

The security boundary is per network and per runner container, not host-global:

1. `ci-build-egress` must report `EnableIPv6=false`.
2. Its IPAM configuration must contain only the expected IPv4 subnet and gateway.
3. The runner must have neither a global IPv6 address nor an IPv6 default route at runtime.
4. IPv4 egress remains controlled by `OCSERV_CI_EGRESS` and `OCSERV_CI_HOST_GUARD`.

A host may have IPv6 enabled for unrelated workloads. That does not violate this plan as long as the dedicated runner network and runner container satisfy the checks above.

## Plan Sections to Update

The plan revision will update all stale or contradictory wording in:

- the revision summary and architecture overview;
- Phase 1 scope and final IPv6 policy;
- the file-structure responsibilities;
- Task 6 and Task 7 headings, descriptions, code comments, and checkpoints;
- the embedded runbook example;
- the final acceptance checklist.

The resulting text will use one consistent formulation: “IPv4-only; IPv6 unsupported and absent on the runner path; per-network and runtime checks are authoritative; no host-global Docker daemon IPv6 requirement.”

## Verification

After editing the plan:

1. Search the plan for `fixed-cidr-v6`, `daemon-IPv4-only`, `daemon IPv4-only`, and `reject global daemon IPv6`; all matches must be removed.
2. Confirm the plan still contains `EnableIPv6=false`, IPv4-only IPAM validation, runtime global-address/default-route absence checks, and no-`ip6tables` policy.
3. Review the surrounding sections to ensure headings, examples, checkpoints, and acceptance criteria express the same policy.
4. Run `git diff --check`.

Because this change updates documentation requirements only, no product test suite or implementation change is required at this stage.
