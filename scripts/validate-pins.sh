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
#   4. roborev pins vs the generic paste script:
#      conductor-roborev-rwx-setup.sh's roborev_install() carries the same
#      ROBOREV_PIN and (platform, sha256) pairs as conductor-cloud-install.sh
#      — it provisions the same binary for repos with no committed setup
#   5. rwx pins likewise: RWX_PIN and the (platform, sha256) pairs in its
#      rwx_install() == conductor-cloud-install.sh's rwx_stage(). The
#      generic script is the in-repo rwx counterpart this check previously
#      reported SKIP for lacking (the sibling constant also lives in the
#      private gtm-sdk repo's conductor-workspace-setup.sh — comment-synced
#      there, machine-checked here).
#   6. paste-safety of the generic script: no triple-double-quote sequences
#      and no backslash line-continuations anywhere in it — Conductor
#      serializes the GUI setup field into a TOML multiline string, and
#      either would corrupt the paste. Comment-enforced constraints rot
#      silently; this makes CI fail instead.
#
# No process substitution anywhere (gtm-sdk#279 — same rule as every other
# provisioning script in this repo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL="${REPO_ROOT}/scripts/conductor-cloud-install.sh"
PREFLIGHT="${REPO_ROOT}/scripts/conductor-trunk-preflight.sh"
GENERIC="${REPO_ROOT}/scripts/conductor-roborev-rwx-setup.sh"
REPACKAGE_MANIFEST="${REPO_ROOT}/envs/repackage/.flox/env/manifest.toml"
PROVISION_MANIFEST="${REPO_ROOT}/envs/floxhub-provision/.flox/env/manifest.toml"

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
# EXIT does the cleanup; the signal traps exit with the conventional codes
# instead — a cleanup-only trap lets bash resume the script with WORK
# already deleted, and the next redirect into WORK then dies confusingly
# under set -e (the same finding fixed in the generic setup script).
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
# Function bodies the generic-vs-install checks (4-5) compare: the generic
# paste script's roborev_install()/rwx_install() and conductor-cloud-install
# .sh's rwx_stage() (its roborev_stage is already extracted above).
awk '/^roborev_install\(\)/,/^}$/' "${GENERIC}" >"${WORK}/generic_roborev"
awk '/^rwx_install\(\)/,/^}$/' "${GENERIC}" >"${WORK}/generic_rwx"
awk '/^rwx_stage\(\)/,/^}$/' "${INSTALL}" >"${WORK}/rwx_stage"
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

