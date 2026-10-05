#!/usr/bin/env bash
# Provision a headless trunk login so `trunk merge` works without a browser
# (issue #40 Workstream B / gtm-sdk#702).
#
# `trunk check` is fully unauthenticated (findings/20261005-141227Z-trunk-
# cli-env-var-setup-mechanics.md), but `trunk merge` has NO env-var auth: no
# TRUNK_TOKEN/TRUNK_API_TOKEN equivalent exists for the merge CLI (verified
# empirically against the 1.25.0 binary -- a set TRUNK_TOKEN is ignored --
# and `trunk login` is browser-only). The one non-interactive path is the
# login file itself: trunk reads its session token from
# ~/.cache/trunk/user.yaml, and a copy provisioned from elsewhere
# authenticates fully (proven live, including the Infisical round-trip:
# findings/20261005-152730Z-trunk-merge-headless-auth.md).
#
# This is the by-hand form of that recipe -- the startup script's
# STARTUP_TRUNK_MERGE_AUTH=1 stage carries the wired form (issue #40),
# inlined so the paste-ready script stays self-contained for repos with
# no checkout of this one. Run this helper by hand wherever a headless
# sandbox (or any machine) needs merge-queue access without re-running
# the whole startup script:
#
#   bash scripts/trunk-merge-auth.sh
#
# The two forms are dual homes of one recipe, and
# scripts/conductor-startup-script-cloud-test.sh's RUN 18 asserts they
# install byte-identical files for the same TRUNK_USER_YAML -- the same
# drift guard validate-pins.sh plays for the duplicated pins.
#
# Login-file lifecycle: an operator runs `trunk login` once on an
# authenticated machine and stores the file's contents in Infisical as
# TRUNK_USER_YAML (overridable below). The yaml carries a session access
# token with NO refresh token -- when it expires, merge reports
# not-logged-in; re-login on the authenticated machine and re-store the
# secret (same rotation posture as FLOXHUB_TOKEN).
#
# Lookup order (this workspace's secrets-management convention, identical to
# scripts/floxhub-provision.sh): TRUNK_USER_YAML already in the environment
# first, then `infisical secrets get ${TRUNK_USER_YAML_SECRET_NAME:-TRUNK_USER_YAML}
# --plain` when the infisical CLI is on PATH (machine identity INFISICAL_TOKEN
# required; --projectId passed when INFISICAL_PROJECT_ID is set, since a
# fresh workspace has no .infisical.json context). No interactive fallback.
#
# Safety properties, all load-bearing:
#   - never clobbers an existing login: an interactive `trunk login` on the
#     machine is strictly better than a provisioned copy, so this script is
#     a no-op when ~/.cache/trunk/user.yaml already exists;
#   - the yaml is a bearer credential: it is written only to a 0600 file --
#     never echoed, logged, or passed through argv;
#   - shape-checked before install (a trunk_user key must be present) so a
#     wrong-pasted secret fails loudly here instead of as a mysteriously
#     logged-out trunk later;
#   - idempotent and safe to re-run; same sandbox rules as every
#     provisioning script here (no process substitution, plain redirects).
#
# Verify afterwards from a repo that actually has a Trunk merge queue (this
# repo does not -- "User not authorized" there means the repo, not the
# token): e.g. in a gtm-sdk checkout, `trunk merge status` should render the
# real queue. `trunk check` needs none of this, by design.
set -euo pipefail

TRUNK_USER_YAML_PATH="${HOME}/.cache/trunk/user.yaml"

if [[ -f "${TRUNK_USER_YAML_PATH}" ]]; then
  echo "trunk login already present at ${TRUNK_USER_YAML_PATH} — leaving it untouched (re-run after removing it to force re-provisioning)."
  exit 0
fi

if [[ -z "${TRUNK_USER_YAML:-}" ]] && command -v infisical >/dev/null 2>&1 &&
  [[ -n "${INFISICAL_TOKEN:-}" ]]; then
  SECRET_NAME="${TRUNK_USER_YAML_SECRET_NAME:-TRUNK_USER_YAML}"
  INFISICAL_ARGS=(--env="${INFISICAL_ENV:-dev}" --plain --silent)
  if [[ -n "${INFISICAL_PROJECT_ID:-}" ]]; then
    INFISICAL_ARGS+=(--projectId "${INFISICAL_PROJECT_ID}")
  fi
  if YAML_FROM_INFISICAL="$(infisical secrets get "${SECRET_NAME}" "${INFISICAL_ARGS[@]}" 2>/dev/null)" &&
    [[ -n "${YAML_FROM_INFISICAL}" ]]; then
    TRUNK_USER_YAML="${YAML_FROM_INFISICAL}"
    TRUNK_LOGIN_SOURCE="Infisical (${SECRET_NAME})"
  fi
  unset -v YAML_FROM_INFISICAL
fi

if [[ -z "${TRUNK_USER_YAML:-}" ]]; then
  echo "error: TRUNK_USER_YAML is not set, and no login file was found via Infisical (secret name: ${TRUNK_USER_YAML_SECRET_NAME:-TRUNK_USER_YAML})." >&2
  echo "On an authenticated machine, run 'trunk login', then store the contents of ~/.cache/trunk/user.yaml as the TRUNK_USER_YAML secret (Infisical) and re-run." >&2
  exit 1
fi

# Write through a 0600 temp file, shape-check it, then atomically install.
TRUNK_YAML_TMP="$(mktemp)"
chmod 600 "${TRUNK_YAML_TMP}"
printf '%s\n' "${TRUNK_USER_YAML}" >"${TRUNK_YAML_TMP}"
if ! grep -q "trunk_user" "${TRUNK_YAML_TMP}"; then
  rm -f "${TRUNK_YAML_TMP}"
  echo "error: the resolved TRUNK_USER_YAML did not look like a trunk login file (no trunk_user key) — not installed. Check the secret's value." >&2
  exit 1
fi
mkdir -p "${HOME}/.cache/trunk"
chmod 700 "${HOME}/.cache/trunk" 2>/dev/null || true
mv -f "${TRUNK_YAML_TMP}" "${TRUNK_USER_YAML_PATH}"
echo "provisioned headless trunk login at ${TRUNK_USER_YAML_PATH} (0600) from ${TRUNK_LOGIN_SOURCE:-the environment}"
