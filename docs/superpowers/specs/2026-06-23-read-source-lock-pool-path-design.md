# read-source-lock.py Pool Path Quality Design

## Objective

Improve the CodeScene code-health finding for `scripts/read-source-lock.py` by reducing the complexity of `check_pool_path()` only. This is a local readability refactor, not a behavior change.

## Scope

Only `check_pool_path()` and newly extracted helper functions for that function are in scope. `emit()`, CLI parsing, YAML loading, lock identity checks, document validation, TSV formatting, and tests for unrelated behavior are out of scope.

The implementation must keep the current single-file script structure and must not add runtime or test dependencies.

## Current Problem

`check_pool_path()` currently performs all pool path validation through a sequence of independent conditionals. The rules are correct and covered by existing tests, but the function concentrates too many branches in one method, which CodeScene reports as a complex method.

The goal is to preserve those rules while moving cohesive validation groups into small helpers.

## Proposed Design

Keep `check_pool_path(path)` as the public local validation entry point:

```python
def check_pool_path(path):
    if not isinstance(path, str) or path == "":
        fail("pool_path must be a non-empty string")

    check_pool_path_slashes(path)
    check_pool_path_characters(path)
    check_pool_path_segments(path)
```

Add three private-by-convention helper functions using the current file's `check_*` naming style:

- `check_pool_path_slashes(path)` validates leading slash, trailing slash, and backslash rejection.
- `check_pool_path_characters(path)` validates control characters, whitespace, and URL-ish or fragment characters: `://`, `?`, `#`, `%`.
- `check_pool_path_segments(path)` validates empty segments, `.`, `..`, and each segment against `RE_POOL_SEGMENT`.

The helper boundaries mirror the existing validation groups. They should not combine error messages, reorder checks, change regular expressions, or introduce table-driven validation.

## Observable Behavior

The refactor must strictly preserve observable CLI behavior:

- Valid input produces byte-for-byte identical TSV on stdout.
- Invalid input exits with the same status.
- Invalid input writes the same stderr text.
- For paths that violate multiple rules, the first failing rule remains the same.
- CLI argument behavior remains unchanged.

## Testing

Verification should use the existing test suite because the intended behavior is unchanged:

- Run the focused Bats tests for `read-source-lock.py`.
- Run `make test`.

If a test failure appears, treat it as a behavior regression unless it is clearly unrelated to this file.

## Acceptance Criteria

- Only `scripts/read-source-lock.py` is changed during implementation.
- Only `check_pool_path()` and its extracted helper functions are modified or added.
- `emit()` is not changed.
- No dependency is added.
- Existing Bats tests pass.
- `make test` passes.
- CodeScene's `Complex Method` finding for `check_pool_path()` is eliminated or materially reduced.
