#!/usr/bin/env bash
# Opt-in Phase D MVP setup-script recipe (issue #16 §9): obtain a FloxHub
# token, authenticate, then activate the combined envs/floxhub-provision
# manifest (uv/dolt/infisical/gh/git + bd + roborev). This IS the recipe
# eventually meant for gtm-sdk/scripts/conductor-workspace-setup.sh —
# proven here first, per issue #16 §8; ported there separately, later.
#
# NEVER call this from `.conductor/settings.toml`'s setup script or from
# `scripts/sandbox-test.sh`'s default path, for the same reason
# scripts/floxhub-login.sh isn't: authenticating a sandbox permanently
# disqualifies it from ever being the unauthenticated Stage 4 (H4) tester.
#
# Usage:
#   FLOXHUB_TOKEN=<token> bash scripts/floxhub-provision.sh
#   # or, with Infisical configured for this project and a FLOXHUB_TOKEN
#   # secret available:
#   bash scripts/floxhub-provision.sh
#
# Token acquisition order (this workspace's secrets-management convention:
# Infisical first, never fall back further than the documented env var):
#   1. FLOXHUB_TOKEN, if already set in the environment.
#   2. `infisical secrets get ${FLOXHUB_TOKEN_SECRET_NAME:-FLOXHUB_TOKEN}
#      --plain`, if `infisical` is on PATH. The secret name is overridable
#      via FLOXHUB_TOKEN_SECRET_NAME so switching to an org machine token
#      later (e.g. a secret named FLOXHUB_MACHINE_TOKEN) is a config
#      change, not a rewrite (issue #16 §9 step 5).
# No interactive fallback either way — same discipline as
# scripts/floxhub-login.sh. The token is never echoed or logged here; it's
# handed to floxhub-login.sh purely via the FLOXHUB_TOKEN env var, which
# owns the mktemp/umask/trap/shred handling.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${FLOXHUB_TOKEN:-}" ]] && command -v infisical >/dev/null 2>&1; then
  SECRET_NAME="${FLOXHUB_TOKEN_SECRET_NAME:-FLOXHUB_TOKEN}"
  if TOKEN_FROM_INFISICAL="$(infisical secrets get "${SECRET_NAME}" --plain 2>/dev/null)" &&
    [[ -n "${TOKEN_FROM_INFISICAL}" ]]; then
    export FLOXHUB_TOKEN="${TOKEN_FROM_INFISICAL}"
  fi
  unset -v TOKEN_FROM_INFISICAL
fi

if [[ -z "${FLOXHUB_TOKEN:-}" ]]; then
  echo "error: FLOXHUB_TOKEN is not set, and no usable token was found via Infisical (secret name: ${FLOXHUB_TOKEN_SECRET_NAME:-FLOXHUB_TOKEN})." >&2
  echo "Set FLOXHUB_TOKEN to a token from 'flox auth token' (run on an already-authenticated machine) and re-run." >&2
  exit 1
fi

bash "${SCRIPT_DIR}/floxhub-login.sh"

flox activate --dir "${REPO_ROOT}/envs/floxhub-provision" --mode run -- true
