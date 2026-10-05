#!/usr/bin/env bash
# Opt-in Phase D MVP setup-script recipe (issue #16 §9 / issue #40): obtain
# a FloxHub token and activate a combined manifest
# (uv/dolt/infisical/gh/git + bd + roborev by default; any repo's committed
# .flox env via FLOXHUB_ACTIVATE_DIR). This IS the executable reference for
# the startup script's deferred flox stages — proven here first, per issue
# #16 §8. (It was originally meant to be ported into gtm-sdk's own setup
# script; that repo instead retired the script entirely, gtm-sdk#944, and
# the recipe stays here.)
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
#   # the activated manifest defaults to this repo's envs/floxhub-provision;
#   # point FLOXHUB_ACTIVATE_DIR at any repo's committed .flox env to prove
#   # the same token->activation recipe against that repo instead (the
#   # host-repo activation shape the startup script's deferred flox stage
#   # is built from -- e.g. a gtm-sdk checkout, whose manifest resolves
#   # elvis/roborev from the same private catalog):
#   FLOXHUB_ACTIVATE_DIR=/path/to/gtm-sdk bash scripts/floxhub-provision.sh
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
  INFISICAL_ARGS=(--env="${INFISICAL_ENV:-dev}" --plain --silent)
  # A fresh Conductor workspace has no Infisical project context file. Pass
  # the project explicitly when the machine-identity variables are present;
  # the token remains an environment variable so it never appears in a
  # process argument list or in setup logs.
  if [[ -n "${INFISICAL_PROJECT_ID:-}" ]]; then
    INFISICAL_ARGS+=(--projectId "${INFISICAL_PROJECT_ID}")
  fi
  if TOKEN_FROM_INFISICAL="$(infisical secrets get "${SECRET_NAME}" "${INFISICAL_ARGS[@]}" 2>/dev/null)" &&
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

# Validate the token up front so a bad/expired FLOXHUB_TOKEN surfaces as an
# unambiguous auth error here, rather than as a generic flox activate
# failure indistinguishable from a manifest/build/publish-availability
# problem downstream.
if ! flox auth status >/dev/null 2>&1; then
  echo "error: FLOX_FLOXHUB_TOKEN was not accepted by FloxHub (invalid or expired token)." >&2
  exit 1
fi

flox activate --dir "${FLOXHUB_ACTIVATE_DIR:-${REPO_ROOT}/envs/floxhub-provision}" --mode run -- true
