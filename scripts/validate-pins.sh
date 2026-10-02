#!/usr/bin/env bash
# Pin-sync validation for the cloud-install provisioning pins.
#
# The roborev version + sha256 pins and the trunk launcher checksum are
# deliberately duplicated across files (roborev review finding: previously
# only comments kept them in sync). This is the automated drift check — run
# in CI (.github/workflows/conductor-cloud-install.yml) and usable locally:
#
#   1. roborev version: scripts/conductor-cloud-install.sh's ROBOREV_PIN ==
#      envs/repackage's [build.roborev] version ==
#      envs/floxhub-provision's roborev.version (^-stripped)
#   2. roborev (platform, sha256) pairs: conductor-cloud-install.sh's case
#      block == envs/repackage's [build.roborev] assets, as sets
#   3. trunk launcher: TRUNK_LAUNCHER_SHA256 identical in
#      conductor-cloud-install.sh and conductor-trunk-preflight.sh
#
# rwx's pin has no in-repo counterpart (its sibling constant lives in the
# private gtm-sdk repo's conductor-workspace-setup.sh) — comment-synced
# only; reported as SKIP.
#
# No process substitution anywhere (gtm-sdk#279 — same rule as every other
# provisioning script in this repo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL="${REPO_ROOT}/scripts/conductor-cloud-install.sh"
PREFLIGHT="${REPO_ROOT}/scripts/conductor-trunk-preflight.sh"
REPACKAGE_MANIFEST="${REPO_ROOT}/envs/repackage/.flox/env/manifest.toml"
PROVISION_MANIFEST="${REPO_ROOT}/envs/floxhub-provision/.flox/env/manifest.toml"

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT HUP INT TERM

log() { printf '[validate-pins] %s\n' "$*"; }
FAILED=0

fail() { # <check> <detail>
  FAILED=1
  log "FAIL  $1 — $2"
}
pass() { log "PASS  $1 — $2"; }

# The roborev_stage function body, the only place in conductor-cloud-install.sh
# with roborev asset/sha256 pairs (the rwx stage has sha256s but no assets,
# and must stay out of this comparison).
awk '/^roborev_stage\(\)/,/^}$/' "${INSTALL}" >"${WORK}/stage"
# The [build.roborev] manifest section (up to the next table header).
awk 'BEGIN { f = 0 } /^\[build\.roborev\]$/ { f = 1; next } /^\[/ { f = 0 } f' \
  "${REPACKAGE_MANIFEST}" >"${WORK}/repackage_section"

# 1. roborev version across the three sources.
PIN="$(sed -n 's/^ROBOREV_PIN="\([^"]*\)".*/\1/p' "${INSTALL}")"
REPACKAGE_VERSION="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "${WORK}/repackage_section" | head -1)"
PROVISION_VERSION="$(sed -n 's/^roborev\.version *= *"\^\{0,1\}\([^"]*\)".*/\1/p' "${PROVISION_MANIFEST}")"
if [[ -n "${PIN}" && "${PIN}" == "${REPACKAGE_VERSION}" && "${PIN}" == "${PROVISION_VERSION}" ]]; then
  pass "roborev version" "pin ${PIN} == repackage ${REPACKAGE_VERSION} == floxhub-provision ^${PROVISION_VERSION}"
else
  fail "roborev version" "drift: conductor-cloud-install=${PIN:-<missing>}, repackage=${REPACKAGE_VERSION:-<missing>}, floxhub-provision=${PROVISION_VERSION:-<missing>}"
fi

# 2. roborev (platform, sha256) pairs as sets: asset=/sha256= lines strictly
# alternate in both sources, so zip the two ordered lists and sort. The
# greps are neutralized for set -e/pipefail (grep exits 1 on zero matches);
# a missing section then surfaces as a diff failure below, with a message,
# instead of a silent abort.
roborev_pairs() { # <source-file> <out-file>: sorted "<platform> <sha256>" lines
  grep -E 'asset="roborev_' "$1" >"${WORK}/asset_lines" || true
  grep -oE '(linux|darwin)_[a-z0-9]+\.tar\.gz' "${WORK}/asset_lines" >"${WORK}/platforms" || true
  grep -oE 'sha256="[0-9a-f]{64}"' "$1" >"${WORK}/sha_lines" || true
  sed 's/^sha256="//; s/"$//' "${WORK}/sha_lines" >"${WORK}/hashes"
  paste -d' ' "${WORK}/platforms" "${WORK}/hashes" | sort >"$2"
}
roborev_pairs "${WORK}/stage" "${WORK}/pairs_stage"
roborev_pairs "${WORK}/repackage_section" "${WORK}/pairs_manifest"
if diff -q "${WORK}/pairs_stage" "${WORK}/pairs_manifest" >/dev/null; then
  pass "roborev platform/sha256 pairs" "$(wc -l <"${WORK}/pairs_stage" | tr -d ' ') pinned pairs match envs/repackage's [build.roborev]"
else
  fail "roborev platform/sha256 pairs" "conductor-cloud-install.sh's case block != envs/repackage's [build.roborev]; diff: $(diff "${WORK}/pairs_stage" "${WORK}/pairs_manifest" | tr '\n' ' ')"
fi

# 3. trunk launcher checksum across the two downloader scripts. The
# preflight's constant is indented inside a branch, the install script's is
# top-level — tolerate leading whitespace in both.
INSTALL_LAUNCHER_SHA="$(sed -n 's/^[[:space:]]*TRUNK_LAUNCHER_SHA256="\([0-9a-f]\{64\}\)".*/\1/p' "${INSTALL}")"
PREFLIGHT_LAUNCHER_SHA="$(sed -n 's/^[[:space:]]*TRUNK_LAUNCHER_SHA256="\([0-9a-f]\{64\}\)".*/\1/p' "${PREFLIGHT}")"
if [[ -n "${INSTALL_LAUNCHER_SHA}" && "${INSTALL_LAUNCHER_SHA}" == "${PREFLIGHT_LAUNCHER_SHA}" ]]; then
  pass "trunk launcher sha256" "identical in conductor-cloud-install.sh and conductor-trunk-preflight.sh (${INSTALL_LAUNCHER_SHA:0:12}...)"
else
  fail "trunk launcher sha256" "drift or missing: conductor-cloud-install=${INSTALL_LAUNCHER_SHA:-<missing>}, preflight=${PREFLIGHT_LAUNCHER_SHA:-<missing>}"
fi

# 4. rwx: no in-repo counterpart to compare against.
RWX_PIN="$(sed -n 's/^RWX_PIN="\([^"]*\)".*/\1/p' "${INSTALL}")"
if [[ -n "${RWX_PIN}" ]]; then
  log "SKIP  rwx pin — ${RWX_PIN} has no in-repo counterpart (synced by comment with the private gtm-sdk repo's conductor-workspace-setup.sh)"
else
  fail "rwx pin" "RWX_PIN is missing from conductor-cloud-install.sh"
fi

if [[ ${FAILED} -ne 0 ]]; then
  log "pin validation FAILED"
  exit 1
fi
log "pin validation passed"
