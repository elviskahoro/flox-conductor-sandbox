#!/usr/bin/env bash
# Pin-sync validation for the workspace startup provisioning pins.
#
# The roborev version + sha256 pins, the trunk launcher checksum, and the
# uv/pytest/reflex pins are deliberately duplicated across files (roborev
# review finding: previously only comments kept them in sync). This is the
# automated drift check — run in CI
# (.github/workflows/conductor-startup-script-cloud.yml) and usable
# locally:
#
#   1. roborev version: scripts/conductor-startup-script-cloud.sh's
#      ROBOREV_PIN == envs/repackage's [build.roborev] version ==
#      envs/floxhub-provision's roborev.version (^-stripped)
#   2. roborev (platform, sha256) pairs: the startup script's
#      roborev_install() case block == envs/repackage's [build.roborev]
#      assets, as sets
#   3. trunk launcher: TRUNK_LAUNCHER_SHA256 identical in the startup
#      script and scripts/conductor-trunk-preflight.sh
#   4. paste-safety of the startup script: no triple-double-quote sequences
#      and no backslash line-continuations anywhere in it — Conductor
#      serializes the GUI setup field into a TOML multiline string, and
#      either would corrupt the paste. Comment-enforced constraints rot
#      silently; this makes CI fail instead.
#   5. uv version (issue #44): the startup script's UV_PIN == envs/prebuilt
#      uv.version == envs/floxhub-provision uv.version — the Flox uv is a
#      separate (process-scoped) install of the same tool; two different
#      uv versions in one workspace is the same confusion class as the
#      roborev drift.
#   6. pytest/reflex pins (issue #44): single-home pins with no Flox
#      counterpart — the check is presence-and-shape, so an accidental
#      unpinning (empty, or a floating range instead of an exact x.y.z)
#      fails CI instead of silently floating.
#
# The former checks that cross-compared two in-repo scripts
# (conductor-cloud-install.sh vs conductor-startup-script.sh, before they
# merged into the single startup script) died with that merge: one file is
# now the only in-repo pin home. The remaining sync surfaces are the Flox
# manifests (checks 1-2, 5) and the trunk preflight (check 3). (gtm-sdk's
# former conductor-workspace-setup.sh sibling died with that repo's
# retirement of the script, gtm-sdk#944 — nothing to sync there anymore.)
#
# No process substitution anywhere (gtm-sdk#279 — same rule as every other
# provisioning script in this repo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STARTUP="${REPO_ROOT}/scripts/conductor-startup-script-cloud.sh"
PREFLIGHT="${REPO_ROOT}/scripts/conductor-trunk-preflight.sh"
REPACKAGE_MANIFEST="${REPO_ROOT}/envs/repackage/.flox/env/manifest.toml"
PROVISION_MANIFEST="${REPO_ROOT}/envs/floxhub-provision/.flox/env/manifest.toml"
PREBUILT_MANIFEST="${REPO_ROOT}/envs/prebuilt/.flox/env/manifest.toml"

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

# The roborev_install function body, the only place in the startup script
# with roborev asset/sha256 pairs (the rwx stage has sha256s but no assets,
# and must stay out of this comparison).
awk '/^roborev_install\(\)/,/^}$/' "${STARTUP}" >"${WORK}/roborev_install"
# The [build.roborev] manifest section (up to the next table header).
awk 'BEGIN { f = 0 } /^\[build\.roborev\]$/ { f = 1; next } /^\[/ { f = 0 } f' \
  "${REPACKAGE_MANIFEST}" >"${WORK}/repackage_section"

