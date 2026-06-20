# fetch-source.sh Local Source Cache Fallback Design

**Date:** 2026-06-20
**Target:**
- `scripts/fetch-source.sh` (modify — refactor + cache fallback)
- `test/test_fetch_source.bats` (new — test pure helpers + stubbed orchestrators)
- `docs/trixie-builder-dryrun-runbook.md` (modify — document the 509 recovery procedure in the fetch/dry-run failure-troubleshooting section)
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
2. Create TMP_ROOT (mktemp -d) with SNAPSHOT_STAGE + CACHE_STAGE subdirs;
   trap rm -rf TMP_ROOT on EXIT (see §3.2).
3. Run `dget -x -u "$DSC_URL"` INSIDE SNAPSHOT_STAGE; capture full
   stdout+stderr + exit code.
4. If dget exit 0:
     a. Verify expected source tree exists in SNAPSHOT_STAGE.
     b. publish_source_tree() → build/source/ (§3.7, policy B swap).
     c. Log "source tree ready".
5. If dget exit != 0:
     a. Inspect captured log for EXPLICIT 509 markers (see §3.3).
     b. If 509 confirmed → enter cache fallback (§3.4), which works in
        CACHE_STAGE and publishes via the same publish_source_tree() (§3.7).
     c. If NOT 509 → re-emit original dget log, die (preserve diagnostics).
6. trap removes TMP_ROOT on exit regardless of outcome. build/source/ and
   build/source-cache/ are never removed by the trap.
```

### 3.2 Disposable staging workspace (review point #4)

**Why required:** `dget` downloads multiple files and invokes `dpkg-source`.
On a mid-run 509 (e.g., `.dsc` succeeds, `.orig.tar.xz` 509s), `build/source/`
would be left with partial files. Re-running cache fallback into the same
directory risks mixing half-products with cached files.

**Layout — single TMP_ROOT, two isolated subdirs:**

```bash
mkdir -p build
TMP_ROOT="$(mktemp -d build/.fetch-tmp.XXXXXX)"
trap 'rm -rf -- "${TMP_ROOT}"' EXIT

SNAPSHOT_STAGE="${TMP_ROOT}/snapshot"   # dget downloads + extraction here
CACHE_STAGE="${TMP_ROOT}/cache"         # cache copy + dpkg-source extraction here
mkdir -p "${SNAPSHOT_STAGE}" "${CACHE_STAGE}"
```

**Why one TMP_ROOT, not two mktemp dirs:** the trap binds to a single variable.
If `STAGING` were reassigned per-path (snapshot → cache), the first staging dir
would leak un-trapped. One `TMP_ROOT` with two subdirs gives path isolation
without reassigning the cleanup target. The trap never touches `build/source/`
or `build/source-cache/`.

```
build/
  source/            # final, completed source tree (only published post-validation)
  source-cache/      # manual trusted cache (operator-seeded; .gitignored via build/)
  .fetch-tmp.XXXXXX/ # single TMP_ROOT (trap target); contains snapshot/ + cache/
