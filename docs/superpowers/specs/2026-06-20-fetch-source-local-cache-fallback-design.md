# fetch-source.sh Local Source Cache Fallback Design

**Date:** 2026-06-20
**Target:** `scripts/fetch-source.sh` (+ new bats test file)
**Trigger:** `make dry-run` failing at the `fetch` stage with HTTP 509 from
snapshot.debian.org (rate-limit / "abusive network requests" policy on the
builder's IP). Confirmed external; the existing fetch code is correct.

---

## 1. Problem & Root Cause

### 1.1 Symptom

```
== 1. fetch ==
dget https://snapshot.debian.org/archive/debian/20260616T083027Z/pool/main/o/ocserv/ocserv_1.5.0-1.dsc
curl: (22) The requested URL returned error: 509
dget: curl ocserv_1.5.0-1.dsc ... failed
DRY-RUN FAILED at: fetch
```

### 1.2 Root cause (confirmed, not a code bug)

snapshot.debian.org's Varnish front-end returns **HTTP 509** for the builder's
IP — its administrative "abusive network requests" block. Evidence:
- Explicit policy text from the snapshot API endpoint.
- `server: Varnish` + `retry-after: 0` response headers.
- The URL/timestamp itself is valid; `fetch-source.sh` constructs it correctly.
- Failure is at the transport layer (curl receives 0 bytes).

The 509 can hit **any** of the requests `dget` makes (the `.dsc`, then each
referenced artifact it downloads). It is not necessarily the `.dsc` request.

### 1.3 Why a code change is warranted

snapshot.debian.org rate-limits are not rare for build/CI hosts and can persist
hours to days. The pipeline has no offline path today, so a rate-limited builder
is fully blocked. A trusted local cache fallback lets `make dry-run` proceed
without weakening the snapshot-first reproducibility design.

---

## 2. Goal

Add a **cache fallback** to `fetch-source.sh` that activates **only** when
snapshot.debian.org explicitly returns HTTP 509. All other failures remain fatal
with original diagnostics. The snapshot path stays the primary, default path.

**Non-goals:**
- Do NOT add automatic cache population (no auto-download from Debian archive).
  Cache is a manually-seeded, operator-trusted local input.
- Do NOT change the snapshot timestamp-locking design (snapshot remains primary).
- Do NOT add `.env` switches or flags (fallback is automatic, scoped to 509).
- Do NOT mask non-509 errors (404, network down, DNS failure stay fatal).

---

## 3. Design (locked from review)

### 3.1 High-level flow

```
1. Build snapshot DSC_URL from .env (existing logic, unchanged).
2. Create a disposable staging dir: build/.fetch-tmp.XXXXXX/ (mktemp -d).
3. Run `dget -x -u "$DSC_URL"` INSIDE staging; capture full stdout+stderr + exit code.
4. If dget exit 0:
     a. Verify expected source tree exists in staging.
     b. Atomically move completed result to build/source/.
     c. Log "source tree ready".
5. If dget exit != 0:
     a. Inspect captured log for EXPLICIT 509 markers (see §3.3).
     b. If 509 confirmed → enter cache fallback (§3.4).
     c. If NOT 509 → re-emit original dget log, die (preserve diagnostics).
6. Always: rm -rf staging dir on exit (trap), regardless of success/failure.
```

### 3.2 Disposable staging workspace (review point #4)

**Why required:** `dget` downloads multiple files and invokes `dpkg-source`.
On a mid-run 509 (e.g., `.dsc` succeeds, `.orig.tar.xz` 509s), `build/source/`
would be left with partial files. Re-running cache fallback into the same
directory risks mixing half-products with cached files.

**Layout:**

```
build/
  source/            # final, completed source tree (only published post-validation)
  source-cache/      # manual trusted cache (operator-seeded; .gitignored via build/)
  .fetch-tmp.XXXXXX/ # mktemp -d staging; removed on exit via trap
```

Both the snapshot path and the cache path complete their work in staging, then
publish a validated result to `build/source/`. `build/source/` is never the
working directory for downloads or extraction.

### 3.3 509 detection: parse dget's captured log (review point #1)

**Do NOT re-probe the URL with `curl -sI`.** A `.dsc` HEAD probe cannot detect a
509 that happened on a later artifact download. `dget`'s exit code is also
unreliable for HTTP semantics (it selects between curl/wget backends and curl's
exit 22 means "any >=400 HTTP error", not specifically 509).

**Method:** match explicit 509 markers in the captured dget stdout+stderr.

Match any of these literal patterns (case-sensitive, as they appear in real
curl/wget output):

```
curl: (22) The requested URL returned error: 509
HTTP Error 509
HTTP/1.1 509
HTTP/2 509
```

Implementation: a helper function `is_509_failure()` that takes the log text and
returns 0 (true) if any pattern matches, 1 otherwise. Keep the pattern list in
one place so it can be extended if dget's backend wording changes.

**Explicitly do NOT match:**
- bare `22` (too broad — covers 404, 403, 500, etc.)
- generic "failed" / "error" strings
- exit code alone

### 3.4 Cache fallback (review points #2, #3)

Triggered only after a confirmed 509. Steps:

```
CACHE_DIR=build/source-cache

a. Require cached .dsc: build/source-cache/ocserv_${SRC_VER}.dsc
   - Missing → die, listing the expected .dsc path + Debian pool URL hint.

b. Validate cached .dsc metadata:
   - Source field == "ocserv"
   - Version field == "${SRC_VER}" (e.g. "1.5.0-1")
   - Mismatch → die, showing actual vs expected (do NOT proceed).

c. Derive required artifacts FROM the cached .dsc (NOT hardcoded filenames):
   - Parse the Checksums-Sha256 stanza (authoritative; required by
     --require-strong-checksums). If absent, die (the .dsc is too weak to use).
   - Collect every filename listed in that stanza.
   - Rationale: dpkg-source 3.0 (quilt) permits additional .orig-*.tar.*;
     future ocserv versions may change compression or add components.
     Hardcoding ".dsc + .orig.tar.xz + .debian.tar.xz" would silently break.

d. Verify each referenced artifact exists in CACHE_DIR.
   - Any missing → die, listing the actually-missing filenames + Debian pool hint.

e. Copy cached .dsc + all referenced artifacts into a fresh staging dir
   (separate from the dget staging dir; cache stays read-only input).
   - Use cp (not symlink) so cache remains untouched and staging is self-contained.

f. Extract with checksum enforcement:
     dpkg-source --require-strong-checksums -x \
       "$STAGING/ocserv_${SRC_VER}.dsc" \
       "$STAGING/ocserv-${UPSTREAM}"
   - --require-strong-checksums refuses packages lacking SHA-256.
   - Extraction failure (checksum mismatch, corrupt file) → die, no ready log.

g. Verify extracted tree: $STAGING/ocserv-${UPSTREAM}/ exists and is non-empty.
   - Missing/empty → die.

h. Publish: move validated source tree to build/source/ (same publish step as
   the snapshot success path, so both paths converge).
   - Log "source tree ready (from local cache; snapshot.debian.org was rate-limited)".
```

### 3.5 Cache trust boundary (explicit acknowledgment)

The cache fallback validates **consistency between the cached `.dsc` and the
cached artifacts** (checksums, filenames, Source/Version fields). It does NOT
and cannot independently prove the cached `.dsc` originates from the configured
`DEBIAN_SNAPSHOT_TIMESTAMP` snapshot — when snapshot is unreachable there is no
online oracle for that.

**Therefore:** `build/source-cache/` is an **operator-trusted local seed**. The
operator is responsible for obtaining the artifacts (e.g., from
`https://deb.debian.org/debian/pool/main/o/ocserv/`). For `ocserv 1.5.0-1` these
files are immutable published artifacts, so the Debian pool copies are
byte-identical to the snapshot-time-locked copies; reproducibility is preserved
in practice. This trade-off is acceptable and is documented in the script header
and the runbook.

### 3.6 Cache directory & seeding (operator manual step)

- Location: `build/source-cache/` (already `.gitignored` via the `build/` rule).
- Not created automatically by the script (avoids implying it manages seeding).
- Operator seeds it once, manually:
  ```
  mkdir -p build/source-cache
  # From a non-rate-limited host, download the 3 (current) files:
  cd build/source-cache
  wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.dsc
  wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0.orig.tar.xz
  wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.debian.tar.xz
  ```
- The script's "missing files" error message will name the exact files the
  cached `.dsc` requires, so the operator doesn't have to guess.

---

## 4. Testing (review point #5)

New file: `test/test_fetch_source.bats`. Follows the existing
`test_bootstrap_bare_metal.bats` style (`call_func` pattern via sourcing).

Because `fetch-source.sh` currently has `set -euo pipefail` + a top-level
main-path body (not wrapped in functions), the implementation MUST refactor the
logic into **pure/testable functions** that take explicit arguments (URL, cache
dir, log text, etc.) and return codes/strings — mirroring how
`bootstrap-bare-metal.sh` separates pure validators from side-effect functions.
A `SOURCE_GUARD` (`[[ "${BASH_SOURCE[0]}" == "${0}" ]]`) allows bats to source
without triggering main.

**Minimum test set (8 cases):**

| # | Scenario | Expected |
|---|----------|----------|
| 1 | dget succeeds | no fallback; result published from staging |
| 2 | dget log explicitly shows 509 + cache complete | fallback succeeds; tree from cache |
| 3 | dget non-509 failure (e.g. 404 / network) | fallback NOT triggered; original log preserved; exit non-zero |
| 4 | 509 + cache missing `.dsc` | die; names expected `.dsc` + pool hint |
| 5 | 509 + cache missing one dsc-listed artifact | die; names actually-missing artifact(s) |
| 6 | 509 + cached `.dsc` Source/Version mismatch | die; shows actual vs expected |
| 7 | 509 + checksum/extraction failure | die; no "ready" log |
| 8 | dget left partial files in staging; cache fallback runs | staging is separate dir; no partial-file contamination |

Tests for cases 1, 2, 3, 8 require faking `dget`/`dpkg-source` (test stubs on
PATH or function overrides). Cases 4–7 test the pure validation helpers
(`is_509_failure`, `parse_dsc_artifacts`, `validate_dsc_metadata`) directly
without subprocess fakes — these are the highest-value, most stable tests and
should be implemented first.

---

## 5. Implementation notes

- **Refactor for testability first:** extract `is_509_failure()`,
  `parse_dsc_artifacts()`, `validate_dsc_metadata()`,
  `verify_cache_artifacts()` as pure functions (input → output, no side effects).
  Keep `fetch_via_snapshot()` and `fetch_via_cache()` as the side-effect
  orchestrators. Main body becomes a thin dispatcher under SOURCE_GUARD.
- **trap cleanup:** `trap 'rm -rf "$STAGING"' EXIT` in main to guarantee
  staging removal even on die.
- **Publish convergence:** both paths write to `build/source/` only after
  validation, via the same `publish_source_tree()` helper.
- **Logging:** use existing `log()` from `_common.sh`. Distinguish cache path
  in the ready message so operators know which path served the request.
- **No new dependencies:** uses only `dget`, `dpkg-source`, `mktemp`, `cp`,
  `grep`, standard coreutils — all already present on the builder.

---

## 6. Verification (post-implementation)

1. `make test` → all existing bats tests + 8 new ones pass.
2. On the rate-limited builder: seed `build/source-cache/`, run `make dry-run`,
   confirm fetch stage completes via cache path with the "from local cache" log.
3. On a non-rate-limited host (or after unblock): confirm snapshot path still
   primary, cache untouched.
4. Force a non-509 failure (bad timestamp → 404): confirm fallback NOT
   triggered, original dget log preserved, exit non-zero.
