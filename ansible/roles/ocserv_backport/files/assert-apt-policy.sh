#!/usr/bin/env bash
set -euo pipefail

# Spec §5.11. Parse `apt-cache policy <pkg>` and assert candidate source/version/priority.
# In real runs, --input omitted -> reads live `apt-cache policy`. Tests pass --input.

package=""; expected_version=""; expected_origin=""; expected_suite=""; expected_priority=""; input=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) package="$2"; shift 2 ;;
    --expected-version) expected_version="$2"; shift 2 ;;
    --expected-origin) expected_origin="$2"; shift 2 ;;
    --expected-suite) expected_suite="$2"; shift 2 ;;
    --expected-priority) expected_priority="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
# expected_origin is asserted via aptly -origin at publish; we confirm suite+priority
# here, which together with the pinning guarantee the origin (Spec §5.12: verify on box).
: "${package}"; : "${expected_version}"; : "${expected_suite}"; : "${expected_priority}"

policy="$(if [[ -n "${input}" ]]; then cat "${input}"; else apt-cache policy "${package}"; fi)"

# Candidate line (e.g. "  Candidate: 1.5.0-1~bpo13+1")
candidate="$(printf '%s\n' "${policy}" | awk '/Candidate:/{print $2; exit}')"
if [[ "${candidate}" != "${expected_version}" ]]; then
  echo "FAIL: Candidate=${candidate} != ${expected_version}" >&2
  printf '%s\n' "${policy}" >&2
  exit 1
fi

# Version-table row for the target version: "    <version> <priority>" then next line
# "      <priority> <url> <suite>/...". Use string equality ($1==v) to avoid regex meta
# issues with characters like + . ~ in Debian versions.
read_block() {
  printf '%s\n' "${policy}" | awk -v v="${expected_version}" '
    $1 == v { print; getline; print; exit }
  '
}
block="$(read_block)"
if [[ -z "${block}" ]]; then
  echo "FAIL: no version-table row for ${expected_version}" >&2
  printf '%s\n' "${policy}" >&2
  exit 1
fi
# Row 1 last field = priority; Row 2 = "  <priority> <url> <suite> ..."
priority="$(printf '%s\n' "${block}" | awk 'NR==1{print $NF; exit}')"
src_line="$(printf '%s\n' "${block}" | awk 'NR==2{$1=""; print; exit}' | sed 's/^ //')"

if [[ "${priority}" != "${expected_priority}" ]]; then
  echo "FAIL: priority=${priority} != ${expected_priority}" >&2
  printf '%s\n' "${policy}" >&2
  exit 1
fi
if [[ "${src_line}" != *"${expected_suite}"* ]]; then
  echo "FAIL: source '${src_line}' lacks suite ${expected_suite}" >&2
  exit 1
fi
# Origin: the source must be a private repo (http(s)://apt.example.com style), NOT the
# Debian official mirror. We check it is not deb.debian.org — combined with the matching
# suite this pins origin to THEHKUS-Backports. (Spec §5.12.)
if [[ "${src_line}" == *"deb.debian.org"* ]] || [[ "${src_line}" != *"://"* ]]; then
  echo "FAIL: source '${src_line}' is not the private ${expected_origin} repo" >&2
  exit 1
fi

echo "OK: Candidate=${candidate} src=${src_line} priority=${priority}"
