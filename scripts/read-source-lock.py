#!/usr/bin/env python3
"""Validate a pool-only source lock YAML and emit its TSV projection."""
import argparse
import os
import re
import sys
from typing import NoReturn

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


ALLOWED_TOP_LEVEL_FIELDS = {
    "schema_version",
    "source",
    "debian_version",
    "pool_path",
    "dsc",
    "artifacts",
}
ARTIFACT_FIELDS = {"name", "size", "sha256"}

RE_SOURCE = re.compile(r"[a-z0-9][a-z0-9+.\-]*")
RE_DEBIAN_VERSION_WITHOUT_EPOCH = re.compile(r"[A-Za-z0-9.+~-]+")
RE_SHA256 = re.compile(r"[0-9a-f]{64}")
RE_POOL_SEGMENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9+._\-]*")
RE_POOL_PATH_FORBIDDEN = re.compile(r"://|[?#%]")
RE_POOL_PATH_WHITESPACE = re.compile(r"[\x00-\x1f\x7f\s]")
RE_SAFE_BASENAME = re.compile(r"[^/\\\x00-\x1f\x7f\s]+")


def fail(msg: str) -> NoReturn:
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def strict_safe_load(raw: str) -> object:
    return yaml.load(raw, Loader=StrictSafeLoader)


def check_lock_path_identity(lock_path: str, data: dict) -> None:
    parent = os.path.basename(os.path.dirname(lock_path))
    filename = os.path.basename(lock_path)

    if not filename.endswith(".yaml"):
        fail(f"lock path must end with .yaml: {lock_path}")

    stem = filename[:-5]
    if parent != data["source"]:
        fail(f"lock path source {parent!r} != YAML source {data['source']!r}")
    if stem != data["debian_version"]:
        fail(
            f"lock path version {stem!r} "
            f"!= YAML debian_version {data['debian_version']!r}"
        )


def _require_pool_path_string(path: object) -> str:
    if not isinstance(path, str):
        fail("pool_path must be a non-empty string")
    if path == "":
        fail("pool_path must be a non-empty string")
    return path


def _check_pool_path_syntax(path: str) -> None:
    if path.startswith("/"):
        fail(f"pool_path must not have leading/trailing slash: {path!r}")
    if path.endswith("/"):
        fail(f"pool_path must not have leading/trailing slash: {path!r}")
    if "\\" in path:
        fail("pool_path must not contain backslash")
    if RE_POOL_PATH_WHITESPACE.search(path):
        fail("pool_path must not contain control characters or whitespace")
    if RE_POOL_PATH_FORBIDDEN.search(path):
        fail("pool_path must not contain :// ? # %")


def _check_pool_path_segments(path: str) -> None:
    segments = path.split("/")
    if any(segment in ("", ".", "..") for segment in segments):
        fail(f"pool_path has empty/./.. segment: {path!r}")

    for segment in segments:
        if RE_POOL_SEGMENT.fullmatch(segment) is None:
            fail(f"pool_path segment invalid: {segment!r}")


def check_pool_path(path: object) -> None:
    checked_path = _require_pool_path_string(path)
    _check_pool_path_syntax(checked_path)
    _check_pool_path_segments(checked_path)


def check_size(value: object, field: str) -> None:
    if isinstance(value, bool):
        fail(f"{field} must be a non-negative int (got {value!r})")
    if not isinstance(value, int):
        fail(f"{field} must be a non-negative int (got {value!r})")
    if value < 0:
        fail(f"{field} must be a non-negative int (got {value!r})")


def check_safe_name(value: object, field: str) -> None:
    if not isinstance(value, str):
        fail(f"{field} invalid basename: {value!r}")
    if RE_SAFE_BASENAME.fullmatch(value) is None:
        fail(f"{field} invalid basename: {value!r}")
    if value in (".", ".."):
        fail(f"{field} invalid basename: {value!r}")
    if value.startswith("-"):
        fail(f"{field} invalid basename: {value!r}")


def check_sha(value: object, field: str) -> None:
    if not isinstance(value, str):
        fail(f"{field} must be 64 lowercase hex")
    if RE_SHA256.fullmatch(value) is None:
        fail(f"{field} must be 64 lowercase hex")


def _check_top_level(data: object) -> dict:
    if not isinstance(data, dict):
        fail("lock root must be a mapping")

    unknown = set(data) - ALLOWED_TOP_LEVEL_FIELDS
    if unknown:
        fail(f"unknown top-level fields: {sorted(unknown)}")

    schema_version = data.get("schema_version")
    if isinstance(schema_version, bool):
        fail("schema_version must be == 1")
    if not isinstance(schema_version, int):
        fail("schema_version must be == 1")
    if schema_version != 1:
        fail("schema_version must be == 1")

    return data


def _check_identity_fields(data: dict) -> None:
    source = data.get("source")
    if not isinstance(source, str):
        fail(f"source invalid: {source!r}")
    if RE_SOURCE.fullmatch(source) is None:
        fail(f"source invalid: {source!r}")

    debian_version = data.get("debian_version")
    if not isinstance(debian_version, str):
        fail(f"debian_version invalid: {debian_version!r}")
    if RE_DEBIAN_VERSION_WITHOUT_EPOCH.fullmatch(debian_version) is None:
        fail(f"debian_version invalid: {debian_version!r}")


def _check_dsc(data: dict) -> dict:
    dsc = data.get("dsc")
    if not isinstance(dsc, dict):
        fail("dsc must be a mapping")

    unknown = set(dsc) - ARTIFACT_FIELDS
    if unknown:
        fail(f"unknown dsc fields: {sorted(unknown)}")

    for key in ("name", "size", "sha256"):
        if key not in dsc:
            fail(f"dsc.{key} missing")

    check_safe_name(dsc["name"], "dsc.name")
    if not dsc["name"].endswith(".dsc"):
        fail("dsc.name must end with .dsc")
    check_size(dsc["size"], "dsc.size")
    check_sha(dsc["sha256"], "dsc.sha256")
    return dsc


def _check_artifact(artifact: object, idx: int, dsc_name: str) -> str:
    if not isinstance(artifact, dict):
        fail(f"artifacts[{idx}] must be a mapping")

    unknown = set(artifact) - ARTIFACT_FIELDS
    if unknown:
        fail(f"unknown artifact fields: {sorted(unknown)}")

    for key in ("name", "size", "sha256"):
        if key not in artifact:
            fail(f"artifacts[{idx}].{key} missing")

    name = artifact["name"]
    check_safe_name(name, f"artifacts[{idx}].name")
    if name == dsc_name:
        fail(f"artifacts[{idx}].name must not equal dsc.name")
    check_size(artifact["size"], f"artifacts[{idx}].size")
    check_sha(artifact["sha256"], f"artifacts[{idx}].sha256")
    return name


def _check_artifacts(data: dict, dsc_name: str) -> None:
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list):
        fail("artifacts must be a non-empty list")
    if not artifacts:
        fail("artifacts must be a non-empty list")

    names = []
    for idx, artifact in enumerate(artifacts):
        names.append(_check_artifact(artifact, idx, dsc_name))

    if len(set(names)) != len(names):
        fail("artifact names must be unique")


def validate(data: object, lock_path: str) -> dict:
    checked_data = _check_top_level(data)
    _check_identity_fields(checked_data)
    check_pool_path(checked_data.get("pool_path"))
    dsc = _check_dsc(checked_data)
    _check_artifacts(checked_data, dsc["name"])
    check_lock_path_identity(lock_path, checked_data)
    return checked_data


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
