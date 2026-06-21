# Debian Pool Primary Source — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Invert `fetch-source.sh` from snapshot-first + 509-fallback to an explicit `FETCH_SOURCE=pool|cache` two-mode design where the builder never touches snapshot.debian.org; Snapshot access moves to a separate prefetch node that produces a verified versioned cache + transport bundle.

**Architecture:** A four-stage pipeline: YAML lock (authority) → `read-source-lock.py` projection → CI-verified `.lock.tsv` (builder input) → prefetch (snapshot) → bundle → import → versioned cache → fetch(pool|cache). Shared contracts (lock schema, cache layout, manifest, cache.meta, bundle format) are defined once in the spec and consumed by both prefetch side and builder side.

**Tech Stack:** Bash (strict mode, `set -euo pipefail`), Python 3 (`yaml.safe_load` via `StrictSafeLoader`), GNU coreutils (`sha256sum`, `cmp`, `realpath`), GNU tar (`--format=ustar`, `--zstd`), `dscverify` + `dpkg-source` (Debian keyrings), bats for tests, GitHub Actions for CI.

**Spec:** `docs/superpowers/specs/2026-06-21-debian-pool-primary-source-design.md` (authoritative — read it before starting any slice).

**Four ordered slices (1 → 2 → 3 → 4, each independently mergeable):**
- **Slice 1:** lock infra — `read-source-lock.py`, `source-lock/`, `.lock.tsv`, CI guard, tests. Pure new, no behavior change.
- **Slice 2:** prefetch/import pipeline — `_dsc.sh`, `_lock_tsv.sh`, `_cache_meta.sh`, `prefetch-source.sh`, `import-source-cache.sh`, cache contract, tests. Pure new, no behavior change.
- **Slice 3:** `fetch-source.sh` refactor — delete snapshot/509, implement pool|cache two-mode with identity closure. **Only behavior-changing slice.**
- **Slice 4:** docs sync — runbook, `.env.example`, README, Makefile, CI doc references.

**Conventions used throughout (from existing codebase):**
- Source-only libs (`_*.sh`): `#!/usr/bin/env bash` + `set -euo pipefail`, no `main()`, sourced by consumers.
- Executable scripts: resolve `SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"`, source `_common.sh` for `log`/`die`.
- Repo-root resolution: `REPO_ROOT="$(git -C "${SCRIPT_DIR}/.." rev-parse --show-toplevel)"`.
- bats: `load helpers/bats-helper.bash` (provides `REPO_ROOT`), `setup() { cd "${REPO_ROOT}"; }`, test functions via `call_func` pattern that sources the script then invokes a function.
- `SOURCE_GUARD` pattern for scripts that have a `main()`: a guard variable so tests can `source` the script without running `main`.

---

## Slice 1 — Lock infrastructure (pure new)

**Branch:** `feat/slice1-lock-infra`

### Task 1.1: Create the canonical lock file for ocserv 1.5.0-1

**Files:**
- Create: `source-lock/ocserv/1.5.0-1.yaml`

- [ ] **Step 1: Look up the real ocserv 1.5.0-1 source package metadata**

