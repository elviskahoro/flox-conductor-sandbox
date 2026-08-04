#!/usr/bin/env bash
# Authenticate DoltHub with a JWK from Infisical, then initialize or pull the
# local Beads database. Conductor setup calls this only when Infisical
# credentials are present; it can also be run manually to refresh tickets.
#
# Usage:
#   INFISICAL_TOKEN=... INFISICAL_PROJECT_ID=... \
#     bash scripts/beads-dolthub-pull.sh
#
# The Dolt credential is imported into a temporary DOLT_ROOT_PATH and removed
# on exit. The local .beads database and its remote configuration remain in
# the workspace, but the credential does not.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# The dolt CLI/embedded engine version pinned for this workspace (2.1.10)
# doesn't recognize the `dolthub://` shorthand scheme ("unknown url scheme:
# 'dolthub'"); the equivalent doltremoteapi HTTPS URL works on every version
# and is what `dolthub://` resolves to internally on versions that support it.
REMOTE="${BEADS_DOLTHUB_REMOTE:-https://doltremoteapi.dolthub.com/elviskahoro/gtm-sdk}"
SECRET_NAME="${DOLTHUB_DOLT_CREDENTIAL_SECRET_NAME:-DOLTHUB_DOLT_CREDENTIAL_JWK}"
INFISICAL_ENV="${INFISICAL_ENV:-dev}"

error() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v bd >/dev/null 2>&1 || error "bd is not installed or not on PATH"
command -v dolt >/dev/null 2>&1 || error "dolt is not installed or not on PATH"
command -v infisical >/dev/null 2>&1 || error "infisical is not installed or not on PATH"

[[ -n "${INFISICAL_TOKEN:-}" ]] || error "INFISICAL_TOKEN is not set"
[[ -n "${INFISICAL_PROJECT_ID:-}" ]] || error "INFISICAL_PROJECT_ID is not set"

umask 077
CREDENTIAL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/beads-dolthub.XXXXXX")"
cleanup() {
  rm -rf "${CREDENTIAL_ROOT}"
}
trap cleanup EXIT HUP INT TERM

# Keep the secret in memory only long enough to pipe it directly into Dolt.
# Infisical's stderr is suppressed because it may include request metadata;
# the command's status is converted into a safe, actionable error below.
if ! CREDENTIAL_JWK="$(infisical secrets get "${SECRET_NAME}" \
  --env="${INFISICAL_ENV}" --projectId "${INFISICAL_PROJECT_ID}" --plain 2>/dev/null)"; then
  error "could not read Infisical secret ${SECRET_NAME}"
fi
[[ -n "${CREDENTIAL_JWK}" ]] || error "Infisical secret ${SECRET_NAME} is empty"

# DOLT_ROOT_PATH controls Dolt's global credentials/config location. Import
# from stdin so no credential file is created outside the temporary root.
if ! printf '%s' "${CREDENTIAL_JWK}" | \
  DOLT_ROOT_PATH="${CREDENTIAL_ROOT}" dolt creds import --no-profile >/dev/null 2>&1; then
  error "Infisical secret ${SECRET_NAME} is not a valid Dolt credential JWK"
fi
unset CREDENTIAL_JWK

cd "${REPO_ROOT}"
export DOLT_ROOT_PATH="${CREDENTIAL_ROOT}"

if [[ ! -d .beads ]]; then
  bd init --remote "${REMOTE}" --non-interactive --skip-agents --skip-hooks
else
  bd dolt pull
fi

printf 'Beads database is ready from %s\n' "${REMOTE}"