# 1. roborev version across the three sources.
PIN="$(sed -n 's/^ROBOREV_PIN="\([^"]*\)".*/\1/p' "${STARTUP}")"
REPACKAGE_VERSION="$(sed -n 's/^version = "\([^"]*\)".*/\1/p' "${WORK}/repackage_section" | head -1)"
PROVISION_VERSION="$(sed -n 's/^roborev\.version *= *"\^\{0,1\}\([^"]*\)".*/\1/p' "${PROVISION_MANIFEST}")"
if [[ -n "${PIN}" && "${PIN}" == "${REPACKAGE_VERSION}" && "${PIN}" == "${PROVISION_VERSION}" ]]; then
  pass "roborev version" "pin ${PIN} == repackage ${REPACKAGE_VERSION} == floxhub-provision ^${PROVISION_VERSION}"
else
  fail "roborev version" "drift: startup-script=${PIN:-<missing>}, repackage=${REPACKAGE_VERSION:-<missing>}, floxhub-provision=${PROVISION_VERSION:-<missing>}"
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
roborev_pairs "${WORK}/roborev_install" "${WORK}/pairs_install"
roborev_pairs "${WORK}/repackage_section" "${WORK}/pairs_manifest"
# Non-empty guard first: two empty pair files would diff as a vacuous pass —
# exactly the silent failure a pin checker must never have.
if [[ ! -s "${WORK}/pairs_install" || ! -s "${WORK}/pairs_manifest" ]]; then
  fail "roborev platform/sha256 pairs" "extraction produced no pairs (startup=$(wc -l <"${WORK}/pairs_install" | tr -d ' '), manifest=$(wc -l <"${WORK}/pairs_manifest" | tr -d ' ')) — sed/awk pattern drift?"
elif diff -q "${WORK}/pairs_install" "${WORK}/pairs_manifest" >/dev/null; then
  pass "roborev platform/sha256 pairs" "$(wc -l <"${WORK}/pairs_install" | tr -d ' ') pinned pairs match envs/repackage's [build.roborev]"
else
  fail "roborev platform/sha256 pairs" "startup script's roborev_install() != envs/repackage's [build.roborev]; diff: $(diff "${WORK}/pairs_install" "${WORK}/pairs_manifest" | tr '\n' ' ')"
fi

# 3. trunk launcher checksum across the startup script and the preflight.
# The preflight's constant is indented inside a branch, the startup
# script's is top-level — tolerate leading whitespace in both.
STARTUP_LAUNCHER_SHA="$(sed -n 's/^[[:space:]]*TRUNK_LAUNCHER_SHA256="\([0-9a-f]\{64\}\)".*/\1/p' "${STARTUP}")"
PREFLIGHT_LAUNCHER_SHA="$(sed -n 's/^[[:space:]]*TRUNK_LAUNCHER_SHA256="\([0-9a-f]\{64\}\)".*/\1/p' "${PREFLIGHT}")"
if [[ -n "${STARTUP_LAUNCHER_SHA}" && "${STARTUP_LAUNCHER_SHA}" == "${PREFLIGHT_LAUNCHER_SHA}" ]]; then
  pass "trunk launcher sha256" "identical in conductor-startup-script-cloud.sh and conductor-trunk-preflight.sh (${STARTUP_LAUNCHER_SHA:0:12}...)"
else
  fail "trunk launcher sha256" "drift or missing: startup-script=${STARTUP_LAUNCHER_SHA:-<missing>}, preflight=${PREFLIGHT_LAUNCHER_SHA:-<missing>}"
fi

# 4. Paste-safety of the startup script. Its whole purpose includes being
# pasted into Conductor's GUI setup field, which Conductor serializes into
# a TOML multiline string — a triple-double-quote would terminate the
# string early and a backslash line-continuation would join lines with
# leading whitespace stripped. Both are documented constraints in the
# script's header; this turns them into a CI-enforced invariant.
if grep -n '"""' "${STARTUP}" >/dev/null; then
  fail "startup paste-safety" "triple-double-quote sequence present — TOML multiline hazard for the GUI paste"
elif grep -nE '\\$' "${STARTUP}" >/dev/null; then
  fail "startup paste-safety" "backslash line-continuation present — TOML multiline hazard for the GUI paste"
else
  pass "startup paste-safety" "no triple-double-quotes, no backslash line-continuations"
fi

# 5. uv version across the startup script and the two Flox manifests that
# pin it (issue #44). The manifests' uv is a process-scoped activation
# install; the startup script's UV_PIN is the persistent PATH binary —
# different installs of the SAME tool, so version drift between them is
# exactly the confusion the roborev check above exists to prevent.
UV_PIN_V="$(sed -n 's/^UV_PIN="\([^"]*\)".*/\1/p' "${STARTUP}")"
PREBUILT_UV="$(sed -n 's/^uv\.version *= *"\([^"]*\)".*/\1/p' "${PREBUILT_MANIFEST}")"
PROVISION_UV="$(sed -n 's/^uv\.version *= *"\([^"]*\)".*/\1/p' "${PROVISION_MANIFEST}")"
if [[ -n "${UV_PIN_V}" && "${UV_PIN_V}" == "${PREBUILT_UV}" && "${UV_PIN_V}" == "${PROVISION_UV}" ]]; then
  pass "uv version" "pin ${UV_PIN_V} == prebuilt ${PREBUILT_UV} == floxhub-provision ${PROVISION_UV}"
else
  fail "uv version" "drift: startup-script=${UV_PIN_V:-<missing>}, prebuilt=${PREBUILT_UV:-<missing>}, floxhub-provision=${PROVISION_UV:-<missing>}"
fi

# 6. pytest/reflex pins (issue #44): single-home pins (no Flox
# counterpart), so there is nothing to cross-check — the invariant is
# that they stay EXACT x.y.z pins in the startup script. An empty value
# or a floating spec (>=, ~=, ^) must fail CI rather than silently float;
# a pre/post release (e.g. 9.1.1rc1) also fails, forcing a deliberate
# pin decision instead of an accidental one.
for pin_name in PYTEST_PIN REFLEX_PIN; do
  pin_value="$(sed -n "s/^${pin_name}=\"\([^\"]*\)\".*/\1/p" "${STARTUP}")"
  if [[ "${pin_value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "${pin_name}" "exact pin ${pin_value}"
  else
    fail "${pin_name}" "missing or not an exact x.y.z pin: ${pin_value:-<missing>}"
  fi
done

if [[ ${FAILED} -ne 0 ]]; then
  log "pin validation FAILED"
  exit 1
fi
log "pin validation passed"
