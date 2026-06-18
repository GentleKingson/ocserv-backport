# Shared setup for bats tests. Loaded by each test file via `load helpers/bats-helper.bash`.
# Resolve repo root relative to THIS helper file (test/helpers/ -> repo root is ../..).
# shellcheck disable=SC1090
_BATS_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "${_BATS_HELPER_DIR}/../.." && pwd)"

setup() { cd "${REPO_ROOT}"; }
