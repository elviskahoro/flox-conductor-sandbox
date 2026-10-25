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
#   7. PI_PIN + PI_INTEGRITY (issue #85): single-home pins with no Flox
#      counterpart — both must be present and non-empty, the pin an exact
#      x.y.z (same shape rule as check 6), the integrity
#      must look like `sha512-<base64>` (the npm registry `dist.integrity`
#      field shape), and the pin must match the same package the URL pins
#      (a re-pin that leaves the URL stale would download a different
#      tarball than the integrity verifies).
#   8. PI_NODE_MIN + PI_NODE_MIN_PIN (issue #85): a major.minor Node floor,
#      recorded against the pin it was read from, which must equal PI_PIN.
#   9. ENTIRE_PIN (issue #91): exactly x.y.z, like pi's pin shape. The four
#      ENTIRE_SHA256_<platform> constants must all be present and hex-64; a
#      missing constant makes the runtime install fail closed on that
#      platform, so the CI check is presence-and-shape, not cross-check.
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

# 7. PI_PIN + PI_INTEGRITY + PI_TARBALL_URL (issue #85): all three must
# be present in the startup script, the integrity must look like the
# `sha512-<base64>` shape the npm registry emits, and the URL must embed
# the same PI_PIN (a re-pin that left the URL stale would download a
# different tarball than the integrity verifies).
# pi_sri_bytes <base64>: decoded byte count (macOS 12 and older spell the
# decode flag -D).
pi_sri_bytes() {
  { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; } | wc -c | tr -d ' '
}
PI_PIN_VALUE="$(sed -n 's/^PI_PIN="\([^"]*\)".*/\1/p' "${STARTUP}")"
PI_INTEGRITY_VALUE="$(sed -n 's/^PI_INTEGRITY="\([^"]*\)".*/\1/p' "${STARTUP}")"
PI_TARBALL_URL_VALUE="$(sed -n 's/^PI_TARBALL_URL="\([^"]*\)".*/\1/p' "${STARTUP}")"
# Literal spot match against '${PI_PIN}' on the left is exactly what this
# check exists to verify — keep both branches (slash-shape AND literal-
# variable-shape) because a re-pin could leave the URL in either form.
# shellcheck disable=SC2016,SC1073
if [[ -z "${PI_PIN_VALUE}" || -z "${PI_INTEGRITY_VALUE}" || -z "${PI_TARBALL_URL_VALUE}" ]]; then
  fail "PI_PIN/PI_INTEGRITY/PI_TARBALL_URL" "one or more missing: pin=${PI_PIN_VALUE:-<missing>}, integrity=${PI_INTEGRITY_VALUE:-<missing>}, url=${PI_TARBALL_URL_VALUE:-<missing>}"
elif ! [[ "${PI_PIN_VALUE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "PI_PIN" "not an exact x.y.z pin: ${PI_PIN_VALUE}"
elif ! [[ "${PI_INTEGRITY_VALUE}" =~ ^sha512-[A-Za-z0-9+/=]+$ ]]; then
  fail "PI_INTEGRITY" "not an sha512 SRI string: ${PI_INTEGRITY_VALUE:0:24}... (expected sha512-<base64>)"
elif [[ "$(pi_sri_bytes "${PI_INTEGRITY_VALUE#sha512-}")" != 64 ]]; then
  # Same invariant the startup script's sri_to_hex enforces at runtime: a
  # shape-valid but truncated pin must fail here, not in a sandbox.
  fail "PI_INTEGRITY" "does not decode to a 64-byte sha512 digest: ${PI_INTEGRITY_VALUE:0:24}..."
elif [[ "${PI_TARBALL_URL_VALUE}" != *'${PI_PIN}'* ]] && [[ "${PI_TARBALL_URL_VALUE}" != *"/pi-coding-agent-${PI_PIN_VALUE}.tgz"* ]]; then
  fail "PI_TARBALL_URL" "does not embed PI_PIN (${PI_PIN_VALUE}); URL=${PI_TARBALL_URL_VALUE} — a re-pin must update both"
else
  pass "PI_PIN" "exact pin ${PI_PIN_VALUE}"
  pass "PI_INTEGRITY" "sha512 SRI pin (${PI_INTEGRITY_VALUE:0:18}...) paired with pi-coding-agent-${PI_PIN_VALUE}.tgz"
fi

# 8. PI_NODE_MIN + PI_NODE_MIN_PIN (issue #85): the Node floor gating the pi
# SKIP comes from the pinned package's `engines`, which only a re-pinner can
# re-read. PI_NODE_MIN must be a major.minor floor, and PI_NODE_MIN_PIN (the
# pin it was read from) must equal PI_PIN, so a re-pin fails CI until the
# floor has been revisited.
PI_NODE_MIN_VALUE="$(sed -n 's/^PI_NODE_MIN="\([^"]*\)".*/\1/p' "${STARTUP}")"
PI_NODE_MIN_PIN_VALUE="$(sed -n 's/^PI_NODE_MIN_PIN="\([^"]*\)".*/\1/p' "${STARTUP}")"
if ! [[ "${PI_NODE_MIN_VALUE}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  fail "PI_NODE_MIN" "not a major.minor Node floor: ${PI_NODE_MIN_VALUE:-<missing>}"
elif [[ "${PI_NODE_MIN_PIN_VALUE}" != "${PI_PIN_VALUE}" ]]; then
  fail "PI_NODE_MIN_PIN" "floor was read from pi ${PI_NODE_MIN_PIN_VALUE:-<missing>} but PI_PIN is ${PI_PIN_VALUE:-<missing>} — re-check \`npm view @earendil-works/pi-coding-agent@${PI_PIN_VALUE} engines\` and update both"
else
  pass "PI_NODE_MIN" "Node >=${PI_NODE_MIN_VALUE} (read from pi ${PI_NODE_MIN_PIN_VALUE})"
fi

# 9. ENTIRE_PIN + ENTIRE_SHA256_* (issue #91). ENTIRE_PIN must be a
# non-floating x.y.z, exactly like pi's. The four per-platform SHA256
# constants must each be present and a 64-char lowercase hex string — the
# runtime install fails closed on any missing entry, so the CI check just
# catches that case earlier, before a sandbox sees it. The tarball URL is
# derived inline from ENTIRE_PIN (no separate constant to drift), so it
# stays in sync by construction; no extra cross-check needed there.
ENTIRE_PIN_VALUE="$(sed -n 's/^ENTIRE_PIN="\([^"]*\)".*/\1/p' "${STARTUP}")"
if ! [[ "${ENTIRE_PIN_VALUE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "ENTIRE_PIN" "missing or not an exact x.y.z pin: ${ENTIRE_PIN_VALUE:-<missing>}"
else
  pass "ENTIRE_PIN" "exact pin ${ENTIRE_PIN_VALUE}"
fi
for plat in LINUX_AMD64 LINUX_ARM64 DARWIN_AMD64 DARWIN_ARM64; do
  hash_value="$(sed -n "s/^ENTIRE_SHA256_${plat}=\"\([0-9a-f]*\)\".*/\1/p" "${STARTUP}")"
  if [[ -z "${hash_value}" ]]; then
    fail "ENTIRE_SHA256_${plat}" "missing — required for issue #91's entire install on platform ${plat,,}"
  elif ! [[ "${hash_value}" =~ ^[0-9a-f]{64}$ ]]; then
    fail "ENTIRE_SHA256_${plat}" "not a 64-char lowercase hex sha256: ${hash_value}"
  else
    pass "ENTIRE_SHA256_${plat}" "pinned (${hash_value:0:12}...)"
  fi
done

if [[ ${FAILED} -ne 0 ]]; then
  log "pin validation FAILED"
  exit 1
fi
log "pin validation passed"
