#!/usr/bin/env bash
# Opt-in Phase D MVP setup-script recipe (issue #16 §9): obtain a FloxHub
# token and activate the combined envs/floxhub-provision manifest
# (uv/dolt/infisical/gh/git + bd + roborev). This IS the recipe eventually
# meant for gtm-sdk/scripts/conductor-workspace-setup.sh — proven here
# first, per issue #16 §8; ported there separately, later.
#
# Uses Flox's own documented CI pattern (flox.dev/docs/tutorials/ci-cd):
# export FLOX_FLOXHUB_TOKEN and let the Flox CLI read it directly on every
# invocation that needs FloxHub auth (activate, install, etc.) — no `flox
# auth login` step, no credential written to the keyring or to disk, no
# persistent sandbox state at all. Confirmed working (2026-08-03): a fresh,
# never-logged-in $HOME can `flox activate` a manifest with personal-catalog
# pkg-path packages (elvis/bd, elvis/roborev) using only this env var.
# Superseded scripts/floxhub-login.sh's --token-file + mktemp/shred dance,
# which is no longer used by this script (kept standalone for the separate
# opt-in *publisher* login use case it documents).
#
# NEVER call this from `.conductor/settings.toml`'s setup script or from
# `scripts/sandbox-test.sh`'s default path: authenticating a sandbox
# permanently disqualifies it from ever being the unauthenticated Stage 4
# (H4) tester.
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
#      via FLOXHUB_TOKEN_SECRET_NAME so switching credentials later (e.g. a
#      differently-named service-account secret) is a config change, not a
#      rewrite.
# No interactive fallback either way. The token is read into
# FLOX_FLOXHUB_TOKEN for this script's own process environment only — never
# echoed, logged, or written to a file.
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
  echo "Set FLOXHUB_TOKEN to a token from 'flox auth token' (run on an already-authenticated machine, ideally a dedicated service account per Flox's CI docs) and re-run." >&2
  exit 1
fi

export FLOX_FLOXHUB_TOKEN="${FLOXHUB_TOKEN}"
flox activate --dir "${REPO_ROOT}/envs/floxhub-provision" --mode run -- true