# 4. roborev pins vs the generic paste script — same binary, second file:
#    exactly the drift class this whole script exists for.
GENERIC_ROBOREV_PIN="$(sed -n 's/^ROBOREV_PIN="\([^"]*\)".*/\1/p' "${GENERIC}")"
if [[ -n "${GENERIC_ROBOREV_PIN}" && "${GENERIC_ROBOREV_PIN}" == "${PIN}" ]]; then
  pass "generic roborev version" "conductor-roborev-rwx-setup.sh pin ${GENERIC_ROBOREV_PIN} == conductor-cloud-install.sh ${PIN}"
else
  fail "generic roborev version" "drift: generic=${GENERIC_ROBOREV_PIN:-<missing>}, conductor-cloud-install=${PIN:-<missing>}"
fi
roborev_pairs "${WORK}/generic_roborev" "${WORK}/pairs_generic_roborev"
# Non-empty guard first: two empty pair files would diff as a vacuous pass —
# exactly the silent failure a pin checker must never have.
if [[ ! -s "${WORK}/pairs_stage" || ! -s "${WORK}/pairs_generic_roborev" ]]; then
  fail "generic roborev platform/sha256 pairs" "extraction produced no pairs (pairs_stage=$(wc -l <"${WORK}/pairs_stage" | tr -d ' '), generic=$(wc -l <"${WORK}/pairs_generic_roborev" | tr -d ' ')) — sed/awk pattern drift?"
elif diff -q "${WORK}/pairs_stage" "${WORK}/pairs_generic_roborev" >/dev/null; then
  pass "generic roborev platform/sha256 pairs" "conductor-roborev-rwx-setup.sh's roborev_install() case block matches conductor-cloud-install.sh's"
else
  fail "generic roborev platform/sha256 pairs" "conductor-roborev-rwx-setup.sh != conductor-cloud-install.sh; diff: $(diff "${WORK}/pairs_stage" "${WORK}/pairs_generic_roborev" | tr '\n' ' ')"
fi

# 5. rwx pins vs the generic paste script. Case lines pair platform and
#    sha256 on one line, so extract with sed instead of the paste-based
#    helper; sorted, so this is a set comparison like check 2.
RWX_PIN="$(sed -n 's/^RWX_PIN="\([^"]*\)".*/\1/p' "${INSTALL}")"
GENERIC_RWX_PIN="$(sed -n 's/^RWX_PIN="\([^"]*\)".*/\1/p' "${GENERIC}")"
rwx_pairs() { # <rwx-stage-body> <out-file>: sorted "<platform> <sha256>" lines
  sed -n 's/^[[:space:]]*\([a-z0-9]*-[a-z0-9_]*\)) sha256="\([0-9a-f]\{64\}\)".*/\1 \2/p' "$1" | sort >"$2"
}
rwx_pairs "${WORK}/rwx_stage" "${WORK}/pairs_rwx_install"
rwx_pairs "${WORK}/generic_rwx" "${WORK}/pairs_rwx_generic"
if [[ -n "${RWX_PIN}" && "${RWX_PIN}" == "${GENERIC_RWX_PIN}" ]]; then
  pass "rwx version" "RWX_PIN ${RWX_PIN} identical in conductor-cloud-install.sh and conductor-roborev-rwx-setup.sh"
else
  fail "rwx version" "drift or missing: conductor-cloud-install=${RWX_PIN:-<missing>}, generic=${GENERIC_RWX_PIN:-<missing>}"
fi
if [[ ! -s "${WORK}/pairs_rwx_install" || ! -s "${WORK}/pairs_rwx_generic" ]]; then
  fail "rwx platform/sha256 pairs" "extraction produced no pairs (install=$(wc -l <"${WORK}/pairs_rwx_install" | tr -d ' '), generic=$(wc -l <"${WORK}/pairs_rwx_generic" | tr -d ' ')) — sed pattern drift?"
elif diff -q "${WORK}/pairs_rwx_install" "${WORK}/pairs_rwx_generic" >/dev/null; then
  pass "rwx platform/sha256 pairs" "$(wc -l <"${WORK}/pairs_rwx_install" | tr -d ' ') pinned pairs identical in both scripts"
else
  fail "rwx platform/sha256 pairs" "conductor-cloud-install.sh's rwx_stage() != conductor-roborev-rwx-setup.sh's rwx_install(); diff: $(diff "${WORK}/pairs_rwx_install" "${WORK}/pairs_rwx_generic" | tr '\n' ' ')"
fi

# 6. Paste-safety of the generic script. Its whole purpose is to be pasted
#    into Conductor's GUI setup field, which Conductor serializes into a
#    TOML multiline string — a triple-double-quote would terminate the
#    string early and a backslash line-continuation would join lines with
#    leading whitespace stripped. Both are documented constraints in the
#    script's header; this turns them into a CI-enforced invariant.
if grep -n '"""' "${GENERIC}" >/dev/null; then
  fail "generic paste-safety" "triple-double-quote sequence present — TOML multiline hazard for the GUI paste"
elif grep -nE '\\$' "${GENERIC}" >/dev/null; then
  fail "generic paste-safety" "backslash line-continuation present — TOML multiline hazard for the GUI paste"
else
  pass "generic paste-safety" "no triple-double-quotes, no backslash line-continuations"
fi

if [[ ${FAILED} -ne 0 ]]; then
  log "pin validation FAILED"
  exit 1
fi
log "pin validation passed"
