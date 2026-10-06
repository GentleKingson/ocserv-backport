# Publish a release

Pushing a tag runs `.github/workflows/release.yml`, which builds the amd64 and
arm64 packages for Debian 13 (trixie) and Ubuntu 24.04 (noble) and publishes
them as a GitHub Release named after the tag.

## Steps

1. Make sure `main` has the versions you want to ship in
   `scripts/_versions.sh`.
   - New Debian source: add its `source-lock/` files and update
     `OCSERV_DEBIAN_VERSION`; reset `BACKPORT_REVISION` to `1`.
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
   `gh release create` (see [Release notes](#release-notes)). GitHub stores `~` in asset names as `.`; the files and
   `SHA256SUMS` already use the stored names, so
   `sha256sum -c SHA256SUMS` works on the downloads.

After a tag push publishes the release, the `install-script` workflow
installs it with the README one-line installer (`install.sh`) on Debian 13
and Ubuntu 24.04, amd64 and arm64, and checks that `ocserv.service` is
enabled but not running.

## Release notes

The release body has three parts, in this order:

1. `.github/release-notes/<tag>.md`, if it exists. Commit it before tagging
   to add highlights, upgrade notes or known issues for that release only.
2. `.github/release-notes/template.md`, rendered by
   `scripts/release-render-notes.sh` with `${TAG}`, `${OCSERV_DEBIAN13}` and
   `${OCSERV_NOBLE}` replaced by the tag and the packaged versions.
3. The list of merged pull requests that `gh release create --generate-notes`
   produces. [`.github/release.yml`](../.github/release.yml) groups them by
   label:

   | Category | Label |
   | --- | --- |
   | Breaking changes | `release/breaking` |
   | Security | `release/security` |
   | Debian 13 (trixie) | `area/debian` |
   | Ubuntu 24.04 (noble) | `area/ubuntu` |
   | Build & Packaging | `area/packaging` |
   | Documentation | `area/docs` |
   | Dependencies | `area/dependencies` |
   | Other changes | Unmatched PRs |

Create these labels in the repository before applying them. Area labels are
optional. Use `release/internal` only for changes with no effect on the
published packages, such as test refactors or CI-only maintenance; it removes
the PR from the generated notes even when other labels are present. Dependabot
GitHub Actions updates get it automatically. Do not apply it to security fixes
or breaking changes.

The generated list uses PR titles, so write titles for people installing the
packages. The [PR template](../.github/PULL_REQUEST_TEMPLATE.md) has an
optional one-sentence Release note; nothing parses it, but it helps when
writing a `<tag>.md` file.

## Dry run

Run the `release` workflow manually from the Actions tab (or
`gh workflow run release.yml --ref <branch>`) to build and collect the
release assets without publishing anything. The tag and already-published
checks are skipped, and the collected files plus `SHA256SUMS` are uploaded as
the `release-assets` artifact, with the rendered notes header in the
`release-notes` artifact. A tag push uploads the same artifacts before it
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
