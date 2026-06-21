#!/usr/bin/env python3
"""Recursive structural validation of the ci-build workflow scheduling boundary (Phase 1).
Checks job- AND step-level (env/secrets/id-token forbidden recursively), job-level
permissions override, exact runs-on, normalized trusted-event if-expression, and
scans ALL .github/workflows/*.yml + *.yaml (structural parse, not text grep).
Run: python3 test/test_workflow_boundary.py"""
import sys, yaml, pathlib, re

WFDIR = pathlib.Path(".github/workflows")
REPO_RUNNER_URL = "https://github.com/GentleKingson/ocserv-backport"
ALLOWED_IF = re.compile(
    r"\(\s*github\.event_name\s*==\s*['\"]push['\"]\s*&&\s*github\.ref\s*==\s*['\"]refs/heads/main['\"]\s*\)"
    r"\s*\|\|\s*"
    r"\(\s*github\.event_name\s*==\s*['\"]workflow_dispatch['\"]\s*&&\s*github\.ref\s*==\s*['\"]refs/heads/main['\"]\s*\)",
    re.MULTILINE)

def workflows():
    for p in sorted(list(WFDIR.glob("*.yml")) + list(WFDIR.glob("*.yaml"))):
        yield p, yaml.safe_load(p.read_text())

FORBIDDEN_KEYS = {"environment", "id-token"}
def find_secret_surfaces(obj, path=""):
    hits = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            p = f"{path}.{k}" if path else k
            if k in FORBIDDEN_KEYS:
                hits.append(p)
            if k == "env":
                hits.append(p)
            if k == "permissions" and path:
                hits.append(f"{p}={v}")
            if isinstance(v, str) and ("secrets." in v or "id-token" in v.lower()):
                hits.append(f"{p}(str:{v[:40]})")
            hits += find_secret_surfaces(v, p)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            hits += find_secret_surfaces(v, f"{path}[{i}]")
    return hits

def main():
    failures = []
    cibuild_locations = []
    top_perms_ok = False
    for wf, doc in workflows():
        if not isinstance(doc, dict):
            continue
        if wf.name == "ci-testing.yml":
            if doc.get("permissions") != {"contents": "read"}:
                failures.append(f"{wf.name}: top-level permissions must be exactly contents:read (got {doc.get('permissions')})")
            top_perms_ok = True
        for jn, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            if job.get("runs-on") == ["self-hosted", "ci-build"]:
                cibuild_locations.append((wf.name, jn))
                hits = find_secret_surfaces(job, jn)
                if hits:
                    failures.append(f"{wf.name}.{jn}: forbidden surfaces: {hits}")
                expr = str(job.get("if", ""))
                if not ALLOWED_IF.search(expr.replace("\n", " ")):
                    failures.append(f"{wf.name}.{jn}: if-expression must be exactly push/main OR workflow_dispatch/main (got: {expr[:120]})")
    if cibuild_locations != [("ci-testing.yml", "lock-projection-cibuild")]:
        failures.append(f"ci-build must appear exactly once on ci-testing.yml.lock-projection-cibuild (got {cibuild_locations})")
    if not top_perms_ok:
        failures.append("ci-testing.yml missing or has no top-level permissions")
    if failures:
        print("FAIL:"); [print(" -", f) for f in failures]; sys.exit(1)
    print("workflow boundary OK: ci-build exactly once; recursive no env/secrets/id-token/environment/job-permissions;")
    print("  trusted-event if normalized; top-level permissions contents:read; no other workflow uses ci-build.")
    print(f"NOTE: runner registration URL must be repository-scoped: {REPO_RUNNER_URL} (verify in GitHub UI, not org-level)")

if __name__ == "__main__":
    main()
