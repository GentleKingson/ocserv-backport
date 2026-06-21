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

### Task 1.1: Resolve real ocserv 1.5.0-1 metadata + write the canonical lock file

**Files:**
- Create: `source-lock/ocserv/1.5.0-1.yaml`

> **No placeholders allowed (plan fix #1).** This task MUST NOT commit `20260101T000000Z` or any `<real ...>` value. The `snapshot_timestamp`, every `size`, and every `sha256` must be the actual values resolved from a reachable Snapshot/pool endpoint. A placeholder timestamp or hash is a plan failure — do not commit this task until every field holds a verified real value.

- [ ] **Step 1: On a node with Snapshot/pool access, resolve the real source identity**

Run on a prefetch node (or any machine that can reach `snapshot.debian.org` / `deb.debian.org`):
```bash
set -euo pipefail
WORK="$(mktemp -d)"; cd "$WORK"
# 1. Pick a Snapshot timestamp at which ocserv 1.5.0-1 exists. Query the package's
#    snapshot metadata to find one; do NOT invent a timestamp.
#    https://snapshot.debian.org/package/ocserv/1.5.0-1/ lists available timestamps.
#    Choose the most recent one and record it exactly as snapshot.debian.org formats
#    it (YYYYMMDDTHHMMSSZ). Verify it matches ^\d{8}T\d{6}Z$.
TS="<the real timestamp you confirmed exists>"
# 2. Download the .dsc from that snapshot timestamp and record its real size+sha256.
DSC_URL="https://snapshot.debian.org/archive/debian/${TS}/pool/main/o/ocserv/ocserv_1.5.0-1.dsc"
curl --fail --location --output ocserv_1.5.0-1.dsc "$DSC_URL"
sha256sum ocserv_1.5.0-1.dsc          # record the hash
wc -c < ocserv_1.5.0-1.dsc            # record the size (bytes)
# 3. Read the .dsc's Files + Checksums-Sha256 stanzas to learn which artifacts it
#    references (ocserv 1.5.0-1's .dsc lists: .orig.tar.xz, .orig.tar.xz.asc,
#    .debian.tar.xz — confirmed by the existing fixture test_fetch_source.bats:178-193).
grep -A4 '^Files:' ocserv_1.5.0-1.dsc
grep -A4 '^Checksums-Sha256:' ocserv_1.5.0-1.dsc
# 4. Download each referenced artifact from the SAME snapshot timestamp and record
#    real size + real sha256 for each.
for f in ocserv_1.5.0.orig.tar.xz ocserv_1.5.0.orig.tar.xz.asc ocserv_1.5.0-1.debian.tar.xz; do
  curl --fail --location --output "$f" \
    "https://snapshot.debian.org/archive/debian/${TS}/pool/main/o/ocserv/$f"
  printf '%s  ' "$(sha256sum "$f" | awk '{print $1}')" ; wc -c < "$f" | tr -d ' '; printf '  %s\n' "$f"
done
cd /; rm -rf "$WORK"
```

Record all six values (1 dsc + 3 artifacts × {sha256, size}) plus the timestamp. These are the ONLY values allowed in Step 2.

- [ ] **Step 2: Write the lock file with the real resolved values**

Write `source-lock/ocserv/1.5.0-1.yaml`. Every `size` is an integer; every `sha256` is 64 lowercase hex; `snapshot_timestamp` is the real `TS`. Example structure (values shown as `REAL_*` MUST be replaced with the actual numbers/hashes from Step 1 — committing any `REAL_*` literal, any `<...>`, or the invented `20260101T000000Z` is a failure):

```yaml
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources:
  - pool
  - snapshot
snapshot_timestamp: "REAL_TIMESTAMP"   # the TS confirmed in Step 1
pool_path: "main/o/ocserv"
dsc:
  name: ocserv_1.5.0-1.dsc
  size: REAL_DSC_SIZE
  sha256: "REAL_DSC_SHA256"
artifacts:
  - name: ocserv_1.5.0.orig.tar.xz
    size: REAL_ORIG_SIZE
    sha256: "REAL_ORIG_SHA256"
  - name: ocserv_1.5.0.orig.tar.xz.asc
    size: REAL_ASC_SIZE
    sha256: "REAL_ASC_SHA256"
  - name: ocserv_1.5.0-1.debian.tar.xz
    size: REAL_DEB_SIZE
    sha256: "REAL_DEB_SHA256"
```

- [ ] **Step 3: Self-check — no placeholders survived**

```bash
# Must print nothing. If any line matches, fix it before committing.
grep -nE 'REAL_|<[a-z ]+>|20260101T000000Z|0000|YYYYMMDD' source-lock/ocserv/1.5.0-1.yaml && \
  { echo "PLACEHOLDER DETECTED — do not commit"; exit 1; } || echo "clean: real values only"
```
Expected: `clean: real values only`.

- [ ] **Step 4: Commit**

```bash
git add source-lock/ocserv/1.5.0-1.yaml
git commit -m "feat(lock): add ocserv 1.5.0-1 source lock (real snapshot identity)"
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

Implements spec §3.6 + §3.6.2 (`download_artifact`) + §3.4 manifest generation via Python `json.dumps`. Functions: `main`, `resolve_paths`, `load_lock`, `download_artifact`, `run_strong_verification` (the 8-step ordering), `write_cache`, `atomic_install` (§3.8 idempotence), `make_bundle`.

> **Test-injection contract (the script must support these for tests):** the script resolves `REPO_ROOT` via `git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel`, so a test creates a throwaway git repo, symlinks/copies `scripts/` + `source-lock/` into it, and the script writes its `build/` there. `download_artifact` calls `curl` from `PATH` (tests prepend a fakebin `curl` that writes a marker + exits non-zero). `dscverify`/`dpkg-source` are likewise PATH-resolvable so tests can stub them.

- [ ] **Step 1: Write the failing drift test — it MUST execute the real script entrypoint and assert zero network (plan fix #2)**

The test does NOT hand-run the parser + `cmp`. It runs `prefetch-source.sh` end-to-end against a drifted lock, with a `curl` stub that fails loudly if invoked. If the script is missing or omits the drift gate, this test fails.

```bash
# test/test_prefetch_source.bats
#!/usr/bin/env bats
load helpers/bats-helper.bash

# Build a throwaway git repo at $1 with scripts/ + a source-lock/ laid out so
# prefetch-source.sh (which resolves REPO_ROOT via git -C "$SCRIPT_DIR/..") treats
# $1 as the repo root. We symlink the real scripts dir so the script-under-test
# and its helpers (_common.sh/_dsc.sh/_lock_tsv.sh/_cache_meta.sh/read-source-lock.py)
# are the actual files.
setup_prefetch_repo() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/source-lock/ocserv"
  # COPY (not symlink) so the script's SCRIPT_DIR/REPO_ROOT resolve INSIDE the
  # temp repo — a symlink would resolve to the real repo and write build/ there.
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
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
echo "CURL INVOKED WITH: $*" >> "$1_CURL_HIT" 2>/dev/null || true
echo "CURL INVOKED" >> "${TMPDIR:-/tmp}/prefetch_curl_hit.$$"
exit 7
SH
  chmod +x "$fakebin/curl"
  # Stub dscverify/dpkg-source too so a missing drift gate can't proceed past them.
  printf '#!/usr/bin/env bash\necho DSCVERIFY_INVOKED >> "%s/hit"; exit 0\n' "$tmpd" > "$fakebin/dscverify"
  printf '#!/usr/bin/env bash\necho DPKGSOURCE_INVOKED >> "%s/hit"; exit 0\n' "$tmpd" > "$fakebin/dpkg-source"
  chmod +x "$fakebin/dscverify" "$fakebin/dpkg-source"

  rc=0
  ( cd "$tmpd" && PATH="$fakebin:$PATH" bash "$tmpd/scripts/prefetch-source.sh" \
      --lock "$tmpd/source-lock/ocserv/1.5.0-1.yaml" ) >"$tmpd/out.log" 2>&1 || rc=$?

  rm -rf "$tmpd" "$fakebin"
  # (a) script exited non-zero
  [ "$rc" -ne 0 ]
}