Run (on a machine with network, or check the existing snapshot URL used in `fetch-source.sh`):
```bash
# The .dsc lists Files (md5 size name) and Checksums-Sha256 (sha256 size name).
# We need: the .dsc's own size+sha256, and each artifact's size+sha256.
# From snapshot.debian.org for the timestamp currently used:
curl -fsSL "https://snapshot.debian.org/archive/debian/20260101T000000Z/pool/main/o/ocserv/ocserv_1.5.0-1.dsc"
# Then download each referenced file and compute sha256+size.
```
Record: the `.dsc` sha256+size, `ocserv_1.5.0.orig.tar.xz` sha256+size, `ocserv_1.5.0.orig.tar.xz.asc` sha256+size (if the `.dsc` lists it — the existing test fixture at `test/test_fetch_source.bats:178-193` confirms ocserv 1.5.0-1's `.dsc` DOES list the `.asc`), `ocserv_1.5.0-1.debian.tar.xz` sha256+size.

- [ ] **Step 2: Write the lock file with real values**

```yaml
# source-lock/ocserv/1.5.0-1.yaml
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources:
  - pool
  - snapshot
snapshot_timestamp: "20260101T000000Z"   # real timestamp from step 1
pool_path: "main/o/ocserv"
dsc:
  name: ocserv_1.5.0-1.dsc
  size: <real size>
  sha256: "<real 64-hex>"
artifacts:
  - name: ocserv_1.5.0.orig.tar.xz
    size: <real size>
    sha256: "<real 64-hex>"
  - name: ocserv_1.5.0.orig.tar.xz.asc
    size: <real size>
    sha256: "<real 64-hex>"
  - name: ocserv_1.5.0-1.debian.tar.xz
    size: <real size>
    sha256: "<real 64-hex>"
```

- [ ] **Step 3: Commit**

```bash
git add source-lock/ocserv/1.5.0-1.yaml
git commit -m "feat(lock): add ocserv 1.5.0-1 source lock"
```

### Task 1.2: Write `read-source-lock.py` with `StrictSafeLoader` (TDD)

**Files:**
- Create: `scripts/read-source-lock.py`
- Test: `test/test_read_source_lock.bats`

This parser: reads a lock YAML with `StrictSafeLoader` (SafeLoader semantics + duplicate-key rejection), strictly validates the schema (spec §2.2), and emits a fixed-schema TAB-separated record stream to stdout. It never does network, checksum computation, or file writes.

- [ ] **Step 1: Write the failing test for a valid lock → correct TSV output**

```bash
# test/test_read_source_lock.bats
#!/usr/bin/env bats
load helpers/bats-helper.bash

READ_LOCK="python3 ${REPO_ROOT}/scripts/read-source-lock.py"

@test "valid lock: emits META + ARTIFACT records with correct fields" {
  tmpd="$(mktemp -d)"
  cat > "$tmpd/ocserv_1.5.0-1.yaml" <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources:
  - pool
  - snapshot
snapshot_timestamp: "20260101T000000Z"
pool_path: "main/o/ocserv"
dsc:
  name: ocserv_1.5.0-1.dsc
  size: 2234
  sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
artifacts:
  - name: ocserv_1.5.0.orig.tar.xz
    size: 100
    sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
YAML
  run $READ_LOCK --lock "$tmpd/ocserv_1.5.0-1.yaml"
  [ "$status" -eq 0 ]
  # META line: rectype source version allowed snapshot_ts pool_path dsc_name dsc_size dsc_sha256
  [ "${lines[0]}" == $'META\tocserv\t1.5.0-1\tpool,snapshot\t20260101T000000Z\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t2234\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]
  [ "${lines[1]}" == $'ARTIFACT\tocserv_1.5.0.orig.tar.xz\t100\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]
  rm -rf "$tmpd"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats test/test_read_source_lock.bats`
Expected: FAIL — `scripts/read-source-lock.py` does not exist.

- [ ] **Step 3: Write `read-source-lock.py`**

```python
#!/usr/bin/env python3
"""Parse + strictly validate a source lock YAML; emit a fixed-schema TAB record stream.

stdout: one META record then N ARTIFACT records, TAB-separated. No provenance.
stderr: single-line errors. exit 1 on validation failure, exit 2 on arg error.
See spec §2.3. Uses StrictSafeLoader (SafeLoader + duplicate-key rejection).
"""
import sys
import re
import argparse

import yaml


class StrictSafeLoader(yaml.SafeLoader):
    """SafeLoader that rejects duplicate mapping keys at every level.

    Plain yaml.SafeLoader lets a later duplicate key silently overwrite the
    earlier one (data loss). We override construct_mapping to detect this.
    """
    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in seen:
                raise yaml.constructor.ConstructorError(
                    None, None, f"duplicate key {key!r} in mapping", key_node.start_mark)
            seen.add(key)
        return super().construct_mapping(node, deep=deep)


def strict_safe_load(stream):
    return yaml.load(stream, Loader=StrictSafeLoader)


# Schema regexes (spec §2.2). Kept in sync with _lock_tsv.sh consumer rules.
RE_SOURCE = re.compile(r'^[a-z0-9][a-z0-9+.\-]*$')
RE_DEBIAN_VERSION = re.compile(r'^[A-Za-z0-9.+~\-]+$')   # NO epoch (advisory B)
RE_SHA256 = re.compile(r'^[0-9a-f]{64}$')
RE_SNAPSHOT_TS = re.compile(r'^\d{8}T\d{6}Z$')
RE_POOL_SEGMENT = re.compile(r'^[A-Za-z0-9][A-Za-z0-9+._\-]*$')
RE_SAFE_BASENAME = re.compile(r'^[^/\x00-\x1f\x7f \\]+$')  # tightened: no whitespace


def fail(msg):
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def check_pool_path(path):
    if path.startswith('/') or path.endswith('/'):
        fail(f"pool_path must not have leading/trailing slash: {path!r}")
    if '\\' in path:
        fail("pool_path must not contain backslash")
    if re.search(r'[\x00-\x1f\x7f]', path):
        fail("pool_path must not contain control characters")
    if '://' in path or '?' in path or '#' in path or '%' in path:
        fail("pool_path must not contain :// ? # %")
    segs = path.split('/')
    if any(s in ('', '.', '..') for s in segs):
        fail(f"pool_path has empty/./.. segment: {path!r}")
    for s in segs:
        if not RE_POOL_SEGMENT.match(s):
            fail(f"pool_path segment invalid: {s!r}")


def check_size(v, field):
    if isinstance(v, bool) or not isinstance(v, int) or v < 0:
        fail(f"{field} must be a non-negative int (got {v!r})")


def check_safe_name(v, field):
    if not isinstance(v, str) or not RE_SAFE_BASENAME.match(v) or v in ('.', '..') or v.startswith('-'):
        fail(f"{field} invalid basename: {v!r}")


def validate(data):
    if not isinstance(data, dict):
        fail("lock root must be a mapping")
    allowed_top = {'schema_version', 'source', 'debian_version', 'allowed_sources',
                   'snapshot_timestamp', 'pool_path', 'dsc', 'artifacts'}
    unknown = set(data) - allowed_top
    if unknown:
        fail(f"unknown top-level fields: {sorted(unknown)}")

    if data.get('schema_version') != 1:
        fail("schema_version must be == 1")
    src = data.get('source')
    if not isinstance(src, str) or not RE_SOURCE.match(src):
        fail(f"source invalid: {src!r}")
    ver = data.get('debian_version')
    if not isinstance(ver, str) or not RE_DEBIAN_VERSION.match(ver):
        fail(f"debian_version invalid: {ver!r}")

    allowed = data.get('allowed_sources')
    if not isinstance(allowed, list) or not allowed:
        fail("allowed_sources must be a non-empty list")
    if set(allowed) - {'pool', 'snapshot'}:
        fail("allowed_sources must be subset of {pool, snapshot}")
    if len(set(allowed)) != len(allowed):
        fail("allowed_sources must not contain duplicates")
    has_snap = 'snapshot' in allowed
    has_pool = 'pool' in allowed

    ts = data.get('snapshot_timestamp')
    if has_snap:
        if not isinstance(ts, str) or not RE_SNAPSHOT_TS.match(ts):
            fail("snapshot_timestamp required and must match \\d{8}T\\d{6}Z when snapshot allowed")
    else:
        if 'snapshot_timestamp' in data:
            fail("snapshot_timestamp present but snapshot not in allowed_sources")

    pp = data.get('pool_path')
    if has_pool:
        if not isinstance(pp, str):
            fail("pool_path required when pool in allowed_sources")
        check_pool_path(pp)
    else:
        if 'pool_path' in data:
            fail("pool_path present but pool not in allowed_sources")

    dsc = data.get('dsc')
    if not isinstance(dsc, dict):
        fail("dsc must be a mapping")
    for k in ('name', 'size', 'sha256'):
        if k not in dsc:
            fail(f"dsc.{k} missing")
    check_safe_name(dsc['name'], 'dsc.name')
    if not dsc['name'].endswith('.dsc'):
        fail("dsc.name must end with .dsc")
    check_size(dsc['size'], 'dsc.size')
    if not isinstance(dsc['sha256'], str) or not RE_SHA256.match(dsc['sha256']):
        fail("dsc.sha256 must be 64 lowercase hex")

    arts = data.get('artifacts')
    if not isinstance(arts, list) or not arts:
        fail("artifacts must be a non-empty list")
    names = []
    for i, a in enumerate(arts):
        if not isinstance(a, dict):
            fail(f"artifacts[{i}] must be a mapping")
        for k in ('name', 'size', 'sha256'):
            if k not in a:
                fail(f"artifacts[{i}].{k} missing")
        check_safe_name(a['name'], f'artifacts[{i}].name')
        if a['name'] == dsc['name']:
            fail(f"artifacts[{i}].name must not equal dsc.name")
        check_size(a['size'], f'artifacts[{i}].size')
        if not isinstance(a['sha256'], str) or not RE_SHA256.match(a['sha256']):
            fail(f"artifacts[{i}].sha256 must be 64 lowercase hex")
        names.append(a['name'])
    if len(set(names)) != len(names):
        fail("artifact names must be unique")
    return data


def emit(data):
    allowed_sorted = ','.join(sorted(set(data['allowed_sources'])))
    ts = data.get('snapshot_timestamp', '-')
    pp = data.get('pool_path', '-')
    d = data['dsc']
    print(f"META\t{data['source']}\t{data['debian_version']}\t{allowed_sorted}\t{ts}\t{pp}\t{d['name']}\t{d['size']}\t{d['sha256']}")
    for a in data['artifacts']:
        print(f"ARTIFACT\t{a['name']}\t{a['size']}\t{a['sha256']}")


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--lock', help='path to <name>/<version>.yaml')
    g.add_argument('--source', help='source name (resolves lock path)')
    ap.add_argument('--debian-version', dest='debian_version',
                    help='debian version (required with --source)')
    args = ap.parse_args()

    if args.lock is not None:
        if args.debian_version is not None:
            ap.error("--lock is mutually exclusive with --source/--debian-version")
        lock_path = args.lock
    else:
        if args.debian_version is None:
            ap.error("--source requires --debian-version")
        lock_path = f"source-lock/{args.source}/{args.debian_version}.yaml"

    try:
        with open(lock_path, 'r', encoding='utf-8') as f:
            raw = f.read()
    except FileNotFoundError:
        fail(f"lock file not found: {lock_path}")
    try:
        data = strict_safe_load(raw)
    except yaml.YAMLError as e:
        fail(f"YAML parse error: {e}")
    validate(data)
    emit(data)


if __name__ == '__main__':
    main()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats test/test_read_source_lock.bats`
Expected: PASS. (If `ModuleNotFoundError: yaml`, install `pip install -r requirements/prefetch.txt` from Task 1.4 first.)

- [ ] **Step 5: Commit**

```bash
git add scripts/read-source-lock.py test/test_read_source_lock.bats
git commit -m "feat(lock): read-source-lock.py with StrictSafeLoader + schema validation"
```

### Task 1.3: Add parser validation-failure tests (TDD)

**Files:**
- Modify: `test/test_read_source_lock.bats`

- [ ] **Step 1: Append the validation-failure test cases**

Append to `test/test_read_source_lock.bats` (after the valid-lock test):

```bash
make_lock() {  # $1 = content, writes to $tmpd/lock.yaml, echoes path
  tmpd="$(mktemp -d)"; printf '%s' "$1" > "$tmpd/lock.yaml"; echo "$tmpd/lock.yaml"
}
cleanup_tmp() { [[ -n "${tmpd:-}" ]] && rm -rf "$tmpd"; }

@test "rejects: --source without --debian-version (arg error)" {
  run $READ_LOCK --source ocserv
  [ "$status" -eq 2 ]
}

@test "rejects: --lock and --source both given (arg error)" {
  run $READ_LOCK --lock /tmp/x.yaml --source ocserv --debian-version 1.5.0-1
  [ "$status" -eq 2 ]
}

@test "rejects: duplicate YAML key" {
  body='source: ocserv
source: other'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_tmp
  [ "$status" -eq 1 ]
}

@test "rejects: unknown top-level field" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/o/ocserv"
dsc: {name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]
bogus: 1'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_tmp
  [ "$status" -eq 1 ]
}

@test "rejects: epoch in debian_version" {
  body='debian_version: "1:1.5.0-1"'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_tmp
  [ "$status" -eq 1 ]
}

@test "rejects: snapshot allowed but no timestamp" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [snapshot]
dsc: {name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_tmp
  [ "$status" -eq 1 ]
}

@test "rejects: pool_path with ../ segment" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/../etc"
dsc: {name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_tmp
  [ "$status" -eq 1 ]
}

@test "rejects: pool_path as full URL" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "https://evil.invalid/x"
dsc: {name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_tmp
  [ "$status" -eq 1 ]
}

@test "rejects: artifact name == dsc.name" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/o/ocserv"
dsc: {name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: o.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_tmp
  [ "$status" -eq 1 ]
}

@test "rejects: dsc.name not ending .dsc" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/o/ocserv"
dsc: {name: o.txt, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_tmp
  [ "$status" -eq 1 ]
}

@test "rejects: YAML bool as size" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/o/ocserv"
dsc: {name: o.dsc, size: true, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_tmp
  [ "$status" -eq 1 ]
}

@test "rejects: uppercase sha256" {
  body='schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [pool]
pool_path: "main/o/ocserv"
dsc: {name: o.dsc, size: 1, sha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
artifacts: [{name: a.tar, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}]'
  p="$(make_lock "$body")"
  run $READ_LOCK --lock "$p"; cleanup_tmp
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run all parser tests**

Run: `bats test/test_read_source_lock.bats`
Expected: all PASS.

- [ ] **Step 3: Commit**

```bash
git add test/test_read_source_lock.bats
git commit -m "test(lock): parser validation-failure cases"
```

### Task 1.4: Add `requirements/prefetch.txt` and generate the committed `.lock.tsv`

**Files:**
- Create: `requirements/prefetch.txt`
- Create: `source-lock/ocserv/1.5.0-1.lock.tsv`

- [ ] **Step 1: Write the requirements file**

```
# requirements/prefetch.txt
PyYAML==6.0.2
```

- [ ] **Step 2: Install it locally to generate the projection**

```bash
python3 -m pip install --user -r requirements/prefetch.txt   # or use a venv
python3 scripts/read-source-lock.py --lock source-lock/ocserv/1.5.0-1.yaml > source-lock/ocserv/1.5.0-1.lock.tsv
```

- [ ] **Step 3: Verify the projection is well-formed (it must NOT be hand-edited)**

```bash
# Re-run and confirm byte-for-byte identical (idempotent projection):
python3 scripts/read-source-lock.py --lock source-lock/ocserv/1.5.0-1.yaml | cmp -s - source-lock/ocserv/1.5.0-1.lock.tsv && echo "OK: projection matches"
```
Expected: `OK: projection matches`. The `.lock.tsv` must contain exactly the META + ARTIFACT lines, no trailing banner.

- [ ] **Step 4: Commit**

```bash
git add requirements/prefetch.txt source-lock/ocserv/1.5.0-1.lock.tsv
git commit -m "feat(lock): PyYAML requirement + committed ocserv 1.5.0-1.lock.tsv projection"
```

### Task 1.5: CI lock projection guard (TDD via workflow + a guard test)

**Files:**
- Modify: `.github/workflows/ci-testing.yml`
- Test: `test/test_lock_projection.bats`

The CI guard (spec §5.5) must run in slice 1 (not slice 4) so `.lock.tsv` has drift protection immediately. It: installs PyYAML in a venv, runs the parser for every `source-lock/**/*.yaml`, `cmp -s` against the committed `.lock.tsv`, and rejects orphan/missing/drifted `.lock.tsv`.

- [ ] **Step 1: Write the projection-drift test**

```bash
# test/test_lock_projection.bats
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
```

- [ ] **Step 2: Run it**

Run: `bats test/test_lock_projection.bats`
Expected: PASS (the Task 1.4 projection is committed and matches).

- [ ] **Step 3: Add the CI job**

In `.github/workflows/ci-testing.yml`, add a new job `lock-projection` that runs first (the `build` job depends on it). Insert after the `on:` block:

```yaml
  lock-projection:
    runs-on: [self-hosted, builder]
    steps:
      - uses: actions/checkout@v4
      - name: verify lock.tsv projection
        run: |
          set -euo pipefail
          python3 -m venv .ci-venv
          .ci-venv/bin/python -m pip install -r requirements/prefetch.txt
          while IFS= read -r -d '' yaml; do
            .ci-venv/bin/python scripts/read-source-lock.py --lock "$yaml" > /tmp/proj.tsv
            cmp -s /tmp/proj.tsv "${yaml%.yaml}.lock.tsv" \
              || { echo "lock.tsv drift: $yaml"; exit 1; }
          done < <(find source-lock -type f -name '*.yaml' -print0 | sort -z)
          while IFS= read -r -d '' tsv; do
            [[ -f "${tsv%.lock.tsv}.yaml" ]] \
              || { echo "orphan lock.tsv: $tsv"; exit 1; }
          done < <(find source-lock -type f -name '*.lock.tsv' -print0 | sort -z)
```

And change the `build:` job to add `needs: [lock-projection]`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci-testing.yml test/test_lock_projection.bats
git commit -m "ci(lock): add lock.tsv projection guard job (slice 1)"
```

### Task 1.6: Slice 1 verification

- [ ] **Step 1: Run the full bats suite**

Run: `make test`
Expected: all tests PASS (existing `test_fetch_source.bats` still passes — slice 1 changed nothing in `fetch-source.sh`).

- [ ] **Step 2: shellcheck the parser is N/A (it's Python); confirm no shell changed**

```bash
git diff --stat main..HEAD -- scripts/*.sh
```
Expected: empty (no shell scripts changed in slice 1).

- [ ] **Step 3: Open the PR for slice 1** (or mark slice 1 complete if merging directly).

Slice 1 leaves `fetch-source.sh` untouched → existing dry-run behavior is unchanged. This is the gate: nothing in slice 1 may alter the build.

---

## Slice 2 — prefetch/import pipeline + versioned cache (pure new)

**Branch:** `feat/slice2-prefetch-import` (off main, after slice 1 merges)

> Slice 2 creates `_dsc.sh`, `_lock_tsv.sh`, `_cache_meta.sh`, `prefetch-source.sh`, `import-source-cache.sh`. It sources slice 1's `read-source-lock.py`. It does NOT touch `fetch-source.sh` — the existing fetch script keeps its inline `_dsc_*` copies untouched until slice 3.

### Task 2.1: `_dsc.sh` shared Deb822 parser (extracted + upgraded from fetch-source.sh)

**Files:**
- Create: `scripts/_dsc.sh`
- Test: `test/test_dsc_helper.bats`

Extract `_dsc_field`, `parse_dsc_artifacts`, `validate_artifact_basenames`, `validate_dsc_metadata` from `scripts/fetch-source.sh:47-123` into a source-only lib, and upgrade `parse_dsc_artifacts` to emit full SHA256+size+filename mappings (not just name sets).

- [ ] **Step 1: Read the current fetch-source.sh helpers to copy their logic exactly**

```bash
sed -n '40,170p' scripts/fetch-source.sh
```
Note the exact awk-scoped `_dsc_field` (skips PGP armor), `validate_dsc_metadata`, `parse_dsc_artifacts`, `validate_artifact_basenames`.

- [ ] **Step 2: Write the failing test**

```bash
# test/test_dsc_helper.bats
#!/usr/bin/env bats
load helpers/bats-helper.bash

call_dsc() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/_dsc.sh'; $*"
}

@test "validate_dsc_metadata: accepts correct Source/Version" {
  tmpd="$(mktemp -d)"
  printf '%s\n' 'Format: 3.0 (quilt)' 'Source: ocserv' 'Version: 1.5.0-1' > "$tmpd/x.dsc"
  call_dsc "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rm -rf "$tmpd"; [ "$status" -eq 0 ]
}

@test "validate_dsc_metadata: rejects wrong Version" {
  tmpd="$(mktemp -d)"
  printf '%s\n' 'Source: ocserv' 'Version: 1.4.0-1' > "$tmpd/x.dsc"
  call_dsc "validate_dsc_metadata '$tmpd/x.dsc' ocserv 1.5.0-1"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "parse_dsc_full: emits name<TAB>size<TAB>sha256 per artifact, Files==Checksums" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Format: 3.0 (quilt)' 'Source: ocserv' 'Version: 1.5.0-1' \
    'Files:' \
    ' 1111 2222 ocserv_1.5.0.orig.tar.xz' \
    ' 3333 4444 ocserv_1.5.0-1.debian.tar.xz' \
    'Checksums-Sha256:' \
    ' aaaa 2222 ocserv_1.5.0.orig.tar.xz' \
    ' bbbb 4444 ocserv_1.5.0-1.debian.tar.xz' > "$tmpd/x.dsc"
  call_dsc "parse_dsc_full '$tmpd/x.dsc'"
  rm -rf "$tmpd"
  [ "$status" -eq 0 ]
  # Each line: name<TAB>size<TAB>sha256, order preserved
  [ "${lines[0]}" == $'ocserv_1.5.0.orig.tar.xz\t2222\taaaa' ]
  [ "${lines[1]}" == $'ocserv_1.5.0-1.debian.tar.xz\t4444\tbbbb' ]
}

@test "dsc_artifacts_match_lock: passes when dsc == lock mapping" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Files:' ' 1 100 a.tar' \
    'Checksums-Sha256:' ' sha1 100 a.tar' > "$tmpd/x.dsc"
  # ARTIFACT_NAME / ARTIFACT_SIZE / ARTIFACT_SHA256 arrays set by caller
  call_dsc "ARTIFACT_NAME=(a.tar); ARTIFACT_SIZE=(100); ARTIFACT_SHA256=(sha1); dsc_artifacts_match_lock '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -eq 0 ]
}

@test "dsc_artifacts_match_lock: dies when sha256 differs" {
  tmpd="$(mktemp -d)"
  printf '%s\n' \
    'Files:' ' 1 100 a.tar' \
    'Checksums-Sha256:' ' evil 100 a.tar' > "$tmpd/x.dsc"
  call_dsc "ARTIFACT_NAME=(a.tar); ARTIFACT_SIZE=(100); ARTIFACT_SHA256=(sha1); dsc_artifacts_match_lock '$tmpd/x.dsc'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}

@test "validate_artifact_basenames: rejects path traversal" {
  call_dsc "validate_artifact_basenames 'a.tar ../../etc/passwd'"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bats test/test_dsc_helper.bats`
Expected: FAIL — `scripts/_dsc.sh` does not exist.

- [ ] **Step 4: Write `scripts/_dsc.sh`**

```bash
#!/usr/bin/env bash
# Source-only Deb822 (.dsc) parser library. Spec §3.6.1.
# Extracted+upgraded from fetch-source.sh (slice 2); fetch-source.sh adopts it in slice 3.
set -euo pipefail

# _dsc_field <dsc_path> <FieldName>  — single-line field, PGP-armor-aware.
_dsc_field() {
  local dsc_path="$1" field="$2"
  awk -v f="$field" '
    /^-----BEGIN PGP SIGNED MESSAGE-----/ { in_hdr=1; next }
    /^-----BEGIN PGP SIGNATURE-----/ { exit }
    in_hdr && /^Hash:/ { next }
    in_hdr && /^$/ { in_hdr=0; next }
    !in_hdr && $0 ~ "^"f":" { sub("^"f":[[:space:]]*",""); print; exit }
  ' "$dsc_path"
}

validate_dsc_metadata() {
  local dsc_path="$1" exp_src="$2" exp_ver="$3"
  local got_src got_ver
  got_src="$(_dsc_field "$dsc_path" Source)"
  got_ver="$(_dsc_field "$dsc_path" Version)"
  [[ "$got_src" == "$exp_src" ]] || { echo "dsc Source '$got_src' != '$exp_src'" >&2; return 1; }
  [[ "$got_ver" == "$exp_ver" ]] || { echo "dsc Version '$got_ver' != '$exp_ver'" >&2; return 1; }
}

# validate_artifact_basenames <space-separated names>
validate_artifact_basenames() {
  local names="$1"
  [[ -n "$names" ]] || { echo "empty artifact list" >&2; return 1; }
  local -a arr=( $names )
  local -A seen=()
  local n
  for n in "${arr[@]}"; do
    [[ "$n" != *"/"* && "$n" != *"\\"* && "$n" != ".." && "$n" != "." && "$n" != *[[:cntrl:]]* && "$n" != *" "* ]] \
      || { echo "bad basename: $n" >&2; return 1; }
    [[ -z "${seen[$n]:-}" ]] || { echo "dup basename: $n" >&2; return 1; }
    seen[$n]=1
  done
}

# parse_dsc_full <dsc_path> — emit name<TAB>size<TAB>sha256 per artifact, order preserved.
# Requires Files stanza and Checksums-Sha256 stanza; dies if either missing or mismatched.
parse_dsc_full() {
  local dsc_path="$1"
  # Build: name -> sha256 (from Checksums-Sha256), name -> size (from Files).
  local tmp; tmp="$(mktemp)"
  awk '
    /^-----BEGIN PGP SIGNATURE-----/ { exit }
    /^-----BEGIN PGP SIGNED MESSAGE-----/ { in_hdr=1; next }
    in_hdr && /^Hash:/ { next }
    in_hdr && /^$/ { in_hdr=0; next }
    in_hdr { next }
    /^Files:/ { sec="files"; next }
    /^Checksums-Sha256:/ { sec="csum"; next }
    /^[^[:space:]]/ { sec=""; next }
    sec=="files" && /^[[:space:]]/ {
      # md5 size name
      line=$0; sub(/^[[:space:]]+/,"",line); n=split(line,p," ");
      files_name[p[3]]=p[2]; files_order[++fc]=p[3]; next
    }
    sec=="csum" && /^[[:space:]]/ {
      line=$0; sub(/^[[:space:]]+/,"",line); n=split(line,p," ");
      csum_sha[p[3]]=p[1]; csum_size[p[3]]=p[2]; next
    }
    END {
      for (i=1;i<=fc;i++) {
        nm=files_order[i]
        if (!(nm in csum_sha)) { print "missing Checksums-Sha256 for "nm > "/dev/stderr"; exit 1 }
        if (files_name[nm] != csum_size[nm]) { print "size mismatch "nm > "/dev/stderr"; exit 1 }
        printf "%s\t%s\t%s\n", nm, files_name[nm], csum_sha[nm]
      }
    }
  ' "$dsc_path" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp"; rm -f "$tmp"
}

# dsc_artifacts_match_lock <dsc_path>
# Caller sets arrays: ARTIFACT_NAME[], ARTIFACT_SIZE[], ARTIFACT_SHA256[] (from lock).
# Validates: Files set == Checksums set == lock set; per-artifact size+sha256 == lock.
dsc_artifacts_match_lock() {
  local dsc_path="$1"
  local -A lock_size lock_sha
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do
    lock_size["${ARTIFACT_NAME[$i]}"]="${ARTIFACT_SIZE[$i]}"
    lock_sha["${ARTIFACT_NAME[$i]}"]="${ARTIFACT_SHA256[$i]}"
  done
  local parsed; parsed="$(parse_dsc_full "$dsc_path")" || return 1
  local name size sha
  local -A seen=()
  while IFS=$'\t' read -r name size sha; do
    [[ -n "${lock_size[$name]:-}" ]] || { echo "dsc lists $name not in lock" >&2; return 1; }
    [[ "$size" == "${lock_size[$name]}" ]] || { echo "size mismatch $name" >&2; return 1; }
    [[ "$sha" == "${lock_sha[$name]}" ]] || { echo "sha256 mismatch $name" >&2; return 1; }
    seen[$name]=1
  done <<< "$parsed"
  # All lock artifacts must appear in dsc.
  for i in "${!ARTIFACT_NAME[@]}"; do
    [[ -n "${seen[${ARTIFACT_NAME[$i]}]:-}" ]] || { echo "lock lists ${ARTIFACT_NAME[$i]} not in dsc" >&2; return 1; }
  done
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats test/test_dsc_helper.bats`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/_dsc.sh test/test_dsc_helper.bats
git commit -m "feat(dsc): _dsc.sh shared Deb822 parser with full sha256+size mapping"
```

### Task 2.2: `_lock_tsv.sh` shared parser + `write_expected_sha256sums`

**Files:**
- Create: `scripts/_lock_tsv.sh`
- Test: `test/test_lock_tsv_helper.bats`

`read_lock_tsv <file> <expect_version>`: strictly parses a `.lock.tsv`, fills globals `META_SOURCE`, `META_DEBIAN_VERSION`, `META_ALLOWED_SOURCES`, `META_SNAPSHOT_TS`, `META_POOL_PATH`, `META_DSC_NAME`, `META_DSC_SIZE`, `META_DSC_SHA256`, and arrays `ARTIFACT_NAME[]`, `ARTIFACT_SIZE[]`, `ARTIFACT_SHA256[]`. Enforces the 3-way identity assertion (expect_version ↔ META ↔ lock path). `write_expected_sha256sums <out_file>`: emits expected SHA256SUMS content from current META/ARTIFACT.

- [ ] **Step 1: Write the failing test**

```bash
# test/test_lock_tsv_helper.bats
#!/usr/bin/env bats
load helpers/bats-helper.bash

call_tsv() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/_lock_tsv.sh'; $*"
}

# A valid TSV fixture matching parser output schema.
VALID_TSV=$'META\tocserv\t1.5.0-1\tpool,snapshot\t20260101T000000Z\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t2234\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nARTIFACT\tocserv_1.5.0.orig.tar.xz\t100\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

@test "read_lock_tsv: valid tsv fills globals + 3-way identity passes" {
  tmp="$(mktemp)"; printf '%s\n' "$VALID_TSV" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1; echo SRC=\$META_SOURCE VER=\$META_DEBIAN_VERSION"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SRC=ocserv VER=1.5.0-1"* ]]
}

