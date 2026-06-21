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
