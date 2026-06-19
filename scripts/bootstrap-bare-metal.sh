#!/usr/bin/env bash
# scripts/bootstrap-bare-metal.sh
# Bare-metal root setup for the trixie builder (runbook step 1).
# Automates: install sudo/git/ca-certificates, create builder user, configure
# passwordless sudo, configure SSH authorized_keys, optional repo clone.
# Stops before bootstrap-build-host.sh (sbuild group relogin cannot be bypassed).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/_common.sh"

# ---- parameters (set by parse_args) -----------------------------------------
BUILDER_USER="builder"
SSH_PUBKEY_FILE=""
SSH_PUBKEY=""
REPO_URL=""
HOST_HINT="<host>"
PUBKEYS=""   # multi-line string of validated pubkey lines, populated by parse_args

usage() {
  cat >&2 <<EOF
Usage: $0 --ssh-pubkey-file <path> | --ssh-pubkey <string> | ADMIN_PUBKEY=<string> [options]

Required (exactly one of):
  --ssh-pubkey-file <path>   read SSH public keys from file (multi-line ok)
  --ssh-pubkey <string>      single SSH public key string
  ADMIN_PUBKEY               env var: single SSH public key string

Optional:
  --builder-user <name>      builder username (default: builder; must not be root)
  --repo-url <url>           clone repo to <builder-home>/ocserv-backport (skip if absent)
  --host-hint <host>         host shown in next-steps ssh hint (default: <host>)
  -h, --help                 show this help
EOF
}

# ---- pure functions (defined here, tested by bats) --------------------------
# (filled in Task 2)

# ---- side-effect functions ---------------------------------------------------
# (filled in Tasks 3-5)

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-pubkey-file) SSH_PUBKEY_FILE="${2:-}"; shift 2 ;;
      --ssh-pubkey)      SSH_PUBKEY="${2:-}"; shift 2 ;;
      --builder-user)    BUILDER_USER="${2:-}"; shift 2 ;;
      --repo-url)        REPO_URL="${2:-}"; shift 2 ;;
      --host-hint)       HOST_HINT="${2:-}"; shift 2 ;;
      -h|--help)         usage; exit 0 ;;
      *)                 usage; die "unknown argument: $1" ;;
    esac
  done
  # (full validation filled in Task 3)
}

main() {
  parse_args "$@"
  # (stages filled in Tasks 3-5)
  :
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