@test "read_lock_tsv: dies when expect_version != META version" {
  tmp="$(mktemp)"; printf '%s\n' "$VALID_TSV" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 9.9.9-9"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: dies when META source != ocserv" {
  tmp="$(mktemp)"
  printf '%s\n' "${VALID_TSV/META\tocserv/META\totherpkg}" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: dies on CRLF" {
  tmp="$(mktemp)"; printf '%s\r\n' "$VALID_TSV" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: dies on duplicate ARTIFACT name" {
  tmp="$(mktemp)"
  printf '%s\n%s\n' "$VALID_TSV" "$(printf '%s\n' "$VALID_TSV" | tail -1)" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: dies on META not first line" {
  tmp="$(mktemp)"
  { printf '%s\n' "$VALID_TSV" | tail -1; printf '%s\n' "$VALID_TSV" | head -1; } > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_lock_tsv: dies on unknown record type" {
  tmp="$(mktemp)"; printf '%s\nBOGUS\tx\n' "$VALID_TSV" > "$tmp"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1"
  rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "write_expected_sha256sums: dsc first, then artifacts in lock order" {
  tmp="$(mktemp)"; printf '%s\n' "$VALID_TSV" > "$tmp"
  out="$(mktemp)"
  call_tsv "read_lock_tsv '$tmp' 1.5.0-1 && write_expected_sha256sums '$out'; cat '$out'"
  rm -f "$tmp" "$out"
  [ "$status" -eq 0 ]
  # Line 1 = dsc, line 2 = first artifact
  [ "${lines[0]}" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ocserv_1.5.0-1.dsc" ]
  [ "${lines[1]}" == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  ocserv_1.5.0.orig.tar.xz" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats test/test_lock_tsv_helper.bats`
Expected: FAIL — `scripts/_lock_tsv.sh` does not exist.

- [ ] **Step 3: Write `scripts/_lock_tsv.sh`**

```bash
#!/usr/bin/env bash
# Source-only restricted .lock.tsv parser. Spec §4.3.1.
# read_lock_tsv <file> <expect_version>  — fills META_* globals + ARTIFACT_* arrays.
# write_expected_sha256sums <out_file>     — emit expected SHA256SUMS from current META/ARTIFACT.
set -euo pipefail

RE_TSV_SOURCE='^[a-z0-9][a-z0-9+.\-]*$'
RE_TSV_VERSION='^[A-Za-z0-9.+~\-]+$'
RE_TSV_SHA='^[0-9a-f]{64}$'

_tsv_die() { echo "lock.tsv error: $*" >&2; return 1; }

read_lock_tsv() {
  local file="$1" expect_ver="$2"
  [[ -f "$file" ]] || _tsv_die "file not found: $file"
  # Reject CRLF.
  if grep -q $'\r' "$file"; then _tsv_die "CRLF present"; fi

  META_SOURCE=""; META_DEBIAN_VERSION=""; META_ALLOWED_SOURCES=""
  META_SNAPSHOT_TS=""; META_POOL_PATH=""; META_DSC_NAME=""; META_DSC_SIZE=""; META_DSC_SHA256=""
  ARTIFACT_NAME=(); ARTIFACT_SIZE=(); ARTIFACT_SHA256=()
  local lineno=0 meta_seen=0
  local -A art_seen=()
  local rectype
  while IFS=$'\t' read -r rectype f1 f2 f3 f4 f5 f6 f7 f8 rest || [[ -n "$rectype" ]]; do
    lineno=$((lineno+1))
    [[ -z "$rest" ]] || _tsv_die "line $lineno: extra fields"
    case "$rectype" in
      META)
        [[ "$meta_seen" -eq 0 ]] || _tsv_die "multiple META records"
        [[ "$lineno" -eq 1 ]] || _tsv_die "META must be first line"
        meta_seen=1
        # exactly 9 columns: rectype + 8
        [[ -n "$f1$f2$f3$f4$f5$f6$f7$f8" ]] || _tsv_die "META missing fields"
        META_SOURCE="$f1"; META_DEBIAN_VERSION="$f2"; META_ALLOWED_SOURCES="$f3"
        META_SNAPSHOT_TS="$f4"; META_POOL_PATH="$f5"
        META_DSC_NAME="$f6"; META_DSC_SIZE="$f7"; META_DSC_SHA256="$f8"
        [[ "$META_SNAPSHOT_TS" == "-" ]] && META_SNAPSHOT_TS=""
        [[ "$META_POOL_PATH" == "-" ]] && META_POOL_PATH=""
        [[ "$META_SOURCE" =~ $RE_TSV_SOURCE ]] || _tsv_die "bad source"
        [[ "$META_DEBIAN_VERSION" =~ $RE_TSV_VERSION ]] || _tsv_die "bad debian_version"
        [[ "$META_DSC_SHA256" =~ $RE_TSV_SHA ]] || _tsv_die "bad dsc sha256"
        [[ "$META_DSC_SIZE" =~ ^[0-9]+$ ]] || _tsv_die "bad dsc size"
        ;;
      ARTIFACT)
        [[ "$meta_seen" -eq 1 ]] || _tsv_die "ARTIFACT before META"
        [[ -n "$f1$f2$f3" ]] || _tsv_die "ARTIFACT missing fields"
        [[ -z "$f4" ]] || _tsv_die "ARTIFACT extra fields"
        [[ "$f1" =~ $RE_TSV_SHA || "$f1" == "$META_DSC_NAME" ]] || true  # name validated below
        [[ -n "$f1" && "$f1" != *"/"* && "$f1" != *"\\"* && "$f1" != *" "* && "$f1" != -* ]] \
          || _tsv_die "bad artifact name: $f1"
        [[ -z "${art_seen[$f1]:-}" ]] || _tsv_die "dup artifact: $f1"
        [[ "$f1" != "$META_DSC_NAME" ]] || _tsv_die "artifact == dsc name"
        [[ "$f2" =~ ^[0-9]+$ ]] || _tsv_die "bad artifact size"
        [[ "$f3" =~ $RE_TSV_SHA ]] || _tsv_die "bad artifact sha256"
        art_seen[$f1]=1
        ARTIFACT_NAME+=("$f1"); ARTIFACT_SIZE+=("$f2"); ARTIFACT_SHA256+=("$f3")
        ;;
      *) _tsv_die "unknown record type: $rectype" ;;
    esac
  done < "$file"

  [[ "$meta_seen" -eq 1 ]] || _tsv_die "no META record"
  [[ "${#ARTIFACT_NAME[@]}" -ge 1 ]] || _tsv_die "no ARTIFACT records"
  # 3-way identity: expect_version == META version (caller also checks lock path <ver>)
  [[ "$META_DEBIAN_VERSION" == "$expect_ver" ]] \
    || _tsv_die "expect_version '$expect_ver' != META debian_version '$META_DEBIAN_VERSION'"
  [[ "$META_SOURCE" == "ocserv" ]] || _tsv_die "META source != ocserv"
}

write_expected_sha256sums() {
  local out="$1"
  : > "$out"
  printf '%s  %s\n' "$META_DSC_SHA256" "$META_DSC_NAME" >> "$out"
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do
    printf '%s  %s\n' "${ARTIFACT_SHA256[$i]}" "${ARTIFACT_NAME[$i]}" >> "$out"
  done
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_lock_tsv_helper.bats`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_lock_tsv.sh test/test_lock_tsv_helper.bats
git commit -m "feat(lock-tsv): _lock_tsv.sh restricted parser + expected SHA256SUMS writer"
```

### Task 2.3: `_cache_meta.sh` shared parser

**Files:**
- Create: `scripts/_cache_meta.sh`
- Test: `test/test_cache_meta_helper.bats`

`read_cache_meta <file>` (fills `CM_*`), `verify_cache_meta_versions()` (meta/bundle/manifest schema ==1), `verify_manifest_hash <cache_dir>`.

- [ ] **Step 1: Write the failing test**

```bash
# test/test_cache_meta_helper.bats
#!/usr/bin/env bats
load helpers/bats-helper.bash

call_cm() {
  run bash -c "set +e; source '${REPO_ROOT}/scripts/_cache_meta.sh'; $*"
}

VALID_META=$'meta_format_version=1\nbundle_format_version=1\nsource=ocserv\ndebian_version=1.5.0-1\ncontent_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nmanifest_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nmanifest_schema_version=1'

@test "read_cache_meta: valid meta fills globals" {
  tmp="$(mktemp)"; printf '%s\n' "$VALID_META" > "$tmp"
  call_cm "read_cache_meta '$tmp'; echo \$CM_SOURCE \$CM_DEBIAN_VERSION \$CM_META_FORMAT_VERSION"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ocserv 1.5.0-1 1"* ]]
}

@test "read_cache_meta: dies on duplicate field" {
  tmp="$(mktemp)"; printf '%s\n%s\n' "$VALID_META" "source=evil" > "$tmp"
  call_cm "read_cache_meta '$tmp'"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_cache_meta: dies on unknown field" {
  tmp="$(mktemp)"; printf '%s\n%s\n' "$VALID_META" "bogus=1" > "$tmp"
  call_cm "read_cache_meta '$tmp'"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "read_cache_meta: dies on epoch in version" {
  tmp="$(mktemp)"; printf '%s\n' "${VALID_META/debian_version=1.5.0-1/debian_version=1:1.5.0-1}" > "$tmp"
  call_cm "read_cache_meta '$tmp'"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "verify_cache_meta_versions: dies when bundle_format_version != 1" {
  tmp="$(mktemp)"; printf '%s\n' "${VALID_META/bundle_format_version=1/bundle_format_version=2}" > "$tmp"
  call_cm "read_cache_meta '$tmp' && verify_cache_meta_versions"; rm -f "$tmp"; [ "$status" -ne 0 ]
}

@test "verify_cache_meta_versions: passes when all == 1" {
  tmp="$(mktemp)"; printf '%s\n' "$VALID_META" > "$tmp"
  call_cm "read_cache_meta '$tmp' && verify_cache_meta_versions"; rm -f "$tmp"; [ "$status" -eq 0 ]
}

@test "verify_manifest_hash: dies on mismatch" {
  tmpd="$(mktemp -d)"; printf '%s\n' "$VALID_META" > "$tmpd/cache.meta"
  echo "{}" > "$tmpd/source-manifest.json"
  call_cm "read_cache_meta '$tmpd/cache.meta' && verify_manifest_hash '$tmpd'"
  rm -rf "$tmpd"; [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats test/test_cache_meta_helper.bats`
Expected: FAIL.

- [ ] **Step 3: Write `scripts/_cache_meta.sh`**

```bash
#!/usr/bin/env bash
# Source-only cache.meta restricted parser. Spec §3.5.1.
set -euo pipefail

RE_CM_SOURCE='^[a-z0-9][a-z0-9+.\-]*$'
RE_CM_VERSION='^[A-Za-z0-9.+~\-]+$'
RE_CM_SHA='^[0-9a-f]{64}$'

_cm_die() { echo "cache.meta error: $*" >&2; return 1; }

read_cache_meta() {
  local file="$1"
  [[ -f "$file" ]] || _cm_die "not found: $file"
  CM_SOURCE=""; CM_DEBIAN_VERSION=""; CM_CONTENT_SHA256=""; CM_MANIFEST_SHA256=""
  CM_META_FORMAT_VERSION=""; CM_BUNDLE_FORMAT_VERSION=""; CM_MANIFEST_SCHEMA_VERSION=""
  local -A seen=()
  local k v
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    [[ -z "$k" ]] && continue
    case "$k" in
      meta_format_version|bundle_format_version|source|debian_version|content_sha256|manifest_sha256|manifest_schema_version) ;;
      *) _cm_die "unknown field: $k" ;;
    esac
    [[ -z "${seen[$k]:-}" ]] || _cm_die "duplicate field: $k"
    [[ -n "$v" ]] || _cm_die "empty value: $k"
    [[ "$v" != *[[:cntrl:]]* && "$v" != *" "* ]] || _cm_die "bad value chars: $k"
    seen[$k]=1
    case "$k" in
      source) CM_SOURCE="$v" ;;
      debian_version) CM_DEBIAN_VERSION="$v" ;;
      content_sha256) CM_CONTENT_SHA256="$v" ;;
      manifest_sha256) CM_MANIFEST_SHA256="$v" ;;
      meta_format_version) CM_META_FORMAT_VERSION="$v" ;;
      bundle_format_version) CM_BUNDLE_FORMAT_VERSION="$v" ;;
      manifest_schema_version) CM_MANIFEST_SCHEMA_VERSION="$v" ;;
    esac
  done < "$file"
  for req in source debian_version content_sha256 manifest_sha256 meta_format_version bundle_format_version manifest_schema_version; do
    case "$req" in
      source) [[ -n "$CM_SOURCE" ]] || _cm_die "missing source" ;;
      debian_version) [[ -n "$CM_DEBIAN_VERSION" ]] || _cm_die "missing debian_version" ;;
      content_sha256) [[ -n "$CM_CONTENT_SHA256" ]] || _cm_die "missing content_sha256" ;;
      manifest_sha256) [[ -n "$CM_MANIFEST_SHA256" ]] || _cm_die "missing manifest_sha256" ;;
      meta_format_version) [[ -n "$CM_META_FORMAT_VERSION" ]] || _cm_die "missing meta_format_version" ;;
      bundle_format_version) [[ -n "$CM_BUNDLE_FORMAT_VERSION" ]] || _cm_die "missing bundle_format_version" ;;
      manifest_schema_version) [[ -n "$CM_MANIFEST_SCHEMA_VERSION" ]] || _cm_die "missing manifest_schema_version" ;;
    esac
  done
  [[ "$CM_SOURCE" =~ $RE_CM_SOURCE ]] || _cm_die "bad source"
  [[ "$CM_DEBIAN_VERSION" =~ $RE_CM_VERSION ]] || _cm_die "bad debian_version"
  [[ "$CM_CONTENT_SHA256" =~ $RE_CM_SHA ]] || _cm_die "bad content_sha256"
  [[ "$CM_MANIFEST_SHA256" =~ $RE_CM_SHA ]] || _cm_die "bad manifest_sha256"
}

