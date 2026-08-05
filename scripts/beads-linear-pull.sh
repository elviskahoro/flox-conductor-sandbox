#!/usr/bin/env bash
# Initialize and explicitly pull Linear AI issues into a local, stealth Beads DB.
#
# Linear is authoritative for this pilot. This script is deliberately pull-only
# and never invokes the bidirectional/default `bd linear sync` mode.
#
# Required environment:
#   INFISICAL_TOKEN
#   INFISICAL_PROJECT_ID
#
# Usage:
#   bash scripts/beads-linear-pull.sh
#   bash scripts/beads-linear-pull.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BEADS_DIR="${REPO_ROOT}/.beads"
LINEAR_TEAM_ID="${LINEAR_TEAM_ID:-68392631-5fd7-4d78-9d12-b6b453785cb6}"
INFISICAL_ENV="${INFISICAL_ENV:-dev}"
LINEAR_SECRET_NAME="${LINEAR_SECRET_NAME:-LINEAR_API_KEY}"
DRY_RUN=0

error() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) error "usage: $0 [--dry-run]" ;;
esac

command -v bd >/dev/null 2>&1 || error "bd is not installed or not on PATH"
command -v infisical >/dev/null 2>&1 || error "infisical is not installed or not on PATH"
[[ -n "${INFISICAL_TOKEN:-}" ]] || error "INFISICAL_TOKEN is not set"
[[ -n "${INFISICAL_PROJECT_ID:-}" ]] || error "INFISICAL_PROJECT_ID is not set"

cd "${REPO_ROOT}"
export BEADS_DIR

if [[ -d .beads ]]; then
  for remote_key in sync.remote dolt.remote; do
    remote_value="$(bd config get "${remote_key}" 2>/dev/null || true)"
    [[ -z "${remote_value}" ]] || error "existing .beads database has ${remote_key}=${remote_value}; refusing to mix Linear with a remote-backed Beads database"
  done
else
  bd init --stealth --non-interactive --skip-agents --skip-hooks -p flox-ai
fi

bd config set linear.team_id "${LINEAR_TEAM_ID}"

# Keep the API key in the process environment only. Infisical's output and all
# command errors are suppressed here so the secret cannot enter setup logs.
if ! LINEAR_API_KEY="$(infisical secrets get "${LINEAR_SECRET_NAME}" \
  --env="${INFISICAL_ENV}" --projectId "${INFISICAL_PROJECT_ID}" --plain 2>/dev/null)"; then
  error "could not read Infisical secret ${LINEAR_SECRET_NAME}"
fi
[[ -n "${LINEAR_API_KEY}" ]] || error "Infisical secret ${LINEAR_SECRET_NAME} is empty"
export LINEAR_API_KEY

SYNC_ARGS=(linear sync --pull --relations)
if [[ "${DRY_RUN}" -eq 1 ]]; then
  SYNC_ARGS+=(--dry-run)
fi

bd "${SYNC_ARGS[@]}"
unset LINEAR_API_KEY
