#!/usr/bin/env python3
"""Validate a pool-only source lock YAML and emit its TSV projection."""
import argparse
import os
import re
import sys

import yaml


class StrictSafeLoader(yaml.SafeLoader):
    """SafeLoader variant that rejects duplicate mapping keys at every level."""

    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in seen:
                raise yaml.constructor.ConstructorError(
                    None, None, f"duplicate key {key!r} in mapping", key_node.start_mark
                )
            seen.add(key)
        return super().construct_mapping(node, deep=deep)


RE_SOURCE = re.compile(r"^[a-z0-9][a-z0-9+.\-]*$")
RE_DEBIAN_VERSION = re.compile(r"^[A-Za-z0-9.+~\-]+$")
RE_SHA256 = re.compile(r"^[0-9a-f]{64}$")
RE_POOL_SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._\-]*$")
RE_SAFE_BASENAME = re.compile(r"^[^/\\\x00-\x1f\x7f\s]+$")


def fail(msg):
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def strict_safe_load(raw):
    return yaml.load(raw, Loader=StrictSafeLoader)


def check_lock_path_identity(lock_path, data):
    parent = os.path.basename(os.path.dirname(lock_path))
    filename = os.path.basename(lock_path)
    if not filename.endswith(".yaml"):
        fail(f"lock path must end with .yaml: {lock_path}")
    stem = filename[:-5]
    if parent != data["source"]:
        fail(f"lock path source {parent!r} != YAML source {data['source']!r}")
    if stem != data["debian_version"]:
        fail(f"lock path version {stem!r} != YAML debian_version {data['debian_version']!r}")


def check_pool_path(path):
    if not isinstance(path, str) or path == "":
        fail("pool_path must be a non-empty string")
    if path.startswith("/") or path.endswith("/"):
        fail(f"pool_path must not have leading/trailing slash: {path!r}")
    if "\\" in path:
        fail("pool_path must not contain backslash")
    if re.search(r"[\x00-\x1f\x7f\s]", path):
        fail("pool_path must not contain control characters or whitespace")
    if "://" in path or "?" in path or "#" in path or "%" in path:
        fail("pool_path must not contain :// ? # %")
    segs = path.split("/")
    if any(seg in ("", ".", "..") for seg in segs):
        fail(f"pool_path has empty/./.. segment: {path!r}")
    for seg in segs:
        if not RE_POOL_SEGMENT.match(seg):
            fail(f"pool_path segment invalid: {seg!r}")


def check_size(value, field):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail(f"{field} must be a non-negative int (got {value!r})")


def check_safe_name(value, field):
    if (
        not isinstance(value, str)
        or not RE_SAFE_BASENAME.match(value)
        or value in (".", "..")
        or value.startswith("-")
    ):
        fail(f"{field} invalid basename: {value!r}")


def check_sha(value, field):
    if not isinstance(value, str) or not RE_SHA256.match(value):
        fail(f"{field} must be 64 lowercase hex")


def validate(data, lock_path):
    if not isinstance(data, dict):
        fail("lock root must be a mapping")
    allowed_top = {"schema_version", "source", "debian_version", "pool_path", "dsc", "artifacts"}
    unknown = set(data) - allowed_top
    if unknown:
        fail(f"unknown top-level fields: {sorted(unknown)}")

    if data.get("schema_version") != 1:
        fail("schema_version must be == 1")
    src = data.get("source")
    if not isinstance(src, str) or not RE_SOURCE.match(src):
        fail(f"source invalid: {src!r}")
    ver = data.get("debian_version")
    if not isinstance(ver, str) or not RE_DEBIAN_VERSION.match(ver) or ":" in ver:
        fail(f"debian_version invalid: {ver!r}")

    check_pool_path(data.get("pool_path"))

    dsc = data.get("dsc")
    if not isinstance(dsc, dict):
        fail("dsc must be a mapping")
    unknown_dsc = set(dsc) - {"name", "size", "sha256"}
    if unknown_dsc:
        fail(f"unknown dsc fields: {sorted(unknown_dsc)}")
    for key in ("name", "size", "sha256"):
        if key not in dsc:
            fail(f"dsc.{key} missing")
    check_safe_name(dsc["name"], "dsc.name")
    if not dsc["name"].endswith(".dsc"):
        fail("dsc.name must end with .dsc")
    check_size(dsc["size"], "dsc.size")
    check_sha(dsc["sha256"], "dsc.sha256")

    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        fail("artifacts must be a non-empty list")
    names = []
    for idx, artifact in enumerate(artifacts):
        if not isinstance(artifact, dict):
            fail(f"artifacts[{idx}] must be a mapping")
        unknown_artifact = set(artifact) - {"name", "size", "sha256"}
        if unknown_artifact:
            fail(f"unknown artifact fields: {sorted(unknown_artifact)}")
        for key in ("name", "size", "sha256"):
            if key not in artifact:
                fail(f"artifacts[{idx}].{key} missing")
        check_safe_name(artifact["name"], f"artifacts[{idx}].name")
        if artifact["name"] == dsc["name"]:
            fail(f"artifacts[{idx}].name must not equal dsc.name")
        check_size(artifact["size"], f"artifacts[{idx}].size")
        check_sha(artifact["sha256"], f"artifacts[{idx}].sha256")
        names.append(artifact["name"])
    if len(set(names)) != len(names):
        fail("artifact names must be unique")

    check_lock_path_identity(lock_path, data)
    return data


def emit(data):
    dsc = data["dsc"]
    print(
        f"META\t{data['source']}\t{data['debian_version']}\t{data['pool_path']}"
        f"\t{dsc['name']}\t{dsc['size']}\t{dsc['sha256']}"
    )
    for artifact in data["artifacts"]:
        print(f"ARTIFACT\t{artifact['name']}\t{artifact['size']}\t{artifact['sha256']}")


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--lock", help="path to <source>/<version>.yaml")
    group.add_argument("--source", help="source name (resolves source-lock/<source>/<version>.yaml)")
    parser.add_argument("--debian-version", dest="debian_version", help="required with --source")
    args = parser.parse_args()

    if args.lock is not None:
        if args.debian_version is not None:
            parser.error("--lock is mutually exclusive with --source/--debian-version")
        lock_path = args.lock
    else:
        if args.debian_version is None:
            parser.error("--source requires --debian-version")
        lock_path = os.path.join("source-lock", args.source, f"{args.debian_version}.yaml")

    try:
        with open(lock_path, "r", encoding="utf-8") as handle:
            raw = handle.read()
    except FileNotFoundError:
        fail(f"lock file not found: {lock_path}")

    try:
        data = strict_safe_load(raw)
    except yaml.YAMLError as exc:
        fail(f"YAML parse error: {exc}")

    emit(validate(data, lock_path))


if __name__ == "__main__":
    main()