verify_cache_meta_versions() {
  [[ "$CM_META_FORMAT_VERSION" == "1" ]] || _cm_die "meta_format_version != 1"
  [[ "$CM_BUNDLE_FORMAT_VERSION" == "1" ]] || _cm_die "bundle_format_version != 1"
  [[ "$CM_MANIFEST_SCHEMA_VERSION" == "1" ]] || _cm_die "manifest_schema_version != 1"
}

# verify_manifest_hash <cache_dir>  — checks source-manifest.json against CM_MANIFEST_SHA256.
verify_manifest_hash() {
  local cache_dir="$1"
  printf '%s  source-manifest.json\n' "$CM_MANIFEST_SHA256" \
    | ( cd "$cache_dir" && sha256sum -c --status - ) \
    || _cm_die "manifest_sha256 mismatch"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_cache_meta_helper.bats`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_cache_meta.sh test/test_cache_meta_helper.bats
git commit -m "feat(cache-meta): _cache_meta.sh restricted parser + version/hash verifiers"
```

### Task 2.4: `prefetch-source.sh`

**Files:**
- Create: `scripts/prefetch-source.sh`
- Test: `test/test_prefetch_source.bats`

Implements spec §3.6 + §3.6.2 (`download_artifact`) + §3.4 manifest generation via Python `json.dumps`. This is a large script; structure it as functions: `main`, `resolve_paths`, `load_lock`, `download_artifact`, `run_strong_verification` (the 8-step ordering), `write_cache`, `atomic_install` (§3.8 idempotence), `make_bundle`.

- [ ] **Step 1: Write the failing test (drift → no network)**

```bash
# test/test_prefetch_source.bats
#!/usr/bin/env bats
load helpers/bats-helper.bash

@test "prefetch: YAML/.lock.tsv drift → fails before any network" {
  tmpd="$(mktemp -d)"
  mkdir -p "$tmpd/source-lock/ocserv"
  cat > "$tmpd/source-lock/ocserv/1.5.0-1.yaml" <<'YAML'
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [snapshot]
snapshot_timestamp: "20260101T000000Z"
dsc: {name: ocserv_1.5.0-1.dsc, size: 1, sha256: "0000000000000000000000000000000000000000000000000000000000000000"}
artifacts: [{name: ocserv_1.5.0.orig.tar.xz, size: 1, sha256: "1111111111111111111111111111111111111111111111111111111111111111"}]
YAML
  # committed .lock.tsv intentionally DIFFERENT (drift)
  printf 'META\tocserv\t9.9.9-9\tsnapshot\t20260101T000000Z\t-\tx.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\n' > "$tmpd/source-lock/ocserv/1.5.0-1.lock.tsv"
  # Stub curl to PROVE it is never called.
  fakebin="$(mktemp -d)"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
echo "CURL WAS CALLED: $*" >> "$PWD/CURL_INVOKED"; exit 7
SH
  chmod +x "$fakebin/curl"
  run bash -c "cd '$tmpd' && PATH='$fakebin:$PATH' python3 '${REPO_ROOT}/scripts/read-source-lock.py' --lock '$tmpd/source-lock/ocserv/1.5.0-1.yaml' >/tmp/proj.tsv 2>/dev/null; cmp -s /tmp/proj.tsv '$tmpd/source-lock/ocserv/1.5.0-1.lock.tsv'"
  rm -rf "$tmpd" "$fakebin"
  [ "$status" -ne 0 ]   # cmp detected drift
}
```

> This test validates the drift gate at the contract level (the `cmp -s` the script itself performs). A full prefetch end-to-end test requires a real snapshot stub server and dscverify/keyrings — those are integration tests run on the prefetch node, documented in `test/test_prefetch_source.bats` as `@test "prefetch: end-to-end (integration, run on prefetch node)"` with a `skip` guard when `PREFETCH_INTTEST=1` is unset.

- [ ] **Step 2: Run test to verify it fails/passes as appropriate, then write the script**

Write `scripts/prefetch-source.sh`. Key functions (full script is long; the structure below is the complete required behavior — implement each function per spec §3.6):

```bash
#!/usr/bin/env bash
# Prefetch a Debian source package from snapshot.debian.org into a verified
# versioned cache + transport bundle. Runs ONLY on a prefetch node with
# snapshot access. Spec §3.6, §3.6.2, §3.4, §3.8, §3.9.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"
# shellcheck source=_dsc.sh
. "$SCRIPT_DIR/_dsc.sh"
# shellcheck source=_lock_tsv.sh
. "$SCRIPT_DIR/_lock_tsv.sh"
# shellcheck source=_cache_meta.sh
. "$SCRIPT_DIR/_cache_meta.sh"

REPO_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
BUILD_ROOT="$REPO_ROOT/build"
CACHE_ROOT="$BUILD_ROOT/source-cache"
BUNDLE_ROOT="$BUILD_ROOT/source-bundles"

# Dscverify fixed trust root (advisory A + review fix #4): all 4 official keyrings.
DSCVERIFY_KEYRINGS=(
  /usr/share/keyrings/debian-keyring.gpg
  /usr/share/keyrings/debian-maintainers.gpg
  /usr/share/keyrings/debian-nonupload.gpg
  /usr/share/keyrings/debian-tag2upload.pgp
)

dscverify_cmd() {
  local dsc="$1"; local args=(dscverify --no-conf --no-default-keyrings)
  local kr; for kr in "${DSCVERIFY_KEYRINGS[@]}"; do args+=(--keyring "$kr"); done
  args+=("$dsc"); "${args[@]}"
}

# download_artifact <url> <destination> <logfile>   (spec §3.6.2, curl, no retry)
download_artifact() {
  local url="$1" dest="$2" logfile="$3"
  if ! curl --fail --show-error --location --output "$dest" "$url" >"$logfile" 2>&1; then
    cat "$logfile" >&2
    return 1
  fi
}

usage() { cat >&2 <<EOF
Usage: $0 --lock <yaml> | --source <name> --debian-version <ver>
EOF
  exit 2
}

# (Implementations of load_lock, provenance, run_strong_verification, write_cache,
#  atomic_install, make_bundle follow the spec §3.6 step-by-step. Each function
#  is a direct transcription of the spec pseudocode; see the spec for the exact
#  8-step ordering in run_strong_verification and the §3.8 idempotence rules.)
main() {
  # 1. parse args (--lock XOR --source/--debian-version), resolve lock yaml path
  # 2. snapshot ∈ allowed_sources check (die otherwise)
  # 3. run read-source-lock.py to temp; cmp -s companion .lock.tsv; read_lock_tsv companion
  # 4. compute provenance (lock_sha256, pyyaml_version, dscverify_keyrings[] via _keyring_prov helper)
  # 5. download + strong verification (8 steps, spec §3.6 step 5)
  # 6. on snapshot failure: emit raw curl log, hint "change egress or retry later"
  # 7. write cache to STAGING/<name>/<version>/ (SHA256SUMS, source-manifest.json via python json.dumps, cache.meta)
  # 8. atomic_install (spec §3.8)
  # 9. make_bundle (spec §3.9: env -u TAR_OPTIONS LC_ALL=C tar --create --format=ustar --zstd --no-recursion)
  :
}

SOURCE_GUARD=1
[[ -n "${SOURCE_GUARD:-}" ]] || main "$@"
```

> **Note for the implementer:** the bodies of `load_lock`, `_keyring_prov`, `run_strong_verification`, `write_cache`, `atomic_install`, `make_bundle` are each a direct line-by-line transcription of the corresponding spec §3.6/§3.8/§3.9 pseudocode. `source-manifest.json` MUST be generated via `python3 -c "import json,sys; json.dump(...)"` (spec fix #4 implementation note), never bash string concatenation. Implement them, then add the end-to-end integration test (gated behind `PREFETCH_INTTEST=1`).

- [ ] **Step 3: Run tests**

Run: `bats test/test_prefetch_source.bats`
Expected: drift-gate test PASS; integration test SKIPs (no snapshot stub).

- [ ] **Step 4: shellcheck**

Run: `shellcheck scripts/prefetch-source.sh scripts/_dsc.sh scripts/_lock_tsv.sh scripts/_cache_meta.sh`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/prefetch-source.sh test/test_prefetch_source.bats
git commit -m "feat(prefetch): prefetch-source.sh (snapshot download + strong verify + bundle)"
```

### Task 2.5: `import-source-cache.sh`

**Files:**
- Create: `scripts/import-source-cache.sh`
- Test: `test/test_import_source_cache.bats`

Implements spec §3.7 (full 10-step flow including tar `--list --verbose` type prescan, `env -u TAR_OPTIONS`, strict sidecar parsing, cwd-independent checksum, identity closure via `cmp -s`).

- [ ] **Step 1: Write failing tests (the negative cases are unit-testable without a real bundle)**

```bash
# test/test_import_source_cache.bats
#!/usr/bin/env bats
load helpers/bats-helper.bash

# Helper to build a valid bundle from a fake cache dir, for import tests.
# Args: outdir name version dsc_sha256 [artifact:name:sha256 ...]
build_bundle() { ... }  # implemented inline in the test file using prefetch's make_bundle logic

@test "import: rejects --expected-sha256 with wrong format" {
  run bash "${REPO_ROOT}/scripts/import-source-cache.sh" --expected-sha256 nothex /tmp/x.source-cache.tar.zst
  [ "$status" -ne 0 ]
}

@test "import: tar member that is a symlink → die (prescan)" {
  # build a bundle containing a symlink member, assert import dies
  ...
}

@test "import: tar with PAX header → die" {
  ...
}

@test "import: sidecar multi-line → die" {
  ...
}

@test "import: valid bundle → atomic install" {
  # full happy path: build a valid cache + bundle via prefetch helpers, import, assert cache present + identical
  ...
}

@test "import: never calls Python/PyYAML/network" {
  # assert no python3/curl in PATH-reachable invocations during a valid import
  ...
}
```

> Each test builds a minimal bundle using the same tar incantation prefetch uses (`env -u TAR_OPTIONS LC_ALL=C tar --create --format=ustar --zstd --no-recursion`), plus the sidecar. Implement `build_bundle` inline in the test file.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_import_source_cache.bats`
Expected: FAIL (script doesn't exist).

- [ ] **Step 3: Write `scripts/import-source-cache.sh`** — direct transcription of spec §3.7 steps 1–10. Use `_lock_tsv.sh`'s `read_lock_tsv` + `write_expected_sha256sums`, `_cache_meta.sh`'s `read_cache_meta`/`verify_cache_meta_versions`/`verify_manifest_hash`, `_dsc.sh`'s `validate_dsc_metadata`. Path resolution via `REPO_ROOT`/`CACHE_ROOT`. Sidecar parsing + cwd-independent checksum exactly as spec §3.7 step 3.

- [ ] **Step 4: Run tests; shellcheck**

Run: `bats test/test_import_source_cache.bats && shellcheck scripts/import-source-cache.sh`
Expected: all PASS; no shellcheck errors.

- [ ] **Step 5: Commit**

```bash
git add scripts/import-source-cache.sh test/test_import_source_cache.bats
git commit -m "feat(import): import-source-cache.sh (untrusted bundle hardening + identity closure)"
```

### Task 2.6: Slice 2 verification

- [ ] **Step 1: Full bats suite**

Run: `make test`
Expected: all PASS. `test_fetch_source.bats` still passes (slice 2 didn't touch it).

- [ ] **Step 2: Confirm fetch-source.sh unchanged**

Run: `git diff main..HEAD -- scripts/fetch-source.sh`
Expected: empty.

---

## Slice 3 — fetch-source.sh refactor (only behavior-changing slice)

**Branch:** `feat/slice3-fetch-refactor` (off main, after slices 1+2 merge)

> Spec §4. Delete `fetch_via_snapshot_staged`, `is_509_failure`, all snapshot/timestamp/509 logic. Retain+adopt `_dsc.sh`/`_lock_tsv.sh`/`_cache_meta.sh` (delete inline copies). Implement `FETCH_SOURCE=pool|cache` with the identity closures (§4.4). All `build/` paths become repo-root-relative.

### Task 3.1: Delete snapshot/509 tests + helpers, restructure main (TDD)

**Files:**
- Modify: `scripts/fetch-source.sh`
- Modify: `test/test_fetch_source.bats`

- [ ] **Step 1: Delete the snapshot/509 tests from `test/test_fetch_source.bats`**

Remove these `@test` blocks (lines ~11-36, 196-302 in the current file): all `is_509_failure:*` tests, `main: dget success`, `main: non-509 dget failure`, `main: 509 + complete cache`, `main: 509 + partial`. Keep `validate_dsc_metadata`, `parse_dsc_artifacts` (adapt), `validate_artifact_basenames` tests. The `write_fixture_cache` helper stays (reused by cache-mode tests).

- [ ] **Step 2: Write the new failing tests for FETCH_SOURCE dispatch**

```bash
# In test/test_fetch_source.bats, replace the main() tests with:

@test "FETCH_SOURCE: unknown value → die" {
  tmprepo="$(mktemp -d)"
  ( cd "$tmprepo" && mkdir -p build && FETCH_SOURCE=bogus bash "${REPO_ROOT}/scripts/fetch-source.sh" ) >"$tmprepo/o" 2>&1 || rc=$?
  rc=${rc:-0}; rm -rf "$tmprepo"
  [ "$rc" -ne 0 ]
}

@test "FETCH_SOURCE=pool: unauth (pool not in allowed_sources) → zero-network fail" {
  # Build a lock whose allowed_sources excludes pool; assert curl never invoked + non-zero exit
  ...
}

@test "FETCH_SOURCE=cache: identity closure cmp -s failure → die" {
  # Seed a cache whose SHA256SUMS differs from .lock.tsv projection; assert die, no publish
  ...
}

@test "FETCH_SOURCE=cache: zero network (no curl/python/snapshot) → publish from cache" {
  # Seed valid versioned cache; stub curl to fail-if-called; assert publish succeeds
  ...
}

@test "FETCH_SOURCE=pool: success → publish (stub curl + dscverify + dpkg-source)" {
  ...
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bats test/test_fetch_source.bats`
Expected: FAIL (current `fetch-source.sh` still uses snapshot).

- [ ] **Step 4: Rewrite `scripts/fetch-source.sh`**

Delete: `fetch_via_snapshot_staged`, `is_509_failure`, the inline `_dsc_field`/`parse_dsc_artifacts`/`validate_artifact_basenames`/`validate_dsc_metadata` (now sourced from `_dsc.sh`), `DEBIAN_SNAPSHOT_TIMESTAMP` reads, snapshot URL construction, the snapshot-first/509-fallback `main` body. Keep: `publish_source_tree`, `publish_orig_tarball`, `cleanup_fetch_tmp`, TMP_ROOT trap. Add: `source _dsc.sh / _lock_tsv.sh / _cache_meta.sh`; repo-root-relative path resolution; `fetch_via_pool` (§4.6 8-step ordering using `download_artifact` + `dscverify` 4-keyring + `dpkg-source`); `fetch_via_cache` (§4.4 11-step identity closure); new `main` with `FETCH_SOURCE` dispatch + 3-way identity assertion. Default `FETCH_SOURCE=pool`.

(The function bodies are direct transcriptions of spec §4.3 main flow, §4.4 cache closure steps 1–11, and §4.6/§3.6-step-5 strong-verification ordering for pool.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats test/test_fetch_source.bats`
Expected: all PASS.

- [ ] **Step 6: shellcheck + full suite**

Run: `shellcheck scripts/fetch-source.sh && make test`
Expected: no errors; all tests pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/fetch-source.sh test/test_fetch_source.bats
git commit -m "feat(fetch): refactor to FETCH_SOURCE=pool|cache with identity closures"
```

### Task 3.2: Slice 3 dry-run validation

- [ ] **Step 1: Manual pool-mode dry-run (if pool reachable)**

```bash
FETCH_SOURCE=pool make fetch
```
Expected: fetches from `deb.debian.org/debian/pool/main/o/ocserv/`, passes strong verification + dscverify, publishes `build/source/ocserv-1.5.0/`.

- [ ] **Step 2: Cache-mode round-trip (prefetch→import→cache fetch)**

On the prefetch node: `scripts/prefetch-source.sh --lock source-lock/ocserv/1.5.0-1.yaml`. Transport the bundle. On the builder: `scripts/import-source-cache.sh <bundle>`. Then `FETCH_SOURCE=cache make fetch`. Expected: zero-network publish from cache.

> If a prefetch node isn't available in dev, this step is an integration check run on the real infra; document it in the PR.

---

## Slice 4 — documentation & migration

**Branch:** `feat/slice4-docs` (off main, after slice 3 merges)

### Task 4.1: `.env.example` + Makefile + README

- [ ] **Step 1: Rewrite `.env.example`** (drop `DEBIAN_SNAPSHOT_TIMESTAMP`, add the `FETCH_SOURCE=pool` block with the full spec §5.1 comment).

- [ ] **Step 2: Update `Makefile`** `fetch:` target comment to `fetch ocserv source per FETCH_SOURCE (pool|cache), locked by source-lock/`.

- [ ] **Step 3: Update `README.md`** fetch narrative to point at `source-lock/` + the runbook prefetch/import workflow.

- [ ] **Step 4: Add the env sanity test**

```bash
# test/test_env_example.bats
#!/usr/bin/env bats
load helpers/bats-helper.bash

@test ".env.example has valid FETCH_SOURCE and no DEBIAN_SNAPSHOT_TIMESTAMP" {
  [[ -f "${REPO_ROOT}/.env.example" ]]
  grep -q '^FETCH_SOURCE=pool\|^FETCH_SOURCE=cache' "${REPO_ROOT}/.env.example"
  ! grep -q 'DEBIAN_SNAPSHOT_TIMESTAMP' "${REPO_ROOT}/.env.example"
}
```

- [ ] **Step 5: Run + commit**

```bash
bats test/test_env_example.bats
git add .env.example Makefile README.md test/test_env_example.bats
git commit -m "docs: FETCH_SOURCE env + Makefile/README sync (slice 4)"
```

### Task 4.2: runbook update

- [ ] **Step 1: Edit `docs/trixie-builder-dryrun-runbook.md`** per spec §5.3: delete the snapshot-timestamp section (~L587-593) and the 509-cache-fallback section (~L595-617); delete the timestamp edit step (~L580-585); add new §4.1 "Source acquisition modes & locked identity"; add §4.1.1 "Snapshot prefetch & cache import workflow" (prefetch + bundle + manual transport + import + `FETCH_SOURCE=cache` — NO rsync/scp/credential specifics); rewrite the fetch product table row (~L657) and fetch failure triage (~L689-698) for pool/cache modes; update the Makefile comment reference.

- [ ] **Step 2: Commit**

```bash
git add docs/trixie-builder-dryrun-runbook.md
git commit -m "docs(runbook): pool/cache source modes + prefetch/import workflow"
```

### Task 4.3: Final full-suite verification

- [ ] **Step 1: Run the entire test suite**

Run: `make test`
Expected: all tests across all slices PASS.

- [ ] **Step 2: Confirm CI projection guard docs reference exists**

The CI job was added in slice 1 (Task 1.5); slice 4 only documents its semantics in the runbook. Confirm the runbook §4.1 mentions "CI verifies `.lock.tsv` byte-for-byte against the YAML projection."

- [ ] **Step 3: grep for residual snapshot/509 references in docs**

```bash
grep -rni 'snapshot.debian.org.*首选\|509 自动回退\|DEBIAN_SNAPSHOT_TIMESTAMP' docs/ README.md .env.example 2>/dev/null || echo "clean"
```
Expected: `clean`.

---

## Cross-slice notes

- **Slice ordering is mandatory:** 1 → 2 → 3 → 4. Slices 1 and 2 are pure-new (no behavior change); slice 3 is the only one touching `fetch-source.sh`; slice 4 is docs only.
- **The spec is authoritative.** Where this plan summarizes, the spec (§2.2, §3.4, §3.5.1, §3.6, §3.7, §3.8, §3.9, §4.4) has the precise field tables, regexes, step orderings, and test lists. When implementing a function, re-read the matching spec section first.
- **TDD discipline:** every task writes the failing test first, runs it to confirm failure, implements, runs to confirm pass, commits. Do not batch multiple tasks into one commit.
- **shellcheck** every new/modified `.sh` before committing.
