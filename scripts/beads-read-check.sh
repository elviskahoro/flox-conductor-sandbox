#!/usr/bin/env bash
# Read-only Beads smoke checks used after beads-dolthub-pull.sh.
set -euo pipefail

READY_JSON="$(mktemp)"
LIST_JSON="$(mktemp)"
SHOW_OUTPUT="$(mktemp)"
cleanup() {
  rm -f "${READY_JSON}" "${LIST_JSON}" "${SHOW_OUTPUT}"
}
trap cleanup EXIT

bd ready --json >"${READY_JSON}"
bd list --json >"${LIST_JSON}"

# bd list returns a JSON array. Extract one real issue ID without requiring a
# second package in the minimal provisioning environment.
issue_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "${LIST_JSON}" | head -1)"
[[ -n "${issue_id}" ]] || {
  echo "error: bd list returned no issue ID" >&2
  exit 1
}

bd show "${issue_id}" >"${SHOW_OUTPUT}"
printf 'Beads read checks passed for %s\n' "${issue_id}"