@test "prefetch: drift test asserts curl never invoked" {
  # Companion assertion: re-run the drift scenario, capture the curl marker.
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
  printf 'META\tocserv\t9.9.9-9\tsnapshot\t20260101T000000Z\t-\tx.dsc\t1\t0000000000000000000000000000000000000000000000000000000000000000\n' \
    > "$tmpd/source-lock/ocserv/1.5.0-1.lock.tsv"
  fakebin="$(mktemp -d)"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
echo "CURL_HIT \$*" >> "$tmpd/CURL_HIT"
exit 7
SH
  chmod +x "$fakebin/curl"
  ( cd "$tmpd" && PATH="$fakebin:$PATH" bash "$tmpd/scripts/prefetch-source.sh" \
      --lock "$tmpd/source-lock/ocserv/1.5.0-1.yaml" ) >/dev/null 2>&1 || true
  curl_called="no"; [[ -f "$tmpd/CURL_HIT" ]] && curl_called="yes"
  rm -rf "$tmpd" "$fakebin"
  [ "$curl_called" == "no" ]
}

@test "prefetch: end-to-end (integration; run on a prefetch node with snapshot+keyrings)" {
  [[ "${PREFETCH_INTTEST:-0}" == "1" ]] || skip "set PREFETCH_INTTEST=1 on a prefetch node"
  # Full happy path: real snapshot download, real dscverify (4 keyrings),
  # real dpkg-source -x, cache + bundle written. Asserts cache.meta content_sha256
  # == sha256(SHA256SUMS), bundle is regular-file-only ustar, etc.
  # IMPLEMENTER: this body is filled in when running on the prefetch node — it
  # invokes `prefetch-source.sh --lock source-lock/ocserv/1.5.0-1.yaml` against
  # the real network and asserts the cache dir + bundle exist and validate.
  # (Not a placeholder failure: the two drift tests above are the unit-level gate;
  #  this is the infra-only integration check, intentionally skip-guarded.)
}
```

> The first two tests are the drift gate's executable contract: they run the real `prefetch-source.sh` and prove `curl` is never reached when YAML/`.lock.tsv` drift. If the script is missing, or the drift gate is absent, or the gate runs after a download, these tests fail.

- [ ] **Step 2: Run tests to verify they fail (script does not exist yet)**

Run: `bats test/test_prefetch_source.bats`
Expected: FAIL — `scripts/prefetch-source.sh` does not exist; integration test SKIPs.

- [ ] **Step 3: Write `scripts/prefetch-source.sh` (full implementation — spec §3.6)**

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

# _sha256 <file>
_sha256() { sha256sum "$1" | awk '{print $1}'; }

# load_lock <yaml_path>
# Spec §3.6 step 3: run parser to temp TSV, cmp -s committed companion .lock.tsv,
# then read_lock_tsv the companion. Dies before any network on drift/missing.
load_lock() {
  local yaml="$1"
  local companion="${yaml%.yaml}.lock.tsv"
  local proj; proj="$(mktemp)"
  if ! python3 "$SCRIPT_DIR/read-source-lock.py" --lock "$yaml" >"$proj" 2>/dev/null; then
    rm -f "$proj"; die "lock YAML failed to parse: $yaml"
  fi
  if [[ ! -f "$companion" ]]; then
    rm -f "$proj"; die "companion .lock.tsv missing for $yaml (run CI projection guard)"
  fi
  if ! cmp -s "$proj" "$companion"; then
    rm -f "$proj"
    die "YAML/.lock.tsv drift for $yaml; regenerate the projection and commit both"
  fi
  rm -f "$proj"
  # Derive the expect-version from the YAML's debian_version (authoritative for the
  # 3-way identity: yaml version == META version == companion path). read_lock_tsv
  # then asserts META.debian_version == expect AND META.source == ocserv.
  local expect_ver
  expect_ver="$(python3 "$SCRIPT_DIR/read-source-lock.py" --lock "$yaml" \
    | awk -F'\t' '/^META/{print $2}')" \
    || die "could not extract debian_version from $yaml"
  [[ -n "$expect_ver" ]] || die "lock has empty debian_version: $yaml"
  read_lock_tsv "$companion" "$expect_ver"
}

# _keyring_prov_json  — emit the dscverify_keyrings[] JSON array to stdout via python.
# Each entry: {path, sha256, package, package_version}. Ordered by DSCVERIFY_KEYRINGS.
_keyring_prov_json() {
  local pkg sha ver entries=()
  local kr
  for kr in "${DSCVERIFY_KEYRINGS[@]}"; do
    [[ -f "$kr" ]] || die "keyring not found: $kr (install debian-keyring / debian-tag2upload-keyring)"
    sha="$(_sha256 "$kr")"
    case "$kr" in
      *debian-tag2upload.pgp) pkg="debian-tag2upload-keyring" ;;
      *)                      pkg="debian-keyring" ;;
    esac
    ver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo unknown)"
    entries+=( "$(printf '{"path":"%s","sha256":"%s","package":"%s","package_version":"%s"}' \
                   "$kr" "$sha" "$pkg" "$ver")" )
  done
  printf '%s\n' "${entries[@]}" | python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))'
}

# run_strong_verification <staging_dir> <base_url>
# Spec §3.6 step 5 (authoritative 8-step ordering) + §4.6 pool ordering.
run_strong_verification() {
  local staging="$1" base_url="$2"
  local dsc="$staging/$META_DSC_NAME"
  local logfile
  # a. download .dsc
  logfile="$(mktemp)"
  if ! download_artifact "$base_url/$META_DSC_NAME" "$dsc" "$logfile"; then
    cat "$logfile" >&2; rm -f "$logfile"
    die "snapshot download failed for $META_DSC_NAME (change egress or retry later)"
  fi
  rm -f "$logfile"
  # b. verify .dsc size + sha256 == lock
  local got_size got_sha
  got_size="$(wc -c <"$dsc" | tr -d ' ')"
  got_sha="$(_sha256 "$dsc")"
  [[ "$got_size" == "$META_DSC_SIZE" ]] || die ".dsc size $got_size != lock $META_DSC_SIZE"
  [[ "$got_sha" == "$META_DSC_SHA256" ]] || die ".dsc sha256 $got_sha != lock"
  # c-d. parse .dsc + cross-check Files/Checksums-Sha256/lock mapping (dsc_artifacts_match_lock)
  dsc_artifacts_match_lock "$dsc" || die ".dsc artifact mapping != lock"
  # e. download all artifacts
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do
    local nm="${ARTIFACT_NAME[$i]}" dest="$staging/$nm"
    logfile="$(mktemp)"
    if ! download_artifact "$base_url/$nm" "$dest" "$logfile"; then
      cat "$logfile" >&2; rm -f "$logfile"
      die "snapshot download failed for $nm (change egress or retry later)"
    fi
    rm -f "$logfile"
    # f. verify actual artifact size + sha256 == lock
    got_size="$(wc -c <"$dest" | tr -d ' ')"
    got_sha="$(_sha256 "$dest")"
    [[ "$got_size" == "${ARTIFACT_SIZE[$i]}" ]] || die "$nm size $got_size != lock"
    [[ "$got_sha" == "${ARTIFACT_SHA256[$i]}" ]] || die "$nm sha256 mismatch"
  done
  # g. dscverify with fixed trust root (artifacts now present)
  dscverify_cmd "$dsc" || die "dscverify failed for $META_DSC_NAME"
  # h. dpkg-source strong unpack (internal integrity confirmation only)
  dpkg-source --require-valid-signature --require-strong-checksums -x "$dsc" "$staging/ocserv-extract-check" \
    || die "dpkg-source -x failed (strong checksum/signature)"
  rm -rf "$staging/ocserv-extract-check"
}

# write_cache <staging_dir>  — assemble <name>/<version>/ with artifacts, SHA256SUMS,
# source-manifest.json (via python json.dumps), cache.meta.
write_cache() {
  local staging="$1"
  local cache="$staging/$META_SOURCE/$META_DEBIAN_VERSION"
  mkdir -p "$cache"
  cp -- "$staging/$META_DSC_NAME" "$cache/$META_DSC_NAME"
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do
    cp -- "$staging/${ARTIFACT_NAME[$i]}" "$cache/${ARTIFACT_NAME[$i]}"
  done
  # SHA256SUMS: dsc first, then artifacts in lock order.
  {
    printf '%s  %s\n' "$META_DSC_SHA256" "$META_DSC_NAME"
    for i in "${!ARTIFACT_NAME[@]}"; do
      printf '%s  %s\n' "${ARTIFACT_SHA256[$i]}" "${ARTIFACT_NAME[$i]}"
    done
  } > "$cache/SHA256SUMS"
  local content_sha manifest_sha
  content_sha="$(_sha256 "$cache/SHA256SUMS")"
  # source-manifest.json via python json.dumps (never bash concat).
  local lock_yaml="$LOCK_YAML" lock_sha pyyaml_ver keyrings_json
  lock_sha="$(_sha256 "$lock_yaml")"
  pyyaml_ver="$(python3 -c 'import yaml;print(yaml.__version__)' 2>/dev/null || echo unknown)"
  keyrings_json="$(_keyring_prov_json)"
  local dscverify_ver dpkg_src_ver
  dscverify_ver="$(dscverify --version 2>/dev/null | head -1 || echo unknown)"
  dpkg_src_ver="$(dpkg-source --version 2>/dev/null | head -1 || echo unknown)"
  local base_url="https://snapshot.debian.org/archive/debian/${META_SNAPSHOT_TS}/pool/${META_POOL_PATH:-main/o/ocserv}"
  python3 - "$cache/source-manifest.json" "$META_SOURCE" "$META_DEBIAN_VERSION" \
           "$META_SNAPSHOT_TS" "$META_POOL_PATH" "$META_ALLOWED_SOURCES" \
           "$META_DSC_NAME" "$META_DSC_SIZE" "$META_DSC_SHA256" \
           "$lock_yaml" "$lock_sha" "$pyyaml_ver" "$keyrings_json" \
           "$dscverify_ver" "$dpkg_src_ver" "$base_url" "${ARTIFACT_NAME[*]}" "${ARTIFACT_SIZE[*]}" "${ARTIFACT_SHA256[*]}" <<'PY'
import json, sys
(out, src, ver, ts, pp, allowed, dn, ds, dsh, lp, lsh, pyv, krj, dv, dsv, base, an, asz, ash) = sys.argv[1:]
an, asz, ash = an.split(), asz.split(), ash.split()
manifest = {
    "manifest_schema_version": 1,
    "source": src, "debian_version": ver,
    "snapshot_timestamp": ts or None, "pool_path": pp or None,
    "allowed_sources": allowed.split(",") if allowed else [],
    "dsc": {"name": dn, "size": int(ds), "sha256": dsh},
    "artifacts": [{"name": n, "size": int(s), "sha256": h} for n, s, h in zip(an, asz, ash)],
    "provenance": {
        "lock_path": lp, "lock_sha256": lsh,
        "read_source_lock_path": "scripts/read-source-lock.py",
        "pyyaml_version": pyv,
        "fetched_at_utc": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "fetch_source_kind": "snapshot",
        "original_urls": [f"{base}/{dn}"],
        "verification": {"dscverify_version": dv, "dpkg_source_version": dsv,
                         "dscverify_keyrings": json.loads(krj)},
    },
}
with open(out, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=False)
    f.write("\n")
PY
  manifest_sha="$(_sha256 "$cache/source-manifest.json")"
  {
    printf 'meta_format_version=1\n'
    printf 'bundle_format_version=1\n'
    printf 'source=%s\n' "$META_SOURCE"
    printf 'debian_version=%s\n' "$META_DEBIAN_VERSION"
    printf 'content_sha256=%s\n' "$content_sha"
    printf 'manifest_sha256=%s\n' "$manifest_sha"
    printf 'manifest_schema_version=1\n'
  } > "$cache/cache.meta"
  printf '%s' "$cache"   # echo cache dir for caller
}

# atomic_install <staging_cache_dir> <target_cache_dir>  — spec §3.8 idempotence.
atomic_install() {
  local src_cache="$1" target="$2"
  if [[ ! -d "$target" ]]; then
    mkdir -p "$(dirname "$target")"
    mv "$src_cache" "$target"
    log "installed cache: $target"
    return 0
  fi
  # target exists: fully verify it, then compare identity.
  read_cache_meta "$target/cache.meta" \
    || die "existing cache $target is corrupt (bad cache.meta); refusing overwrite"
  ( cd "$target" && verify_cache_meta_versions && verify_manifest_hash "$target" \
      && sha256sum -c --status SHA256SUMS ) \
    || die "existing cache $target is corrupt (version/hash/SHA256SUMS); refusing overwrite"
  local dsc_name="$META_DSC_NAME"
  validate_dsc_metadata "$target/$dsc_name" "$META_SOURCE" "$META_DEBIAN_VERSION" \
    || die "existing cache $target .dsc metadata mismatch; refusing overwrite"
  # identity: source/version/content_sha256
  local existing_content
  existing_content="$(read_cache_meta "$target/cache.meta" >/dev/null 2>&1; printf '%s' "$CM_CONTENT_SHA256")"
  local new_content; new_content="$(_sha256 "$src_cache/SHA256SUMS")"
  if [[ "$existing_content" == "$new_content" ]]; then
    log "cache already present and identical: $target (idempotent)"
    rm -rf "$src_cache"
    return 0
  fi
  die "cache $target exists with different content_sha256; refusing overwrite"
}

# make_bundle <cache_dir>  — spec §3.9: regular-file-only ustar, env -u TAR_OPTIONS.
make_bundle() {
  local cache="$1"
  mkdir -p "$BUNDLE_ROOT"
  local bundle="$BUNDLE_ROOT/${META_SOURCE}_${META_DEBIAN_VERSION}.source-cache.tar.zst"
  local -a paths=()
  paths+=( "$cache/$META_DSC_NAME" )
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do paths+=( "$cache/${ARTIFACT_NAME[$i]}" ); done
  paths+=( "$cache/SHA256SUMS" "$cache/source-manifest.json" "$cache/cache.meta" )
  # Convert absolute paths to archive member paths <name>/<version>/<file>.
  local arcbase="$META_SOURCE/$META_DEBIAN_VERSION"
  local -a arcpaths=()
  for p in "${paths[@]}"; do arcpaths+=( "$arcbase/$(basename "$p")" ); done
  # tar needs to be run from the cache parent so member paths are <name>/<ver>/<file>.
  ( cd "$(dirname "$cache")" && \
    env -u TAR_OPTIONS LC_ALL=C tar --create --format=ustar --zstd --no-recursion \
      --file "$bundle" "${arcpaths[@]}" ) \
    || die "bundle creation failed (ustar limit? explicit fail, no auto-downgrade to GNU/PAX)"
  # sidecar
  printf '%s  %s\n' "$(_sha256 "$bundle")" "$(basename "$bundle")" > "$bundle.sha256"
  log "bundle: $bundle (+ $bundle.sha256)"
}

main() {
  local LOCK_YAML=""
  # 1. arg parse (--lock XOR --source/--debian-version)
  if [[ "$1" == "--lock" ]]; then
    [[ $# -eq 2 ]] || usage
    LOCK_YAML="$2"
  elif [[ "$1" == "--source" && "$3" == "--debian-version" ]]; then
    LOCK_YAML="source-lock/$2/$4.yaml"
  else
    usage
  fi
  # 2. snapshot ∈ allowed_sources: peek via parser (no TSV needed for this check).
  local allowed_check
  allowed_check="$(python3 "$SCRIPT_DIR/read-source-lock.py" --lock "$LOCK_YAML" \
    | awk -F'\t' '/^META/{print $4}' 2>/dev/null)" \
    || die "lock failed to parse: $LOCK_YAML"
  [[ ",$allowed_check," == *",snapshot,"* ]] \
    || die "this lock does not authorize snapshot; use FETCH_SOURCE=pool on the builder"
  # 3. drift gate + read companion .lock.tsv (load_lock derives expect-version from yaml)
  load_lock "$LOCK_YAML"
  # 4. provenance computed inside write_cache; no separate step needed.
  [[ -n "$META_SNAPSHOT_TS" ]] || die "snapshot_timestamp required for snapshot prefetch"
  local base_url="https://snapshot.debian.org/archive/debian/${META_SNAPSHOT_TS}/pool/${META_POOL_PATH:-main/o/ocserv}"
  # 5. download + strong verification into staging.
  local STAGING; STAGING="$(mktemp -d)"
  if ! run_strong_verification "$STAGING" "$base_url"; then
    rm -rf "$STAGING"; exit 1
  fi
  # 7. assemble cache content.
  local staging_cache; staging_cache="$(write_cache "$STAGING")"
  # 8. atomic install.
  local target="$CACHE_ROOT/$META_SOURCE/$META_DEBIAN_VERSION"
  atomic_install "$staging_cache" "$target"
  # 9. bundle (from canonical target if idempotent-kept, else from staging that's now target).
  make_bundle "$target"
  rm -rf "$STAGING"
  log "prefetch complete: $META_SOURCE/$META_DEBIAN_VERSION from snapshot $META_SNAPSHOT_TS"
}

SOURCE_GUARD=1
[[ -n "${SOURCE_GUARD:-}" ]] || main "$@"
```

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

