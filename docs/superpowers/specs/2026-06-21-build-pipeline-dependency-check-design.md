# Build Pipeline Dependency Check — Design

**Date:** 2026-06-21
**Status:** Approved
**Triggering incident:** CI `build` job failed on `tencent-x64` runner with `scripts/fetch-source.sh: line 54: dscverify: command not found` — an opaque error that required log-reading to trace to a missing `devscripts` package. Root cause: the runner had never run `bootstrap-build-host.sh` (which declares `devscripts` as a dependency), so `dscverify` was absent. The repo code was correct; the environment was incomplete. This design hardens the scripts so the same class of failure surfaces a precise, actionable error immediately.

## Goal

Make build-pipeline scripts fail fast with a precise, actionable message when a required external command is missing — naming the command, its source package, and the fix — instead of an opaque `command not found` buried mid-execution.

## Scope

**In scope:** Add a shared `require_cmds()` helper to `_common.sh` and call it at the entry of the 5 build-pipeline scripts that CI's `build` job invokes.

**Out of scope:**
- Publish/release scripts (`aptly-publish.sh`, `aptly-rollback.sh`, `r2-sync.sh`, `cf-purge.sh`) — different operational role (repo publisher), installed separately.
- `bootstrap-build-host.sh` — it is itself the package-installer; checking its own deps would be circular.
- `smoke-test.sh` — primarily docker-driven; different dependency profile.
- `_*.sh` sourced helpers — not entry points.

## Design

### New helper: `require_cmds()` in `_common.sh`

Signature: `require_cmds <cmd:pkg> <cmd:pkg> ...`

- Each argument is `command:debian-package`.
- Checks every command via `command -v`; collects ALL missing ones (does not stop at the first).
- If any missing, calls `die` with a multi-line message listing commands, packages, and the fix.
- Matches existing `_common.sh` conventions: uses the existing `die()` (which prefixes `[HH:MM:SS] ERROR:`), `command -v` (already used by `cmd_exists` in the same file).

```bash
# require_cmds <cmd:pkg> <cmd:pkg> ...  — die (reporting ALL missing) if any absent.
# Usage: require_cmds dscverify:devscripts dpkg-source:dpkg-dev
require_cmds() {
  local missing=() pkgs=() c p
  for spec in "$@"; do
    c="${spec%%:*}"; p="${spec#*:}"
    command -v "$c" >/dev/null 2>&1 || { missing+=("$c"); pkgs+=("$p"); }
  done
  if (( ${#missing[@]} )); then
    die "missing commands: ${missing[*]}
  packages: ${pkgs[*]}
  fix: run 'make bootstrap-build-host' on the builder, or: sudo apt-get install -y ${pkgs[*]}"
  fi
}
```

### Why report all missing at once (not first-failure)

The triggering incident's worry was "install devscripts, then sbuild is missing, then lintian..." — a fix-rerun-fix-rerun loop. Reporting all missing commands in one error collapses the loop into one trip.

### Why declare `coreutils` commands too

`sha256sum` (coreutils) is declared even though it ships on every Linux. The `require_cmds` call doubles as **self-documenting dependency list** — reading one line reveals the script's full external footprint. Consistency (every external command is declared) outweighs the marginal redundancy.

### Error message format

```
[15:31:48] ERROR: missing commands: dscverify
  packages: devscripts
  fix: run 'make bootstrap-build-host' on the builder, or: sudo apt-get install -y devscripts
```

Two fix paths surfaced because there are two legitimate remediation contexts:
- `make bootstrap-build-host` — full, reproducible builder setup (preferred).
- `sudo apt-get install -y <pkgs>` — quick ad-hoc fix on an existing host.

### Call sites

Each call goes immediately after all `. _*.sh` source lines and before business logic (fail-fast, before any side effects).

| Script | require_cmds arguments |
|---|---|
| `fetch-source.sh` | `dscverify:devscripts` `dpkg-source:dpkg-dev` `curl:curl` `sha256sum:coreutils` `gpg:gnupg` `quilt:quilt` |
| `prefetch-source.sh` | `dscverify:devscripts` `dpkg-source:dpkg-dev` `curl:curl` `sha256sum:coreutils` `gpg:gnupg` |
| `build-source-package.sh` | `dpkg-buildpackage:dpkg-dev` `sbuild:sbuild` |
| `build-binary.sh` | `sbuild:sbuild` `lintian:lintian` `schroot:schroot` |
| `lint-package.sh` | `lintian:lintian` |
| `rewrap-changelog.sh` | `dch:devscripts` |

Command→package mappings verified against Debian/trixie: `dscverify`/`dch`→devscripts, `dpkg-source`/`dpkg-buildpackage`→dpkg-dev, `sbuild`→sbuild, `schroot`→schroot, `lintian`→lintian, `sha256sum`→coreutils, `gpg`→gnupg, `quilt`→quilt, `curl`→curl.

## Testing

### New test: `test/test_require_cmds.bats`

1. **All present → pass:** call `require_cmds` with commands guaranteed on the test host (e.g. `ls:coreutils bash:bash`); assert exit 0, no output.
2. **Some missing → die with package in message:** stub a guaranteed-absent command name; call `require_cmds cmd-that-does-not-exist:fakepkg ls:coreutils`; assert non-zero exit, stderr contains `fakepkg` and `apt-get install`.
3. **Empty call → pass:** `require_cmds` with no args returns 0 (defensive; no script relies on it but the helper must not crash).

These run via the existing `bats test/` harness; they mock absence by using a nonsense command name rather than manipulating PATH.

### Existing tests

`test_fetch_source.bats`, `test_prefetch_source.bats`, etc. run on hosts that already have the real commands, so `require_cmds` is a no-op pass for them — no behavioral change, no regression.

## Verification

- **Simulated absence:** in a container/PATH without `dscverify`, run `fetch-source.sh`; expect the multi-line error (command + package + fix), exit 1.
- **Complete environment:** on a host with all packages, run the full `bats test/` suite; all green, plus the new test cases.
- **No side effects:** `require_cmds` is read-only (only `command -v` checks); it performs no writes and alters no state on success.

## Non-goals

- Does NOT install packages, modify PATH, or retry. Pure detection + clear failure.
- Does NOT replace `bootstrap-build-host.sh` as the source of truth for builder setup — it complements it by catching drift when bootstrap was skipped or incomplete (exactly the incident scenario).
- Does NOT extend to publish/release scripts in this iteration (deferred).
