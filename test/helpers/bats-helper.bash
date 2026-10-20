# Shared setup for bats tests. Loaded by each test file via `load helpers/bats-helper.bash`.
# Resolve repo root relative to THIS helper file (test/helpers/ -> repo root is ../..).
# shellcheck disable=SC1090
_BATS_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "${_BATS_HELPER_DIR}/../.." && pwd)"

setup() { cd "${REPO_ROOT}"; }

# Script fixtures are written for the Debian 1.5.0-1 source, which takes the
# pool-only fetch path; pin that version so they keep exercising it.
# test_versions.bats (env -i) checks the real defaults; test_upstream_import.bats
# covers the upstream import.
export OCSERV_DEBIAN_VERSION=1.5.0-1 BACKPORT_REVISION=2