```

Both paths complete their work in their own staging subdir, then publish a
validated result to `build/source/` via the shared publish step (§3.7).
`build/source/` is never the working directory for downloads or extraction.

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

c. Derive required artifacts FROM the cached .dsc (NOT hardcoded filenames),
   with FULL coverage enforcement (review point #4):
   - Parse the `Files` stanza → set F (all required artifact filenames).
   - Parse the `Checksums-Sha256` stanza → set S (SHA-256-covered filenames).
   - If `Checksums-Sha256` stanza is absent → die (the .dsc is too weak to use).
   - **Require F == S (set equality).** If any required artifact (in F) lacks a
     SHA-256 entry (not in S), or S references files not in F → die. Rationale:
     `dpkg-source --require-strong-checksums` only demands that the package
     contain *at least one* strong checksum overall; it does NOT guarantee every
     artifact is SHA-256-covered. A partial/corrupt .dsc could cover only some
     files. We enforce full coverage ourselves before trusting the cache.
   - **Validate every filename as a safe basename** before any `cp`:
       * non-empty
       * not `.` or `..`
       * contains no `/` and no `\`
       * no duplicates in F
     Any violation → die. This prevents path traversal when constructing
     `cp "${CACHE_DIR}/${name}"` from .dsc-parsed filenames.
   - Rationale: dpkg-source 3.0 (quilt) permits additional .orig-*.tar.*;
     future ocserv versions may change compression or add components.
     Hardcoding ".dsc + .orig.tar.xz + .debian.tar.xz" would silently break.

d. Verify each referenced artifact (set F) exists in CACHE_DIR.
   - Any missing → die, listing the actually-missing filenames + Debian pool hint.

e. Copy cached .dsc + all referenced artifacts into CACHE_STAGE
   (separate from SNAPSHOT_STAGE; cache stays read-only input).
   - Use cp (not symlink) so cache remains untouched and staging is self-contained.
   - Construct destination paths only from validated basenames (step c).

f. Extract with checksum enforcement:
     dpkg-source --require-strong-checksums -x \
       "${CACHE_STAGE}/ocserv_${SRC_VER}.dsc" \
       "${CACHE_STAGE}/ocserv-${UPSTREAM}"
   - --require-strong-checksums refuses packages lacking SHA-256.
   - Combined with step c's F==S enforcement, every artifact is SHA-256-verified.
   - Extraction failure (checksum mismatch, corrupt file) → die, no ready log.

g. Verify extracted tree: $STAGING/ocserv-${UPSTREAM}/ exists and is non-empty.
   - Missing/empty → die.

h. Publish: publish_source_tree() moves validated source tree to build/source/
   (§3.7, same publish step as the snapshot success path, so both paths converge).
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
`https://deb.debian.org/debian/pool/main/o/ocserv/`).

