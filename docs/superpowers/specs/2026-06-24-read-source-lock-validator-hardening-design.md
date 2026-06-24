# read-source-lock.py Validator Hardening Design

## Objective

Apply the attachment-first validator hardening design to
`scripts/read-source-lock.py`.

The change should tighten whole-string validation boundaries, reject boolean
values where integer fields are required, and split the current validation and
CLI orchestration logic into small linear helper functions. The repository
remains a single-purpose ocserv Debian backport build and validation repository.

## Scope

In scope:

- `scripts/read-source-lock.py` validation structure and helper functions.
- Focused Bats regression coverage in `test/test_read_source_lock.bats`.
- Syntax and full test verification for the source-lock reader.

Out of scope:

- Source lock YAML content changes.
- TSV projection format changes.
- Fetch, build, lint, dry-run, smoke, or package publishing behavior.
- New runtime or test dependencies.
- A generic schema validation framework.

## Chosen Approach

Use the attachment as the behavioral and structural baseline.

This means the implementation should prefer the attachment's helper boundaries
and stricter validation behavior over strict compatibility with the current
stderr order. Small error-boundary changes are acceptable when they follow from
clearer helper boundaries or stricter validation.

The implementation must still preserve the script's observable success path:
valid lock files emit byte-for-byte identical TSV output.

## Architecture

Keep `scripts/read-source-lock.py` as one small script. Split responsibilities
inside that file into private helper groups:

- Constants: keep the existing validation regex meanings, but use unanchored
  regex patterns with `fullmatch()` at call sites.
- YAML loading: keep `StrictSafeLoader` as the duplicate-key protection.
- Top-level validation: `_check_top_level()` validates root type, unknown
  top-level fields, and `schema_version`.
- Identity validation: `_check_identity_fields()` validates `source` and
  `debian_version`.
- Pool path validation: keep `check_pool_path()` as the public local entry
  point and use `_require_pool_path_string()`, `_check_pool_path_syntax()`,
  and `_check_pool_path_segments()`.
- Artifact validation: `_check_dsc()`, `_check_artifact()`, and
  `_check_artifacts()` validate `.dsc` and source artifact records.
- CLI orchestration: `_build_parser()`, `_resolve_lock_path()`, `_read_raw()`,
  and `_parse_lock()` isolate argument setup, path resolution, file reading,
  and YAML parse error handling.

`validate()` should remain a linear orchestration function:

1. Check top-level mapping and schema version.
2. Check source identity fields.
3. Check `pool_path`.
4. Check `dsc`.
5. Check `artifacts`.
6. Check lock path identity.
7. Return the checked data.

`main()` should also remain linear:

1. Build parser.
2. Parse arguments.
3. Resolve lock path.
4. Read raw YAML.
5. Parse YAML.
6. Validate and emit.

## Validation Behavior

The hardened validator should follow these rules:

- `schema_version` must be exactly integer `1`; boolean values are rejected
  explicitly.
- `source` must be a string matching the full Debian source-name pattern.
- `debian_version` must be a string matching the full version-without-epoch
  pattern; epochs are rejected by the pattern rather than a separate colon
  branch.
- `pool_path` must be a non-empty string with no leading or trailing slash, no
  backslash, no control characters or whitespace, and no `://`, `?`, `#`, or
  `%`.
- Each `pool_path` segment must be non-empty, not `.` or `..`, and must match
  the full pool segment pattern.
- `dsc` must be a mapping with only `name`, `size`, and `sha256`.
- `dsc.name` must be a safe basename ending in `.dsc`.
- `artifacts` must be a non-empty list of mappings with only `name`, `size`,
  and `sha256`.
- Artifact names must be safe basenames, must not equal `dsc.name`, and must be
  unique.
- `size` fields must be non-negative integers; boolean values are rejected
  explicitly.
- `sha256` fields must be strings matching exactly 64 lowercase hex characters.

`fullmatch()` should be used for whole-string regex checks. This avoids prefix
acceptance from `match()` and avoids relying on `$` anchor behavior around final
newlines.

## Error Handling

Continue using `fail(msg)` as the single validation failure path. Validation
errors print the message to stderr and exit with status `1`.

Argument parser errors should continue to use argparse behavior and exit with
status `2`.

File-not-found and YAML parse errors should keep the existing failure style:

- `lock file not found: <path>`
- `YAML parse error: <exception>`

Small validation error ordering changes are acceptable if they result from the
new helper boundaries. Tests should assert important new boundaries rather than
locking every old stderr priority.

## Testing

Add focused regression coverage for the hardened boundaries:

- Whole-string matching for `source`, `debian_version`, `sha256`, safe
  basenames, and `pool_path` segments.
- `schema_version: true` is rejected.
- Boolean `size` values remain rejected for both `dsc` and artifact entries.
- Unknown and missing fields remain rejected at top level, `dsc`, and artifact
  levels.
- Duplicate artifact names remain rejected.
- Artifact name equal to `dsc.name` remains rejected.
- CLI failures remain covered for `--source` without `--debian-version`,
  incompatible `--lock` and `--debian-version`, missing lock file, and YAML
  parse error.
- Valid lock TSV output remains byte-for-byte unchanged.
- Committed `.lock.tsv` projections do not drift from their YAML files.

Verification commands:

```bash
python3 -m py_compile scripts/read-source-lock.py
bats test/test_read_source_lock.bats
make test
```

## Acceptance Criteria

- `scripts/read-source-lock.py` follows the attachment-first helper structure.
- `validate()` and `main()` are linear orchestration functions.
- Regex validation uses `fullmatch()` for whole-string checks.
- Boolean integer boundary cases are rejected explicitly.
- Valid lock TSV output is unchanged.
- Focused and full tests pass.
- No dependency is added.
- No fetch, build, lint, smoke, dry-run, source-lock authority, or TSV schema
  behavior is changed.
