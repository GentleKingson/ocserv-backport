# Shared setup for bats tests.
export REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
load "${BATS_TEST_DIRNAME}/helpers/bats-helper.bash" 2>/dev/null || true
setup() { cd "${REPO_ROOT}"; }
