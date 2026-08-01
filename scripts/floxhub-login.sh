#!/usr/bin/env bash
# Opt-in, non-interactive FloxHub login for a *publisher* sandbox.
#
# NEVER call this from `.conductor/settings.toml`'s setup script or from
# `scripts/sandbox-test.sh`'s default path. Stage 4 of the harness (H4)
# depends on testing an unauthenticated sandbox's ability to fetch a FloxHub
# package; auto-authenticating on provisioning would permanently disqualify
# every fresh sandbox from ever running that test again. Authenticating a
# sandbox must stay a deliberate, explicit action an operator takes on a
# sandbox they intend to use for publishing, never a side effect of normal
# provisioning.
#
# Usage:
#   FLOXHUB_TOKEN=<token> bash scripts/floxhub-login.sh
#
# See README.md's "Running" section for how to obtain and hand off a token.
set -euo pipefail

if [[ -z "${FLOXHUB_TOKEN:-}" ]]; then
  echo "error: FLOXHUB_TOKEN is not set. Refusing to fall back to interactive login." >&2
  echo "Set FLOXHUB_TOKEN to a token from 'flox auth token' (run on an already-authenticated machine) and re-run." >&2
  exit 1
fi

umask 077
TOKEN_FILE="$(mktemp)"
cleanup() {
  if command -v shred >/dev/null 2>&1; then
    shred -u "${TOKEN_FILE}" 2>/dev/null || rm -f "${TOKEN_FILE}"
  else
    # macOS has no `shred`; best-effort overwrite before removing.
    dd if=/dev/urandom of="${TOKEN_FILE}" bs=1024 count=1 conv=notrunc >/dev/null 2>&1 || true
    rm -f "${TOKEN_FILE}"
  fi
}
trap cleanup EXIT

printf '%s' "${FLOXHUB_TOKEN}" >"${TOKEN_FILE}"

flox auth login --token-file="${TOKEN_FILE}"
flox auth status
