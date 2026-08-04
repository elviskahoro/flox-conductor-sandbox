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
# second package in the minimal provisioning environment. The gtm-sdk remote
# may legitimately be empty; in that case create an ephemeral local bead with
# --sandbox so `bd show` is still exercised without pushing test data.
issue_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "${LIST_JSON}" | head -1)"
if [[ -z "${issue_id}" ]]; then
  issue_id="$(bd --sandbox create --ephemeral --silent \
    --title "Conductor Linux Beads validation" \
    --description "Disposable read-check fixture; never pushed to DoltHub." \
    --type task --priority 4)"
  printf 'Remote Beads list was empty; using disposable local fixture %s\n' "${issue_id}"
fi

bd show "${issue_id}" >"${SHOW_OUTPUT}"
printf 'Beads read checks passed for %s\n' "${issue_id}"
