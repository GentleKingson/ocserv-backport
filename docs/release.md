# Publish a release

Pushing a tag runs `.github/workflows/release.yml`, which builds the amd64 and
arm64 packages for Debian 13 (trixie) and Ubuntu 24.04 (noble) and publishes
them as a GitHub Release named after the tag.

## Steps

1. Make sure `main` has the versions you want to ship in
   `scripts/_versions.sh`.
   - New Debian source: add its `source-lock/` files and update
     `OCSERV_DEBIAN_VERSION`; keep `BACKPORT_REVISION=1`.
   - Rebuild of an already released Debian source: increase
     `BACKPORT_REVISION` (for example `1` -> `2`), so the packages become
     `~debian13.2` and `~ubuntu24.04.2` and apt treats them as an upgrade.
2. Tag the commit and push the tag:

   ```bash
   git tag 1.5.0-2
   git push origin 1.5.0-2
   ```

The tag must be the upstream ocserv version (`1.5.0`) or start with it
followed by `-` or `.` (`1.5.0-2`, `1.5.0.1`).

## What the workflow does

1. `preflight` runs `scripts/release-preflight.sh`. It fails before any build
   starts when:
   - a release for the tag already exists;
   - the tag does not match the upstream version in `scripts/_versions.sh`;
   - an earlier release already ships the same ocserv package version, which
     means `BACKPORT_REVISION` was not bumped.
2. `debian-trixie` and `ubuntu-noble` call `debian-trixie-build.yml` and
   `ubuntu-noble-build.yml`. Each one builds both architectures and runs
   lintian and the Docker smoke test, exactly like a manual run.
3. `publish` runs only when all four builds succeed. It downloads their
   artifacts, and `scripts/release-collect-assets.sh` picks exactly these
   files, failing if any is missing or has an unexpected version:
   - `ocserv_<version>~debian13.<n>_{amd64,arm64}.deb`
   - `ocserv_<version>~ubuntu24.04.<n>_{amd64,arm64}.deb`

   It writes `SHA256SUMS` for them and creates the release with
   `gh release create`. GitHub stores `~` in asset names as `.`; the files and
   `SHA256SUMS` already use the stored names, so
   `sha256sum -c SHA256SUMS` works on the downloads.

## Dry run

Run the `release` workflow manually from the Actions tab (or
`gh workflow run release.yml --ref <branch>`) to build and collect the
release assets without publishing anything. The tag and already-published
checks are skipped, and the collected files plus `SHA256SUMS` are uploaded as
the `release-assets` artifact. A tag push uploads the same artifact before it
creates the release.

## When a build fails

No release is created. Fix the problem, then delete the tag and push it again
on the fixed commit:

```bash
git push origin :refs/tags/1.5.0-2
git tag -f 1.5.0-2 <fixed-commit>
git push origin 1.5.0-2
```

For a failure that is not caused by the code (for example a runner problem),
use "Re-run failed jobs" on the workflow run instead.