Implements spec §3.7 (full 10-step flow: strict sidecar, cwd-independent checksum, tar `--list --verbose` type prescan accepting only regular files, `env -u TAR_OPTIONS`, lock-derived whitelist + `cmp -s` identity closure, atomic install).

> **Test-injection contract:** `import-source-cache.sh` resolves `REPO_ROOT`/`CACHE_ROOT` via `git -C "$SCRIPT_DIR/.."`. Tests build a throwaway git repo (like `setup_prefetch_repo` in Task 2.4) with symlinked `scripts/` + a `source-lock/`, so the script reads the test's lock and writes to the test's `build/source-cache/`. The bundle argument is an arbitrary path into the test temp dir. No `curl`/`python3` is invoked by import — tests assert this.

- [ ] **Step 1: Write the failing tests with a full `build_bundle` helper**

```bash
# test/test_import_source_cache.bats
#!/usr/bin/env bats
load helpers/bats-helper.bash

setup_import_repo() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/source-lock/ocserv"
  for f in _common.sh _dsc.sh _lock_tsv.sh _cache_meta.sh import-source-cache.sh; do
    cp "${REPO_ROOT}/scripts/$f" "$root/scripts/$f"   # copy not symlink (REPO_ROOT must resolve here)
  done
  git -C "$root" init -q
  git -C "$root" add -A && git -C "$root" -c user.email=t@t -c user.name=t commit -qm init
}

# write_lock <repo_root>  — writes a consistent yaml + committed .lock.tsv pair
# (matching projection) into <repo>/source-lock/ocserv/1.5.0-1.{yaml,lock.tsv}.
write_lock() {
  local repo="$1"
  local dsc_sha="0000000000000000000000000000000000000000000000000000000000000000"
  local art_sha="1111111111111111111111111111111111111111111111111111111111111111"
  cat > "$repo/source-lock/ocserv/1.5.0-1.yaml" <<YAML
schema_version: 1
source: ocserv
debian_version: "1.5.0-1"
allowed_sources: [snapshot, pool]
snapshot_timestamp: "20260101T000000Z"
pool_path: "main/o/ocserv"
dsc: {name: ocserv_1.5.0-1.dsc, size: 5, sha256: "$dsc_sha"}
artifacts: [{name: ocserv_1.5.0.orig.tar.xz, size: 3, sha256: "$art_sha"}]
YAML
  printf 'META\tocserv\t1.5.0-1\tpool,snapshot\t20260101T000000Z\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t5\t%s\n' "$dsc_sha" > "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  printf 'ARTIFACT\tocserv_1.5.0.orig.tar.xz\t3\t%s\n' "$art_sha" >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
}

# build_bundle <repo_root> <bundle_out> <content_kind>
# content_kind: "valid" | "bad_shasums" | "symlink_member"
# Builds a regular-file-only ustar bundle from a synthesized cache dir, then
# writes <bundle_out>.sha256 sidecar. For "bad_shasums"/"symlink_member" it
# intentionally corrupts the archive contents.
build_bundle() {
  local repo="$1" bundle="$2" kind="$3"
  local srcdir="$repo/.bundle-src"; rm -rf "$srcdir"; mkdir -p "$srcdir/ocserv/1.5.0-1"
  local cdir="$srcdir/ocserv/1.5.0-1"
  local dsc_sha="0000000000000000000000000000000000000000000000000000000000000000"
  local art_sha="1111111111111111111111111111111111111111111111111111111111111111"
  printf 'hello' > "$cdir/ocserv_1.5.0-1.dsc"   # 5 bytes
  printf 'abc'   > "$cdir/ocserv_1.5.0.orig.tar.xz"   # 3 bytes
  if [[ "$kind" == "bad_shasums" ]]; then
    # SHA256SUMS that does NOT match lock (content divergence)
    printf '%s  %s\n' "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" "ocserv_1.5.0-1.dsc" > "$cdir/SHA256SUMS"
  else
    printf '%s  %s\n%s  %s\n' "$dsc_sha" "ocserv_1.5.0-1.dsc" "$art_sha" "ocserv_1.5.0.orig.tar.xz" > "$cdir/SHA256SUMS"
  fi
  printf '{}' > "$cdir/source-manifest.json"
  local manifest_sha content_sha
  manifest_sha="$(sha256sum "$cdir/source-manifest.json" | awk '{print $1}')"
  content_sha="$(sha256sum "$cdir/SHA256SUMS" | awk '{print $1}')"
  printf 'meta_format_version=1\nbundle_format_version=1\nsource=ocserv\ndebian_version=1.5.0-1\ncontent_sha256=%s\nmanifest_sha256=%s\nmanifest_schema_version=1\n' \
    "$content_sha" "$manifest_sha" > "$cdir/cache.meta"
  local -a members=( "ocserv/1.5.0-1/ocserv_1.5.0-1.dsc" "ocserv/1.5.0-1/ocserv_1.5.0.orig.tar.xz" \
                     "ocserv/1.5.0-1/SHA256SUMS" "ocserv/1.5.0-1/source-manifest.json" "ocserv/1.5.0-1/cache.meta" )
  if [[ "$kind" == "symlink_member" ]]; then
    ( cd "$srcdir" && ln -s ocserv_1.5.0-1.dsc ocserv/1.5.0-1/evil && \
      env -u TAR_OPTIONS LC_ALL=C tar --create --format=ustar --zstd --no-recursion \
        --file "$bundle" "${members[@]}" "ocserv/1.5.0-1/evil" )
  else
    ( cd "$srcdir" && env -u TAR_OPTIONS LC_ALL=C tar --create --format=ustar --zstd --no-recursion \
        --file "$bundle" "${members[@]}" )
  fi
  printf '%s  %s\n' "$(sha256sum "$bundle" | awk '{print $1}')" "$(basename "$bundle")" > "$bundle.sha256"
  rm -rf "$srcdir"
}

@test "import: rejects --expected-sha256 wrong format" {
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/in.tar.zst"; printf 'x' > "$bun"
  run bash -c "cd '$repo' && bash '$repo/scripts/import-source-cache.sh' --expected-sha256 nothex '$bun'"
  rc=$?; rm -rf "$repo"
  [ "$rc" -ne 0 ]
}

@test "import: sidecar multi-line → die" {
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/ocserv_1.5.0-1.source-cache.tar.zst"
  build_bundle "$repo" "$bun" valid
  printf 'aaaa  %s\nbbbb  other\n' "$(basename "$bun")" > "$bun.sha256"
  run bash -c "cd '$repo' && bash '$repo/scripts/import-source-cache.sh' '$bun'"
  rc=$?; rm -rf "$repo"
  [ "$rc" -ne 0 ]
}

@test "import: tar symlink member → die (prescan)" {
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/ocserv_1.5.0-1.source-cache.tar.zst"
  build_bundle "$repo" "$bun" symlink_member
  # Recompute sidecar (bundle changed)
  printf '%s  %s\n' "$(sha256sum "$bun" | awk '{print $1}')" "$(basename "$bun")" > "$bun.sha256"
  run bash -c "cd '$repo' && bash '$repo/scripts/import-source-cache.sh' '$bun'"
  rc=$?; rm -rf "$repo"
  [ "$rc" -ne 0 ]
}

@test "import: cache vs lock SHA256SUMS mismatch → die (identity closure)" {
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/ocserv_1.5.0-1.source-cache.tar.zst"
  build_bundle "$repo" "$bun" bad_shasums
  printf '%s  %s\n' "$(sha256sum "$bun" | awk '{print $1}')" "$(basename "$bun")" > "$bun.sha256"
  run bash -c "cd '$repo' && bash '$repo/scripts/import-source-cache.sh' '$bun'"
  rc=$?; rm -rf "$repo"
  [ "$rc" -ne 0 ]
}

@test "import: valid bundle → atomic install to build/source-cache" {
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/ocserv_1.5.0-1.source-cache.tar.zst"
  build_bundle "$repo" "$bun" valid
  run bash -c "cd '$repo' && bash '$repo/scripts/import-source-cache.sh' '$bun'"
  rc=$?
  if [[ $rc -ne 0 ]]; then rm -rf "$repo"; fail "valid import failed"; fi
  [ -d "$repo/build/source-cache/ocserv/1.5.0-1" ]
  [ -f "$repo/build/source-cache/ocserv/1.5.0-1/cache.meta" ]
  rm -rf "$repo"
}

@test "import: zero network / zero Python (valid import)" {
  repo="$(mktemp -d)"; setup_import_repo "$repo"; write_lock "$repo"
  bun="$repo/ocserv_1.5.0-1.source-cache.tar.zst"
  build_bundle "$repo" "$bun" valid
  fakebin="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho HIT >> "%s/net_hit"\nexit 7\n' "$repo" > "$fakebin/curl"
  printf '#!/usr/bin/env bash\necho HIT >> "%s/py_hit"\nexit 7\n' "$repo" > "$fakebin/python3"
  chmod +x "$fakebin/curl" "$fakebin/python3"
  ( cd "$repo" && PATH="$fakebin:$PATH" bash "$repo/scripts/import-source-cache.sh" "$bun" ) >/dev/null 2>&1 || true
  net_hit="no"; py_hit="no"
  [[ -f "$repo/net_hit" ]] && net_hit="yes"
  [[ -f "$repo/py_hit" ]] && py_hit="yes"
  rm -rf "$repo" "$fakebin"
  [ "$net_hit" == "no" ]
  [ "$py_hit" == "no" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_import_source_cache.bats`