**Reproducibility scope (tightened):** the fallback preserves deterministic
reconstruction **relative to an operator-approved cache seed**. It verifies
cache-internal consistency (`.dsc` ↔ artifacts via checksums, Source/Version
metadata), but does **not** independently establish that the cached `.dsc`
originated from the configured `DEBIAN_SNAPSHOT_TIMESTAMP`. This trade-off is
acceptable for an operator-seeded recovery path and is documented in the script
header and the runbook (§4 of this spec's scope).

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

### 3.7 Publish policy (review point #3)

"Atomically move" is imprecise when the target dir already exists and is
non-empty. Lock **policy B** (swap-with-rollback): validate in staging first,
then swap, with rollback on failure.

```text
publish_source_tree(staging_tree, target=build/source/ocserv-${UPSTREAM}):
  1. Assert staging_tree exists and is non-empty (caller already validated).
  2. If target does not exist:
       mv staging_tree → target. Done.
  3. If target exists:
       a. mv target → target.old.$$      # move old aside (do NOT delete yet)
       b. mv staging_tree → target        # install new
       c. If step (b) failed:
            mv target.old.$$ → target     # restore old
            die "publish failed; old source tree restored"
       d. rm -rf target.old.$$            # only delete old AFTER new is confirmed in place
```

**Key invariant:** the existing source tree is never deleted before the new tree
is successfully installed. If install fails, the old tree is restored.

**What gets published (explicit decision):** only the extracted source tree
`ocserv-${UPSTREAM}/` is published to `build/source/`. The downloaded `.dsc`
and tarballs remain in the staging subdir (cleaned up by trap). Rationale:
downstream `build-source-package.sh` consumes `build/source/ocserv-${UPSTREAM}`,
not the raw artifacts; publishing only the tree matches current downstream
expectations and keeps `build/source/` focused. (If a future stage needs the
raw `.dsc`, that's a separate change — out of scope here.)

This is an observable behavior change from the current script (which leaves
`.dsc` + tarballs in `build/source/`), so it is called out explicitly and will
be noted in the commit message.

---

## 4. Testing (review point #5)

New file: `test/test_fetch_source.bats`. Follows the existing
`test_bootstrap_bare_metal.bats` style (`call_func` pattern via sourcing).

Because `fetch-source.sh` currently has `set -euo pipefail` + a top-level
main-path body (not wrapped in functions), the implementation MUST refactor the
logic into **pure/testable functions** that take explicit arguments (URL, cache
dir, log text, etc.) and return codes/strings — mirroring how
`bootstrap-bare-metal.sh` separates pure validators from side-effect functions.
The locked script skeleton (§5: `BASH_SOURCE[0]` + `if [[ "${BASH_SOURCE[0]}"
== "${0}" ]]`) allows bats to source without triggering main.

**Minimum test set (10 cases):**

| # | Scenario | Expected |
|---|----------|----------|
| 1 | dget succeeds | no fallback; result published from staging |
| 2 | dget log explicitly shows 509 + cache complete | fallback succeeds; tree from cache |
| 3 | dget non-509 failure (e.g. 404 / network) | fallback NOT triggered; original log preserved; exit non-zero |
| 4 | 509 + cache missing `.dsc` | die; names expected `.dsc` + pool hint |
| 5 | 509 + cache missing one dsc-listed artifact | die; names actually-missing artifact(s) |
| 6 | 509 + cached `.dsc` Source/Version mismatch | die; shows actual vs expected |
| 7 | 509 + checksum/extraction failure | die; no "ready" log |
| 8 | dget left partial files in SNAPSHOT_STAGE; cache fallback runs | CACHE_STAGE is separate dir; no partial-file contamination |
| 9 | 509 + cached `.dsc` Files set != Checksums-Sha256 set | die; fallback rejected (partial SHA-256 coverage) |
| 10 | 509 + cached `.dsc` artifact filename contains `../` or `/` or `\` | die; fallback rejected (unsafe basename / path traversal) |

Tests for cases 1, 2, 3, 8 require faking `dget`/`dpkg-source` (test stubs on
PATH or function overrides). Cases 4–7, 9, 10 test the pure validation helpers
(`is_509_failure`, `parse_dsc_artifacts`, `validate_dsc_metadata`,
`verify_cache_artifacts`, `validate_artifact_basenames`) directly without
subprocess fakes — these are the highest-value, most stable tests and should be
implemented first (TDD: write them before the orchestrator tests).

---

## 5. Implementation notes

- **Script skeleton (locked — required for bats sourceability):** the current
  `source "$(dirname "$0")/_common.sh"` breaks when bats sources the script,
  because `$0` is the calling shell, not the sourced file. Use `BASH_SOURCE[0]`
  throughout, matching `bootstrap-bare-metal.sh`:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
  source "${SCRIPT_DIR}/_common.sh"

  # ... pure helpers + orchestrator functions ...

  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
  fi
  ```

  This makes the script both directly executable and bats-sourceable without
  changing `_common.sh` resolution.

- **Refactor for testability first:** extract `is_509_failure()`,
  `parse_dsc_artifacts()` (returns set F from Files + set S from
  Checksums-Sha256), `validate_dsc_metadata()` (Source/Version),
  `validate_artifact_basenames()` (safe-basename check),
  `verify_cache_artifacts()` (existence) as pure functions
  (input → output, no side effects). Keep `fetch_via_snapshot()` and
  `fetch_via_cache()` as the side-effect orchestrators. Main body becomes a
  thin dispatcher under the SOURCE_GUARD (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`).
- **trap cleanup:** single `trap 'rm -rf -- "${TMP_ROOT}"' EXIT` in main (§3.2).
  Never reassign TMP_ROOT. SNAPSHOT_STAGE / CACHE_STAGE are subdirs of TMP_ROOT,
  so both are cleaned by the one trap. `build/source/` and `build/source-cache/`
  are never touched by the trap.
- **Publish convergence:** both paths produce a validated source tree in their
  staging subdir, then call the shared `publish_source_tree()` (§3.7, policy B)
  to install into `build/source/`.
- **Logging:** use existing `log()` from `_common.sh`. Distinguish cache path
  in the ready message so operators know which path served the request.
- **No new dependencies:** uses only `dget`, `dpkg-source`, `mktemp`, `cp`,
  `grep`, standard coreutils — all already present on the builder.

---

## 6. Verification (post-implementation)

1. `make test` → all existing bats tests + 10 new ones pass.
2. On the rate-limited builder: seed `build/source-cache/`, run `make dry-run`,
   confirm fetch stage completes via cache path with the "from local cache" log.
3. On a non-rate-limited host (or after unblock): confirm snapshot path still
   primary, cache untouched.
4. Force a non-509 failure (bad timestamp → 404): confirm fallback NOT
   triggered, original dget log preserved, exit non-zero.

---

## 7. Runbook change (scope item #3)

`docs/trixie-builder-dryrun-runbook.md` must be updated so the 509 recovery
procedure is part of the documented operational flow, not an ad-hoc operator
note. Two insertions:

### 7.1 Expand the fetch failure-troubleshooting block (§4.3 of runbook)

Current text at runbook L664-667:

```text
步骤 1 fetch 失败：
  可能原因：DEBIAN_SNAPSHOT_TIMESTAMP 写错或仍为占位符 / 网络到 snapshot.debian.org 不通
  回到：4.1（确认 .env 时间戳）；或排查网络/代理
```

Add a new cause/branch for HTTP 509:

```text
步骤 1 fetch 失败：
  可能原因 A：DEBIAN_SNAPSHOT_TIMESTAMP 写错或仍为占位符
    回到：4.1（确认 .env 时间戳）
  可能原因 B：网络到 snapshot.debian.org 不通
    排查网络/代理
  可能原因 C：snapshot.debian.org 返回 HTTP 509（rate-limit / "abusive network requests"）
    表现：dget 日志含 "curl: (22) The requested URL returned error: 509" 等显式 509 标记
    自动恢复：fetch-source.sh 会自动回退到 build/source-cache/ 本地缓存
    前提：操作者已预先 seed 缓存（见 §7.2）
    若缓存未 seed 或不全：脚本会列出缺失文件，按提示从 Debian pool 下载后重跑
```

### 7.2 Add a cache-seeding subsection (new, near the fetch stage explanation)

Place near runbook L585-595 (where `DEBIAN_SNAPSHOT_TIMESTAMP` and
snapshot.debian.org are explained). New content:

```text
### 预置源码缓存（应对 snapshot.debian.org rate-limit）

snapshot.debian.org 对高频请求的 IP 会返回 HTTP 509（"abusive network requests"），
可持续数小时到数天。若 make dry-run 的 fetch 阶段遇到 509，fetch-source.sh 会
自动回退到本地缓存 build/source-cache/。

缓存是操作者信任的本地 seed：fetch-source.sh 不会自动下载填充它。
预置步骤（一次性，在未被 rate-limit 的机器上下载，或从 Debian 主 archive）：

    mkdir -p build/source-cache
    cd build/source-cache
    wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.dsc
    wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0.orig.tar.xz
    wget https://deb.debian.org/debian/pool/main/o/ocserv/ocserv_1.5.0-1.debian.tar.xz

注意：
- 所需文件以 cached .dsc 的 Checksums-Sha256 stanza 为准，不要假设永远是这三个文件名。
- 缓存验证的是 artifacts 与 cached .dsc 的一致性（checksum + Source/Version），
  不能在线重新证明 cached .dsc 来自所配置 timestamp 的 snapshot。这是受信任的本地 seed。
- 对 ocserv 1.5.0-1（immutable 发布版本），Debian pool 副本与 snapshot 副本字节一致。
```

### 7.3 Non-goals for the runbook change

- Do NOT renumber existing runbook sections (the renumber project already fixed
  §4.3 etc. — this change only inserts content within existing sections).
- Do NOT add the cache-fallback logic to the "quick-ref" appendix unless the
  operator explicitly wants it surfaced there.