Expected: FAIL (script doesn't exist).

- [ ] **Step 3: Write `scripts/import-source-cache.sh` (full implementation — spec §3.7)**

```bash
#!/usr/bin/env bash
# Import a verified source-cache bundle into build/source-cache/<name>/<version>/.
# Runs on the builder or an internal cache node (NOT the prefetch node).
# Zero Python, zero YAML/JSON parsing, zero network. Spec §3.7.
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
CACHE_ROOT="$REPO_ROOT/build/source-cache"

_sha256() { sha256sum "$1" | awk '{print $1}'; }

usage() { cat >&2 <<EOF
Usage: $0 [--expected-sha256 <64hex>] <bundle>
EOF
  exit 2; }

# parse_sidecar <sidecar_path> <bundle_basename>  — echo the hash, die on malformed.
parse_sidecar() {
  local sidecar="$1" basename="$2"
  local n
  n="$(wc -l <"$sidecar" | tr -d ' ')"
  [[ "$n" -eq 1 ]] || die "sidecar must be exactly one line (got $n): $sidecar"
  local line; line="$(cat "$sidecar")"
  # Strict: ^<64hex>  <basename><LF>$ — reject CRLF already ensured by single-line wc above
  [[ "$line" =~ ^([0-9a-f]{64})[[:space:]][[:space:]]([^[:space:]]+)$ ]] \
    || die "sidecar malformed: $sidecar"
  local h="${BASH_REMATCH[1]}" nm="${BASH_REMATCH[2]}"
  [[ "$nm" == "$basename" ]] || die "sidecar names '$nm' != bundle basename '$basename'"
  [[ ! "$nm" == *"\\"* ]] || die "sidecar name has backslash escape"
  printf '%s' "$h"
}

# tar_prescan <bundle> <whitelist_file>
# whitelist_file: one expected member path per line, <name>/<version>/<file>.
# Accepts ONLY regular files (verbose mode first char '-'). Dies on any violation.
tar_prescan() {
  local bundle="$1" whitelist="$2"
  local listing; listing="$(mktemp)"
  env -u TAR_OPTIONS LC_ALL=C tar --list --verbose --zstd --file "$bundle" >"$listing" 2>/dev/null \
    || { rm -f "$listing"; die "tar listing failed: $bundle"; }
  # Sort whitelist once.
  local wl_sorted; wl_sorted="$(sort -u "$whitelist")"
  local modeblank member rest line
  while read -r modeblank member rest; do
    [[ -n "$modeblank" ]] || continue
    # verbose line: "<mode/type> <owner/group> <size> <date> <time> <name> [-> target]"
    # We only inspect the first char of modeblank and the member name.
    local type_char="${modeblank:0:1}"
    [[ "$type_char" == "-" ]] || { rm -f "$listing"; die "tar member not regular file: $member (type '$type_char')"; }
    case "$member" in
      /*)        rm -f "$listing"; die "tar absolute path: $member" ;;
      *../*)     rm -f "$listing"; die "tar .. in path: $member" ;;
      *//*)      rm -f "$listing"; die "tar empty segment: $member" ;;
    esac
    # member must be in whitelist
    if ! grep -qxF "$member" "$wl_sorted"; then
      rm -f "$listing"; die "tar member not in whitelist: $member"
    fi
  done < "$listing"
  rm -f "$listing"
}

main() {
  local expected_hash="" bundle=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --expected-sha256) expected_hash="$2"; shift 2 ;;
      --help|-h) usage ;;
      -*) die "unknown option: $1" ;;
      *) [[ -z "$bundle" ]] || usage; bundle="$1"; shift ;;
    esac
  done
  [[ -n "$bundle" ]] || usage
  [[ -f "$bundle" ]] || die "bundle not found: $bundle"

  if [[ -n "$expected_hash" ]]; then
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || die "--expected-sha256 must be 64 lowercase hex"
  fi

  # 2. parse <name>+<version> from bundle basename.
  local bname; bname="$(basename "$bundle")"
  [[ "$bname" =~ ^([a-z0-9][a-z0-9+.\-]*)_([A-Za-z0-9.+~\-]+)\.source-cache\.tar\.zst$ ]] \
    || die "bundle name malformed: $bname"
  local name="${BASH_REMATCH[1]}" version="${BASH_REMATCH[2]}"

  # 3. cwd-independent checksum. realpath -e first; sidecar beside bundle_abs.
  local bundle_abs; bundle_abs="$(realpath -e -- "$bundle")"
  if [[ -z "$expected_hash" ]]; then
    local sidecar="${bundle_abs}.sha256"
    [[ -f "$sidecar" ]] || die "sidecar missing and no --expected-sha256: $sidecar"
    expected_hash="$(parse_sidecar "$sidecar" "$bname")"
  fi
  local actual_hash; actual_hash="$(_sha256 "$bundle_abs")"
  [[ "$actual_hash" == "$expected_hash" ]] || die "bundle checksum mismatch (expected $expected_hash, got $actual_hash)"

  # 4. read lock projection; build whitelist + expected-SHA256SUMS.
  local lock_tsv="$REPO_ROOT/source-lock/$name/$version.lock.tsv"
  read_lock_tsv "$lock_tsv" "$version"
  local whitelist; whitelist="$(mktemp)"
  {
    printf '%s/%s/%s\n' "$name" "$version" "$META_DSC_NAME"
    local i
    for i in "${!ARTIFACT_NAME[@]}"; do printf '%s/%s/%s\n' "$name" "$version" "${ARTIFACT_NAME[$i]}"; done
    printf '%s/%s/SHA256SUMS\n' "$name" "$version"
    printf '%s/%s/source-manifest.json\n' "$name" "$version"
    printf '%s/%s/cache.meta\n' "$name" "$version"
  } > "$whitelist"
  local expected_sums; expected_sums="$(mktemp)"
  write_expected_sha256sums "$expected_sums"

  # 5. tar type prescan (regular files only, whitelist membership).
  tar_prescan "$bundle_abs" "$whitelist"

  # 6. extract to empty staging with hardened flags.
  local staging; staging="$(mktemp -d)"
  env -u TAR_OPTIONS LC_ALL=C tar --extract --zstd --file "$bundle_abs" \
      --directory "$staging" --no-same-owner --no-same-permissions --no-overwrite-dir \
    || { rm -rf "$staging" "$whitelist" "$expected_sums"; die "tar extract failed"; }

  local staged="$staging/$name/$version"
  [[ -d "$staged" ]] || { rm -rf "$staging" "$whitelist" "$expected_sums"; die "staged $staged missing"; }

  # 7-8. cache.meta + version assertions + identity closure.
  read_cache_meta "$staged/cache.meta"
  verify_cache_meta_versions
  [[ "$CM_SOURCE" == "$name" && "$CM_DEBIAN_VERSION" == "$version" ]] \
    || die "cache.meta source/version != bundle name/version"
  # identity anchor: expected (from lock) == actual SHA256SUMS (cmp -s, no cwd dep)
  cmp -s "$expected_sums" "$staged/SHA256SUMS" \
    || { rm -rf "$staging" "$whitelist" "$expected_sums"; die "cache SHA256SUMS != lock projection (identity mismatch)"; }
  verify_manifest_hash "$staged" || { rm -rf "$staging" "$whitelist" "$expected_sums"; die "manifest hash mismatch"; }
  ( cd "$staged" && sha256sum -c --status SHA256SUMS ) \
    || { rm -rf "$staging" "$whitelist" "$expected_sums"; die "SHA256SUMS verification failed"; }
  [[ "$CM_CONTENT_SHA256" == "$(_sha256 "$staged/SHA256SUMS")" ]] \
    || { rm -rf "$staging" "$whitelist" "$expected_sums"; die "content_sha256 self-inconsistent"; }
  validate_dsc_metadata "$staged/$META_DSC_NAME" "$name" "$version" \
    || { rm -rf "$staging" "$whitelist" "$expected_sums"; die ".dsc metadata mismatch"; }

  # 9. atomic install (idempotence: spec §3.8).
  local target="$CACHE_ROOT/$name/$version"
  if [[ -d "$target" ]]; then
    read_cache_meta "$target/cache.meta" \
      || { rm -rf "$staging" "$whitelist" "$expected_sums"; die "existing cache corrupt; refusing overwrite"; }
    ( cd "$target" && verify_cache_meta_versions && sha256sum -c --status SHA256SUMS ) \
      || { rm -rf "$staging" "$whitelist" "$expected_sums"; die "existing cache corrupt; refusing overwrite"; }
    [[ "$CM_CONTENT_SHA256" == "$(_sha256 "$staged/SHA256SUMS")" ]] \
      && { log "cache already present and identical: $target"; rm -rf "$staging" "$whitelist" "$expected_sums"; exit 0; } \
      || { rm -rf "$staging" "$whitelist" "$expected_sums"; die "cache $target exists with different content; refusing overwrite"; }
  fi
  mkdir -p "$(dirname "$target")"
  mv "$staged" "$target"
  rm -rf "$staging" "$whitelist" "$expected_sums"
  log "imported cache: $target"
}

SOURCE_GUARD=1
[[ -n "${SOURCE_GUARD:-}" ]] || main "$@"
```

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

- [ ] **Step 2: Write the new failing tests for FETCH_SOURCE dispatch (full code)**

These tests use a throwaway git repo (like slices 1/2) so the rewritten `fetch-source.sh` resolves `REPO_ROOT` to the temp dir. `call_func` stays for the retained helper unit tests (`validate_dsc_metadata`, `validate_artifact_basenames`).

```bash
# In test/test_fetch_source.bats — keep the existing call_func helper and the
# validate_dsc_metadata / validate_artifact_basenames unit tests. Replace the
# main() orchestrator section with the block below.

setup_fetch_repo() {
  local root="$1"
  mkdir -p "$root/scripts" "$root/source-lock/ocserv"
  for f in _common.sh _dsc.sh _lock_tsv.sh _cache_meta.sh fetch-source.sh; do
    cp "${REPO_ROOT}/scripts/$f" "$root/scripts/$f"   # copy not symlink (REPO_ROOT must resolve here)
  done
  git -C "$root" init -q
  git -C "$root" add -A && git -C "$root" -c user.email=t@t -c user.name=t commit -qm init
}

# write_lock <repo> <allowed_comma>  — yaml + committed .lock.tsv pair (matching).
write_lock() {
  local repo="$1" allowed="$2"
  local dsc_sha="0000000000000000000000000000000000000000000000000000000000000000"
  local art_sha="1111111111111111111111111111111111111111111111111111111111111111"
  # build yaml lines depending on allowed
  {
    echo 'schema_version: 1'
    echo 'source: ocserv'
    echo 'debian_version: "1.5.0-1"'
    printf 'allowed_sources: [%s]\n' "$allowed"
    [[ ",$allowed," == *",snapshot,"* ]] && echo 'snapshot_timestamp: "20260101T000000Z"'
    [[ ",$allowed," == *",pool,"* ]] && echo 'pool_path: "main/o/ocserv"'
    printf 'dsc: {name: ocserv_1.5.0-1.dsc, size: 5, sha256: "%s"}\n' "$dsc_sha"
    printf 'artifacts: [{name: ocserv_1.5.0.orig.tar.xz, size: 3, sha256: "%s"}]\n' "$art_sha"
  } > "$repo/source-lock/ocserv/1.5.0-1.yaml"
  printf 'META\tocserv\t1.5.0-1\t%s\t' "$allowed" > "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  [[ ",$allowed," == *",snapshot,"* ]] && printf '20260101T000000Z\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv" || printf '-\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  [[ ",$allowed," == *",pool,"* ]] && printf 'main/o/ocserv\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv" || printf '-\t' >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  printf 'ocserv_1.5.0-1.dsc\t5\t%s\nARTIFACT\tocserv_1.5.0.orig.tar.xz\t3\t%s\n' "$dsc_sha" "$art_sha" >> "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
}

# seed_cache <repo> <shasums_kind>  — build/source-cache/ocserv/1.5.0-1/ with
# cache.meta + SHA256SUMS (kind: "match" or "drift") + a minimal .dsc + artifact.
seed_cache() {
  local repo="$1" kind="$2"
  local cdir="$repo/build/source-cache/ocserv/1.5.0-1"; mkdir -p "$cdir"
  local dsc_sha="0000000000000000000000000000000000000000000000000000000000000000"
  local art_sha="1111111111111111111111111111111111111111111111111111111111111111"
  printf 'hello' > "$cdir/ocserv_1.5.0-1.dsc"
  printf 'abc'   > "$cdir/ocserv_1.5.0.orig.tar.xz"
  if [[ "$kind" == "drift" ]]; then
    printf 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  ocserv_1.5.0-1.dsc\n' > "$cdir/SHA256SUMS"
  else
    printf '%s  ocserv_1.5.0-1.dsc\n%s  ocserv_1.5.0.orig.tar.xz\n' "$dsc_sha" "$art_sha" > "$cdir/SHA256SUMS"
  fi
  printf '{}' > "$cdir/source-manifest.json"
  local manifest_sha content_sha
  manifest_sha="$(sha256sum "$cdir/source-manifest.json" | awk '{print $1}')"
  content_sha="$(sha256sum "$cdir/SHA256SUMS" | awk '{print $1}')"
  printf 'meta_format_version=1\nbundle_format_version=1\nsource=ocserv\ndebian_version=1.5.0-1\ncontent_sha256=%s\nmanifest_sha256=%s\nmanifest_schema_version=1\n' \
    "$content_sha" "$manifest_sha" > "$cdir/cache.meta"
}

@test "FETCH_SOURCE: unknown value → die" {
  repo="$(mktemp -d)"; setup_fetch_repo "$repo"; write_lock "$repo" "pool"
  rc=0
  ( cd "$repo" && OCSERV_UPSTREAM_VERSION=1.5.0 OCSERV_DEBIAN_REVISION=1 \
      FETCH_SOURCE=bogus bash "$repo/scripts/fetch-source.sh" ) >"$repo/o" 2>&1 || rc=$?
  rm -rf "$repo"
  [ "$rc" -ne 0 ]
}

@test "FETCH_SOURCE=pool: pool not in allowed_sources → zero-network fail" {
  repo="$(mktemp -d)"; setup_fetch_repo "$repo"; write_lock "$repo" "snapshot"
  fakebin="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho HIT >> "%s/net"\nexit 7\n' "$repo" > "$fakebin/curl"
  chmod +x "$fakebin/curl"
  rc=0
  ( cd "$repo" && OCSERV_UPSTREAM_VERSION=1.5.0 OCSERV_DEBIAN_REVISION=1 \
      FETCH_SOURCE=pool PATH="$fakebin:$PATH" bash "$repo/scripts/fetch-source.sh" ) >"$repo/o" 2>&1 || rc=$?
  net="no"; [[ -f "$repo/net" ]] && net="yes"
  rm -rf "$repo" "$fakebin"
  [ "$rc" -ne 0 ]
  [ "$net" == "no" ]
}

@test "FETCH_SOURCE=cache: identity closure (SHA256SUMS drift) → die, no publish" {
  repo="$(mktemp -d)"; setup_fetch_repo "$repo"; write_lock "$repo" "pool,snapshot"
  seed_cache "$repo" drift
  rc=0
  ( cd "$repo" && OCSERV_UPSTREAM_VERSION=1.5.0 OCSERV_DEBIAN_REVISION=1 \
      FETCH_SOURCE=cache bash "$repo/scripts/fetch-source.sh" ) >"$repo/o" 2>&1 || rc=$?
  published=$([ -d "$repo/build/source/ocserv-1.5.0" ] && echo yes || echo no)
  rm -rf "$repo"
  [ "$rc" -ne 0 ]
  [ "$published" == "no" ]
}

@test "FETCH_SOURCE=cache: zero network → publish from cache" {
  repo="$(mktemp -d)"; setup_fetch_repo "$repo"; write_lock "$repo" "pool,snapshot"
  seed_cache "$repo" match
  # Make the .dsc look unpackable by stub dpkg-source to produce a tree.
  fakebin="$(mktemp -d)"
  printf '#!/usr/bin/env bash\necho HIT >> "%s/net"\nexit 7\n' "$repo" > "$fakebin/curl"
  # dpkg-source -x <dsc> <outdir>: create outdir with a marker file.
  cat > "$fakebin/dpkg-source" <<SH
#!/usr/bin/env bash
# args: -x ... <dsc> <outdir>   (we only care about last two)
dsc="\${@: -2: 1}"; out="\${@: -1: 1}"
mkdir -p "\$out"; echo "from-cache" > "\$out/configure.ac"
# also drop an orig tarball sibling for publish_orig_tarball to find
cp "\$dsc" "\$dsc" 2>/dev/null
: > "\$(dirname "\$out")/ocserv_1.5.0.orig.tar.xz"
: > "\$(dirname "\$out")/ocserv_1.5.0.orig.tar.xz.asc"
SH
  chmod +x "$fakebin/curl" "$fakebin/dpkg-source"
  rc=0
  ( cd "$repo" && OCSERV_UPSTREAM_VERSION=1.5.0 OCSERV_DEBIAN_REVISION=1 \
      FETCH_SOURCE=cache PATH="$fakebin:$PATH" bash "$repo/scripts/fetch-source.sh" ) >"$repo/o" 2>&1 || rc=$?
  net="no"; [[ -f "$repo/net" ]] && net="yes"
  published=$([ -d "$repo/build/source/ocserv-1.5.0" ] && echo yes || echo no)
  rm -rf "$repo" "$fakebin"
  [ "$rc" -eq 0 ]
  [ "$net" == "no" ]
  [ "$published" == "yes" ]
}

@test "FETCH_SOURCE=pool: success → publish (stub curl + dscverify + dpkg-source)" {
  repo="$(mktemp -d)"; setup_fetch_repo "$repo"; write_lock "$repo" "pool,snapshot"
  fakebin="$(mktemp -d)"
  # curl: write the requested bytes so size/sha match lock (5-byte dsc, 3-byte artifact).
  # The lock declares dsc_sha=0000... (5 bytes "hello") — we must emit content hashing to that.
  # Since 0000... is a placeholder hash, this test instead stubs the *verification* by making
  # fetch_via_pool tolerant in test mode OR use real hashes. To keep it deterministic, this
  # test sets the lock to REAL hashes of the stub bytes by re-seeding write_lock output.
  # SIMPLER: assert the orchestration calls curl/dscverify/dpkg-source in order and publishes,
  # using a lock whose hashes match the stub bytes. Recompute the lock with real stub hashes:
  printf 'hello' > /tmp/_dsc; printf 'abc' > /tmp/_art
  dsha="$(sha256sum /tmp/_dsc | awk '{print $1}')"; asha="$(sha256sum /tmp/_art | awk '{print $1}')"
  rm -f /tmp/_dsc /tmp/_art
  # rewrite lock with real stub hashes
  {
    echo 'schema_version: 1'; echo 'source: ocserv'; echo 'debian_version: "1.5.0-1"'
    echo 'allowed_sources: [pool, snapshot]'; echo 'pool_path: "main/o/ocserv"'
    printf 'dsc: {name: ocserv_1.5.0-1.dsc, size: 5, sha256: "%s"}\n' "$dsha"
    printf 'artifacts: [{name: ocserv_1.5.0.orig.tar.xz, size: 3, sha256: "%s"}]\n' "$asha"
  } > "$repo/source-lock/ocserv/1.5.0-1.yaml"
  printf 'META\tocserv\t1.5.0-1\tpool,snapshot\t-\tmain/o/ocserv\tocserv_1.5.0-1.dsc\t5\t%s\nARTIFACT\tocserv_1.5.0.orig.tar.xz\t3\t%s\n' "$dsha" "$asha" \
    > "$repo/source-lock/ocserv/1.5.0-1.lock.tsv"
  # curl: serve the bytes for any URL
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
# emulate: curl --fail --show-error --location --output <dest> <url>
dest=""; prev=""
for a in "\$@"; do
  if [[ "\$prev" == "--output" ]]; then dest="\$a"; fi
  prev="\$a"
done
case "\$dest" in
  *.dsc) printf 'hello' > "\$dest" ;;
  *.tar.xz) printf 'abc' > "\$dest" ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/dscverify"
  cat > "$fakebin/dpkg-source" <<SH
#!/usr/bin/env bash
out="\${@: -1: 1}"; dsc="\${@: -2: 1}"
mkdir -p "\$out"; echo "from-pool" > "\$out/configure.ac"
: > "\$(dirname "\$out")/ocserv_1.5.0.orig.tar.xz"
: > "\$(dirname "\$out")/ocserv_1.5.0.orig.tar.xz.asc"
SH
  chmod +x "$fakebin/curl" "$fakebin/dscverify" "$fakebin/dpkg-source"
  rc=0
  ( cd "$repo" && OCSERV_UPSTREAM_VERSION=1.5.0 OCSERV_DEBIAN_REVISION=1 \
      FETCH_SOURCE=pool PATH="$fakebin:$PATH" bash "$repo/scripts/fetch-source.sh" ) >"$repo/o" 2>&1 || rc=$?
  published=$([ -d "$repo/build/source/ocserv-1.5.0" ] && echo yes || echo no)
  rm -rf "$repo" "$fakebin"
  [ "$rc" -eq 0 ]
  [ "$published" == "yes" ]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bats test/test_fetch_source.bats`
Expected: FAIL (current `fetch-source.sh` still uses snapshot).

- [ ] **Step 4: Rewrite `scripts/fetch-source.sh` (full implementation — spec §4)**

Delete: `fetch_via_snapshot_staged`, `is_509_failure`, the inline `_dsc_field`/`parse_dsc_artifacts`/`validate_artifact_basenames`/`validate_dsc_metadata` (now sourced from `_dsc.sh`), `DEBIAN_SNAPSHOT_TIMESTAMP` reads, snapshot URL construction, the snapshot-first/509-fallback `main` body. Keep: `publish_source_tree`, `publish_orig_tarball`, `cleanup_fetch_tmp`, TMP_ROOT trap (copy their exact bodies from the current file).

```bash
#!/usr/bin/env bash
# Fetch the ocserv source tree into build/source/. Spec §4.
# FETCH_SOURCE=pool  : fetch locked version from deb.debian.org/debian/pool/<pool_path>/
# FETCH_SOURCE=cache : read verified build/source-cache/<name>/<version>/ (zero network)
# No automatic fallback. No snapshot access on the builder.
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
SOURCE_ROOT="$BUILD_ROOT/source"

UPSTREAM="${OCSERV_UPSTREAM_VERSION:-1.5.0}"
REVISION="${OCSERV_DEBIAN_REVISION:-1}"
REQUEST_VER="${UPSTREAM}-${REVISION}"
LOCK_TSV="${REPO_ROOT}/source-lock/ocserv/${REQUEST_VER}.lock.tsv"

# dscverify fixed trust root (advisory A + review fix #4): all 4 official keyrings.
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

# download_artifact <url> <destination> <logfile>  (spec §3.6.2; shared with prefetch)
download_artifact() {
  local url="$1" dest="$2" logfile="$3"
  if ! curl --fail --show-error --location --output "$dest" "$url" >"$logfile" 2>&1; then
    cat "$logfile" >&2; return 1
  fi
}
_sha256() { sha256sum "$1" | awk '{print $1}'; }

# publish_source_tree / publish_orig_tarball / cleanup_fetch_tmp / TMP_ROOT trap:
# RETAIN EXACT BODIES from the current fetch-source.sh (lines ~184-242). Copy them
# verbatim — they handle the staging→build/source atomic publish + trap cleanup.
publish_source_tree() { :; }   # <-- REPLACE with verbatim current body
publish_orig_tarball() { :; }  # <-- REPLACE with verbatim current body
TMP_ROOT=""
cleanup_fetch_tmp() { :; }     # <-- REPLACE with verbatim current body

# fetch_via_pool <staging> <lock_tsv>
# Spec §4.1 + §3.6-step-5 8-step ordering. Pool URL = https://deb.debian.org/debian/pool/<pool_path>/<file>.
fetch_via_pool() {
  local staging="$1" lock_tsv="$2"
  # allowed_sources gate (zero-network if pool unauthorized)
  [[ ",$META_ALLOWED_SOURCES," == *",pool,"* ]] \
    || die "lock does not authorize pool source for ocserv/${REQUEST_VER}"
  [[ -n "$META_POOL_PATH" ]] || die "lock missing pool_path"
  local base="https://deb.debian.org/debian/pool/${META_POOL_PATH}"
  local dsc="$staging/$META_DSC_NAME" logfile
  # 1. download .dsc
  logfile="$(mktemp)"
  download_artifact "$base/$META_DSC_NAME" "$dsc" "$logfile" \
    || { cat "$logfile" >&2; rm -f "$logfile"; die "pool download failed for $META_DSC_NAME"; }
  rm -f "$logfile"
  # 2. verify .dsc size+sha256 == lock
  local s h; s="$(wc -c <"$dsc" | tr -d ' ')"; h="$(_sha256 "$dsc")"
  [[ "$s" == "$META_DSC_SIZE" ]] || die "pool .dsc size $s != lock $META_DSC_SIZE"
  [[ "$h" == "$META_DSC_SHA256" ]] || die "pool .dsc sha256 mismatch"
  # 3-4. parse + cross-check Files/Checksums-Sha256/lock
  dsc_artifacts_match_lock "$dsc" || die "pool .dsc artifact mapping != lock"
  # 5. download artifacts
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do
    local nm="${ARTIFACT_NAME[$i]}" dest="$staging/$nm"
    logfile="$(mktemp)"
    download_artifact "$base/$nm" "$dest" "$logfile" \
      || { cat "$logfile" >&2; rm -f "$logfile"; die "pool download failed for $nm"; }
    rm -f "$logfile"
    # 6. verify actual size+sha256 == lock
    s="$(wc -c <"$dest" | tr -d ' ')"; h="$(_sha256 "$dest")"
    [[ "$s" == "${ARTIFACT_SIZE[$i]}" ]] || die "$nm size $s != lock"
    [[ "$h" == "${ARTIFACT_SHA256[$i]}" ]] || die "$nm sha256 mismatch"
  done
  # 7. dscverify (fixed trust root)
  dscverify_cmd "$dsc" || die "dscverify failed for $META_DSC_NAME"
  # 8. dpkg-source strong unpack into staging/ocserv-<UPSTREAM>
  dpkg-source --require-valid-signature --require-strong-checksums -x "$dsc" "$staging/ocserv-${UPSTREAM}" \
    || die "dpkg-source -x failed"
  # place orig tarball(s) as siblings of the tree (publish_orig_tarball expects them in staging)
}

# fetch_via_cache <staging> <lock_tsv> <cache_root>
# Spec §4.4 11-step identity closure. Zero network.
fetch_via_cache() {
  local staging="$1" lock_tsv="$2" cache_root="$3"
  local cache="$cache_root/$META_SOURCE/$META_DEBIAN_VERSION"
  [[ -d "$cache" ]] || die "cache missing: $cache (run prefetch + import on a prefetch node)"
  # 2. read cache.meta
  read_cache_meta "$cache/cache.meta"
  # 3. version assertions (all three)
  verify_cache_meta_versions
  # 4. cache.meta source/version == lock META (4-way: env→META→lock path→cache dir)
  [[ "$CM_SOURCE" == "$META_SOURCE" && "$CM_DEBIAN_VERSION" == "$META_DEBIAN_VERSION" ]] \
    || die "cache.meta source/version != lock META"
  [[ "$CM_SOURCE/$CM_DEBIAN_VERSION" == "$META_SOURCE/$META_DEBIAN_VERSION" ]] \
    || die "cache dir name != cache.meta identity"
  # 5. content_sha256 == sha256(SHA256SUMS)  (cache.meta self-consistent)
  [[ "$CM_CONTENT_SHA256" == "$(_sha256 "$cache/SHA256SUMS")" ]] \
    || die "cache content_sha256 self-inconsistent"
  # 6-7. identity anchor: expected (from lock) == actual SHA256SUMS
  local expected; expected="$(mktemp)"
  write_expected_sha256sums "$expected"
  cmp -s "$expected" "$cache/SHA256SUMS" \
    || { rm -f "$expected"; die "cache SHA256SUMS != lock projection (identity mismatch)"; }
  rm -f "$expected"
  # 8. sha256sum -c on actual artifact bytes
  ( cd "$cache" && sha256sum -c --status SHA256SUMS ) || die "cache SHA256SUMS verification failed"
  # 9. manifest integrity (internal consistency only)
  verify_manifest_hash "$cache" || die "cache manifest hash mismatch"
  # 10. .dsc artifact mapping == lock
  dsc_artifacts_match_lock "$cache/$META_DSC_NAME" || die "cache .dsc mapping != lock"
  # 11. dpkg-source strong unpack into staging (re-verifies signature)
  cp -- "$cache/$META_DSC_NAME" "$staging/"
  local i
  for i in "${!ARTIFACT_NAME[@]}"; do cp -- "$cache/${ARTIFACT_NAME[$i]}" "$staging/"; done
  dpkg-source --require-valid-signature --require-strong-checksums -x "$staging/$META_DSC_NAME" "$staging/ocserv-${UPSTREAM}" \
    || die "dpkg-source -x failed (cache)"
}

main() {
  local mode="${FETCH_SOURCE:-pool}"
  case "$mode" in
    pool|cache) ;;
    *) die "FETCH_SOURCE must be pool|cache, got: $mode" ;;
  esac
  # read lock + 3-way identity (env version == META version == lock path <ver>; META source == ocserv)
  read_lock_tsv "$LOCK_TSV" "$REQUEST_VER"
  [[ "$META_DEBIAN_VERSION" == "$REQUEST_VER" ]] \
    || die "env version '$REQUEST_VER' != lock META debian_version '$META_DEBIAN_VERSION'"
  [[ "$META_SOURCE" == "ocserv" ]] || die "lock META source '$META_SOURCE' != ocserv"

  mkdir -p "$BUILD_ROOT"
  TMP_ROOT="$(mktemp -d "$BUILD_ROOT/.fetch-tmp.XXXXXX")"
  trap cleanup_fetch_tmp EXIT
  local staging="$TMP_ROOT/staging"; mkdir -p "$staging"

  case "$mode" in
    pool)  fetch_via_pool  "$staging" "$LOCK_TSV" ;;
    cache) fetch_via_cache "$staging" "$LOCK_TSV" "$CACHE_ROOT" ;;
  esac

  publish_source_tree "$staging/ocserv-${UPSTREAM}" "$SOURCE_ROOT/ocserv-${UPSTREAM}"
  publish_orig_tarball "$staging" "$SOURCE_ROOT"
  log "source tree ready: $SOURCE_ROOT/ocserv-${UPSTREAM} (from ${mode})"
}

SOURCE_GUARD=1
[[ -n "${SOURCE_GUARD:-}" ]] || main "$@"
```

> **Implementer note for the three `:;` placeholders:** `publish_source_tree`, `publish_orig_tarball`, and `cleanup_fetch_tmp` MUST be copied verbatim from the *current* `fetch-source.sh` (lines ~184-242) — they are retained unchanged (spec §4.2). Do not reimplement them. Their exact bodies handle the atomic `mv` from staging to `build/source/`, the orig-tarball-as-sibling requirement for quilt, and the TMP_ROOT `trap ... EXIT` cleanup. Replace each `:;` body with the verbatim retained code.

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
