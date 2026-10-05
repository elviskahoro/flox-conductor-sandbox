#!/usr/bin/env bash
# shellcheck disable=SC2312  # $(...) in assignments and rows: stage failures surface through the stages' own || returns and the summary, not by killing the script mid-row
# The single Conductor workspace startup script: roborev + trunk + rwx +
# Python 3.11, then the auth/init that makes them work rather than merely
# exist.
#
# Two consumers, one file (it replaced the former conductor-cloud-install.sh
# + conductor-startup-script.sh pair, whose duplicated pins were exactly the
# drift class scripts/validate-pins.sh was built to catch — one file is the
# stronger guarantee):
#
#   1. This repo's own workspaces: .conductor/settings.toml runs it before
#      the harness. On the AL2023/Vercel sandbox class Conductor cloud
#      provisions (https://vercel.com/docs/sandbox/concepts/runtimes —
#      `dnf` for system packages, passwordless `sudo`, code running as the
#      `vercel-sandbox` user, sandbox proxy CA trusted system-wide so plain
#      `curl` works), AL2023's default `python3` is 3.9 while pyproject.toml
#      requires >=3.11 — hence the python stage. Vercel deprecates those
#      runtimes in favor of managed images, but Conductor cloud is still on
#      the AL2023 class, so `dnf` stays the system-package path.
#
#   2. Any other repo's workspaces: the canonical, version-controlled copy
#      of the paste-ready setup script for repos that have no committed
#      .conductor/settings.toml setup of their own — open the workspace/repo
#      settings in the Conductor GUI and paste this file's contents into the
#      setup-script field (stored there as scripts.setup — "Shell script run
#      when a workspace is created"). Conductor exposes no API for that
#      field, so the GUI paste is the only mechanism; this file exists so
#      the pasted text is reviewable and pin-checked instead of
#      hand-carried. It also runs standalone, unchanged:
#
#        bash scripts/conductor-startup-script-cloud.sh
#
#      Repo-agnostic by design: no repo paths, no repo scripts, nothing that
#      assumes a particular project — safe in any workspace, local or cloud.
#      The trunk and python stages are reuse-if-present and SKIP cleanly off
#      the target class, so pasting this into a repo that needs neither
#      costs nothing.
#
# What "work" means here, beyond the binaries landing on PATH:
#   roborev  installed (pinned, checksum-verified) + `git roborev` alias +
#            repo init when unconfigured (daemon started) + post-commit hook
#            ensured independently of init + agent smoke check. When
#            core.hooksPath points at a machine-global hooks dir (often
#            another tool's, e.g. git-lfs's), init is skipped too — roborev
#            init installs the hook itself — and no hook is ever written.
#   trunk    the official launcher, content-pinned by sha256: trunk
#            publishes no versioned launcher URL (trunk.io/releases/trunk
#            is latest-only), but the artifact is a portable bash script
#            that has been byte-stable since 2024-11-06 (S3 last-modified) —
#            fail closed on any upstream change, bump deliberately. What the
#            launcher then fetches is trunk's own managed update channel,
#            out of this script's control. Same download as
#            scripts/conductor-trunk-preflight.sh, which this repo's setup
#            runs first, so this stage is normally verify-only reuse there.
#   rwx      installed (pinned, checksum-verified) + token validated BEFORE
#            it is persisted (a bad token never overwrites a good one), so
#            every later shell is authenticated, not just setup.
#   python3.11  installed ALONGSIDE 3.9, never as a replacement, on the
#            AL2023 class only (see the stage body for the shadow-safety
#            facts); SKIP elsewhere. The only stage whose failure is a
#            stated requirement rather than a nice-to-have.
#
# Pins: ROBOREV_PIN/RWX_PIN and every sha256 below are the single in-repo
# home of those constants. The roborev pin is kept in sync with
# envs/repackage/.flox/env/manifest.toml's [build.roborev] and
# envs/floxhub-provision's roborev.version — scripts/validate-pins.sh
# cross-checks them in CI; bump runbook: new pin + sha256s from the
# release's checksums file, then republish the FloxHub package — don't
# hand-edit any lock. The rwx block's sibling copy in gtm-sdk's
# conductor-workspace-setup.sh (its PR #699) is comment-synced only — that
# repo is private, so no machine check can reach it; bump both together.
#
# Paste-safety constraints (load-bearing for consumer 2, because Conductor
# serializes the GUI setup field into a TOML multiline string): NO
# triple-double-quote sequences and NO backslash line-continuations
# anywhere in this file — a future editor must keep long commands on one
# line. Same sandbox rules as every provisioning script here: no process
# substitution (sandboxes can lack /dev/fd and `set -e` then kills the
# script silently, gtm-sdk#279); log to ~/.conductor-setup.log via a plain
# append redirect, not tee; idempotent (reuse-if-present, safe to re-run);
# one WORK dir cleaned by a single EXIT trap; per-stage failures recorded
# and summarized with the hard failure deferred to the very end so every
# stage still gets its chance to run and report.
#
# Failure semantics — two reviewed contracts, one file, one opt-in flag:
# by default any FAIL row fails the run (deferred to the end), the posture
# the paste-ready consumer was reviewed with: a roborev/rwx/auth failure
# in the tools a workspace exists for must fail setup loudly, not pass
# silently. This repo's own settings.toml instead opts into the
# best-effort posture its former cloud-install carried (gtm-sdk#702's
# fallback-installer idiom) by exporting STARTUP_BEST_EFFORT=1: then the
# tool stages (roborev/trunk/rwx install, rwx auth, roborev init) record
# their FAIL rows but do not fail the run, and only a Python 3.11 failure
# on the AL2023 target class (the stated >=3.11 requirement) exits
# non-zero.
#
# Environment variables (set them in Conductor's environment variables
# settings — never inline them in this script: settings values are plain
# strings with no masking):
#   RWX_ACCESS_TOKEN  RWX personal access token (cloud.rwx.com -> Settings ->
#                     Personal access tokens). Without it, rwx installs but
#                     stays unauthenticated (warning, not failure).
#   ROBOREV_AGENT     optional review-agent override; one of codex,
#                     claude-code, gemini, copilot, opencode, cursor, kiro,
#                     kilo. Defaults to claude-code, which Conductor cloud
#                     sandboxes ship pre-authenticated.
#   STARTUP_BEST_EFFORT  set to 1 (this repo's settings.toml does) to make
#                     the tool stages recorded-but-non-fatal; see the
#                     failure-semantics section above.
set -euo pipefail

# Save the original stdout/stderr as fd 3/4 BEFORE the log redirect: the
# summary and any final error are surfaced there as well, so a failing
# setup is visible wherever its output is presented, not only in the log
# file. Pure fd duplication — no process substitution (the /dev/fd rule).
exec 3>&1 4>&2
# APPEND, never truncate: this repo's .conductor/settings.toml already
# appends everything to this same file, and a standalone/pasted run must
# not wipe an earlier run's log either — each run's "=== setup started ==="
# header keeps the appended log readable run-by-run.
SETUP_LOG="$HOME/.conductor-setup.log"
touch "$SETUP_LOG"
exec >> "$SETUP_LOG" 2>&1
echo "=== setup started $(date -u +%FT%TZ) ==="

# ~/.local/bin is the no-sudo fallback install location; keep it on PATH for
# the rest of setup (later shells normally have it via the profile).
export PATH="${HOME}/.local/bin:${PATH}"

LOCAL_BIN="/usr/local/bin"
RESULTS=""
FAILED=0
# Tools that had to land in ~/.local/bin because /usr/local/bin was not
# writable and no passwordless sudo existed. They are NOT on the default
# PATH of later setup steps; the summary warns about them and callers must
# export ~/.local/bin (this repo's settings.toml does).
LOCAL_FALLBACK_TOOLS=""

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
# EXIT alone does the cleanup. The signal traps exist because a trap that
# only cleans up lets bash RESUME the script with WORK already deleted —
# later stages then fail confusingly — so they exit with the conventional
# codes instead, which re-triggers the EXIT trap (roborev review finding).
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log() { echo "[startup] $*"; }

record() { # <status> <name> <detail> — one summary row + one log line
  RESULTS="${RESULTS}
 ${2} | ${1} | ${3}"
  log "[${1}] ${2} — ${3}"
}

# note_placement <path>: record tools whose install landed in the
# ~/.local/bin fallback (see LOCAL_FALLBACK_TOOLS above).
note_placement() {
  case "$1" in
  "${HOME}/.local/bin/"*)
    LOCAL_FALLBACK_TOOLS="${LOCAL_FALLBACK_TOOLS} $(basename "$1")"
    ;;
  esac
}

# install_bin <src> <name>: place a file as an executable under
# /usr/local/bin (the convention this repo's setup already uses for
# roborev/infisical/trunk) when root or passwordless sudo allows it,
# else under ~/.local/bin. Echoes the installed path on success (nothing on
# failure).
install_bin() {
  local src="$1" name="$2" dir
  if [[ "$(id -u)" == 0 || -w "${LOCAL_BIN}" ]]; then
    install -m 755 "${src}" "${LOCAL_BIN}/${name}" || return 1
    dir="${LOCAL_BIN}"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo install -m 755 "${src}" "${LOCAL_BIN}/${name}" || return 1
    dir="${LOCAL_BIN}"
  else
    mkdir -p "${HOME}/.local/bin" || return 1
    install -m 755 "${src}" "${HOME}/.local/bin/${name}" || return 1
    dir="${HOME}/.local/bin"
  fi
  printf '%s' "${dir}/${name}"
  echo
}

# link_bin <target> <name>: symlink <name> -> <target> next to <target>
# (e.g. git-roborev -> roborev, so `git roborev ...` resolves as a native
# git subcommand). Derives the directory from <target> itself: callers run
# install_bin inside command substitution, so any directory state set there
# never propagates out.
link_bin() {
  local target="$1" name="$2" dir
  dir="$(dirname "${target}")"
  if [[ "$(id -u)" == 0 || -w "${dir}" ]]; then
    ln -sfn "${target}" "${dir}/${name}"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo ln -sfn "${target}" "${dir}/${name}"
  else
    ln -sfn "${target}" "${dir}/${name}"
  fi
}

# checksum_verify <sha256> <file>: works with sha256sum (AL2023) and
# `shasum -a 256` (macOS), which accept the same "<hash>  <file>" stdin form.
checksum_verify() {
  local expected="$1" file="$2"
  local tool="sha256sum"
  if ! command -v sha256sum >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
    tool="shasum -a 256"
  fi
  # shellcheck disable=SC2086  # intentional two-word command (shasum -a 256), not a path to quote
  if ! echo "${expected}  ${file}" | ${tool} -c - >/dev/null; then
    log "error: checksum mismatch for ${file} (expected ${expected})"
    return 1
  fi
}

# --- roborev ----------------------------------------------------------------
# Pinned release binary, fail-closed sha256 (same pins the sandbox repos
# cross-check in CI). Reuse-if-present keeps re-runs cheap. No FloxHub
# deferral here, deliberately (roborev review finding): this pinned binary
# is the guaranteed floor, installed immediately.
ROBOREV_PIN="0.63.0"

roborev_install() {
  if command -v roborev >/dev/null 2>&1; then
    record PASS roborev "reused $(command -v roborev) ($(roborev version 2>&1 | head -1 || true))"
    return 0
  fi
  local asset sha256
  case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    asset="roborev_${ROBOREV_PIN}_linux_amd64.tar.gz"
    sha256="c7dbbefed91747b80d04498358fa0207880adb7e2b57c95677214195a3ece887"
    ;;
  Linux-aarch64)
    asset="roborev_${ROBOREV_PIN}_linux_arm64.tar.gz"
    sha256="bcb1e96d13efb903a80f965581c23bcf8e6d39a92ded01bf8ee61a2e9e18fe71"
    ;;
  Darwin-arm64)
    asset="roborev_${ROBOREV_PIN}_darwin_arm64.tar.gz"
    sha256="696161b785d5bf45f635af993c4a32334c545a5d8747e41213356d33fe2fd5e1"
    ;;
  *)
    log "error: no pinned roborev asset for $(uname -s)-$(uname -m)"
    return 1
    ;;
  esac
  local dir="${WORK}/roborev"
  mkdir -p "${dir}"
  if ! curl -fsSLo "${dir}/${asset}" "https://github.com/kenn-io/roborev/releases/download/v${ROBOREV_PIN}/${asset}"; then
    return 1
  fi
  if ! checksum_verify "${sha256}" "${dir}/${asset}"; then
    return 1
  fi
  if ! tar -xzf "${dir}/${asset}" -C "${dir}" || [[ ! -x "${dir}/roborev" ]]; then
    log "error: roborev tarball did not yield an executable ./roborev"
    return 1
  fi
  local path
  path="$(install_bin "${dir}/roborev" roborev || true)"
  if [[ -z "${path}" ]]; then
    log "error: could not place the roborev binary in a bin directory"
    return 1
  fi
  note_placement "${path}"
  link_bin "${path}" git-roborev || true
  hash -r 2>/dev/null || true
  if ! command -v roborev >/dev/null 2>&1; then
    log "error: roborev installed at ${path} but not on PATH"
    return 1
  fi
  record PASS roborev "v${ROBOREV_PIN} (${path})"
}

# --- trunk ------------------------------------------------------------------
# Same launcher download as scripts/conductor-trunk-preflight.sh (which
# .conductor/settings.toml runs before this script in this repo, so this
# stage is normally verify-only reuse there; the preflight pins the same
# checksum — scripts/validate-pins.sh cross-checks the two constants). Kept
# inline so the script stays a self-contained recipe for pasting (the
# gtm-sdk#702 porting rationale).
TRUNK_LAUNCHER_URL="https://trunk.io/releases/trunk"
TRUNK_LAUNCHER_SHA256="89fbdd8c7b63649eeb1479415757b898903c041e73b49b78028dbd64eca3087a"
# Bump runbook: trunk publishes no versioned launcher URL, so re-download
# ${TRUNK_LAUNCHER_URL} by hand, re-hash it, and update this constant (and
# the preflight's copy) in the same commit.

trunk_stage() {
  if command -v trunk >/dev/null 2>&1; then
    record PASS trunk "reused $(command -v trunk) ($(trunk --version 2>&1 | head -1 || true))"
    return 0
  fi
  local launcher="${WORK}/trunk"
  if ! curl -fsSL "${TRUNK_LAUNCHER_URL}" -o "${launcher}"; then
    return 1
  fi
  if ! checksum_verify "${TRUNK_LAUNCHER_SHA256}" "${launcher}"; then
    return 1
  fi
  chmod 755 "${launcher}"
  local path
  path="$(install_bin "${launcher}" trunk || true)"
  if [[ -z "${path}" ]]; then
    log "error: could not place the trunk launcher in a bin directory"
    return 1
  fi
  note_placement "${path}"
  hash -r 2>/dev/null || true
  # The launcher bootstraps (downloads the real binary) on first invocation;
  # that cold start was observed to fail transiently once in a container
  # test, passing on the very next run — retry once before declaring
  # failure instead of recording a spurious FAIL on a fresh sandbox.
  if ! trunk --version >/dev/null 2>&1; then
    sleep 5
    if ! trunk --version >/dev/null 2>&1; then
      log "error: installed trunk launcher failed its version check (twice)"
      return 1
    fi
  fi
  record PASS trunk "launcher at ${path} ($(trunk --version 2>&1 | head -1 || true))"
}

# --- rwx --------------------------------------------------------------------
# Pinned static release binary (RWX is not in nixpkgs/Flox; their docs
# recommend pinning for scripted use). Reuse-if-present.
RWX_PIN="v3.33.0"

rwx_install() {
  if command -v rwx >/dev/null 2>&1; then
    record PASS rwx "reused $(command -v rwx) ($(rwx --version 2>&1 | head -1 || true))"
    return 0
  fi
  local os arch sha256 binary path
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m | sed s/arm64/aarch64/)"
  case "${os}-${arch}" in
  linux-x86_64) sha256="a62408976abfa709d806cf2a30d73fb995eb1b343664caae6f7cfae260e0751c" ;;
  linux-aarch64) sha256="2e5bcdf810c9dfd719ef4b38cdee665629e9a450e421b1a5cf3becd65f4893d2" ;;
  darwin-x86_64) sha256="3bb95c3519413aaa45c94942bebea3200f722b8891b2c30463aeb2892e9b71ee" ;;
  darwin-aarch64) sha256="c6254fd112a3bc666ca2a57130a7a6b9e293d5952d7014a6893984402360acee" ;;
  *)
    log "error: no pinned rwx asset for ${os}-${arch}"
    return 1
    ;;
  esac
  binary="${WORK}/rwx"
  if ! curl -fsSLo "${binary}" "https://github.com/rwx-cloud/rwx/releases/download/${RWX_PIN}/rwx-${os}-${arch}"; then
    return 1
  fi
  if ! checksum_verify "${sha256}" "${binary}"; then
    return 1
  fi
  chmod 755 "${binary}"
  path="$(install_bin "${binary}" rwx || true)"
  if [[ -z "${path}" ]]; then
    log "error: could not place the rwx binary in a bin directory"
    return 1
  fi
  note_placement "${path}"
  hash -r 2>/dev/null || true
  if ! rwx --version >/dev/null 2>&1; then
    log "error: installed rwx binary failed its version check"
    return 1
  fi
  record PASS rwx "${RWX_PIN} (${path})"
}

# --- python3.11 -------------------------------------------------------------
python311_stage() {
  # Single probe, no version-string parsing: exit status says whether the
  # current `python3` is already >= 3.11 (also covers python3 missing).
  if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    record PASS python3.11 "already $(python3 --version 2>&1 | head -1 || true) ($(command -v python3))"
    return 0
  fi
  if [[ "$(uname -s)" != "Linux" ]] || ! command -v dnf >/dev/null 2>&1; then
    record SKIP python3.11 "not the AL2023 target class (no dnf on $(uname -s)); cannot install here, continuing"
    return 0
  fi
  local can_install=0
  if [[ "$(id -u)" == 0 ]]; then
    can_install=1
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    can_install=1
  fi
  if [[ ${can_install} != 1 ]]; then
    record SKIP python3.11 "no root or passwordless sudo; cannot dnf-install here, continuing"
    return 0
  fi
  # Install 3.11 ALONGSIDE 3.9, never as a replacement: AL2023's
  # /usr/bin/python3 -> python3.9 is load-bearing for absolute-path system
  # callers. /usr/local/bin precedes /usr/bin on PATH in these sandboxes
  # (the same convention every other tool in this repo's setup relies on),
  # so symlinks there shadow PATH lookups only.
  #
  # Shadow blast radius, verified empirically on the stock amazonlinux:2023
  # image (asserted on every run by
  # scripts/conductor-startup-script-cloud-test.sh): dnf's shebang is the
  # absolute `#!/usr/bin/python3` (dnf-3 likewise), so it resolves through
  # /usr/bin and never sees the /usr/local/bin shadow; /usr/bin and
  # /usr/sbin contain zero `#!/usr/bin/env python3` consumers; and a
  # post-shadow `dnf repolist` still succeeds. A future AL2023 update that
  # adds env-shebang system tooling would be caught by that test.
  log "installing python3.11 (AL2023 default python3 is 3.9; pyproject.toml requires >=3.11)"
  if [[ "$(id -u)" == 0 ]]; then
    if ! dnf install -y python3.11; then
      log "error: dnf install python3.11 failed"
      return 1
    fi
  else
    if ! sudo dnf install -y python3.11; then
      log "error: sudo dnf install python3.11 failed"
      return 1
    fi
  fi
  # pip for 3.11 is best-effort: prefer the distro package, fall back to
  # ensurepip, warn (non-fatal) if neither lands — python3.11 itself is the
  # requirement; pip is a convenience for the tools that assume it.
  local pip_ok=0
  if [[ "$(id -u)" == 0 ]]; then
    if dnf install -y python3.11-pip; then
      pip_ok=1
    elif /usr/bin/python3.11 -m ensurepip --upgrade >/dev/null 2>&1; then
      pip_ok=1
    fi
  else
    if sudo dnf install -y python3.11-pip; then
      pip_ok=1
    elif sudo /usr/bin/python3.11 -m ensurepip --upgrade >/dev/null 2>&1; then
      pip_ok=1
    fi
  fi
  if [[ ! -x /usr/bin/python3.11 ]]; then
    log "error: dnf reports success but /usr/bin/python3.11 is missing"
    return 1
  fi
  if [[ "$(id -u)" == 0 || -w "${LOCAL_BIN}" ]]; then
    ln -sfn /usr/bin/python3.11 "${LOCAL_BIN}/python3"
    if [[ ${pip_ok} == 1 && -e /usr/bin/pip3.11 ]]; then
      ln -sfn /usr/bin/pip3.11 "${LOCAL_BIN}/pip3"
    fi
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo ln -sfn /usr/bin/python3.11 "${LOCAL_BIN}/python3"
    if [[ ${pip_ok} == 1 && -e /usr/bin/pip3.11 ]]; then
      sudo ln -sfn /usr/bin/pip3.11 "${LOCAL_BIN}/pip3"
    fi
  fi
  hash -r 2>/dev/null || true
  if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    log "error: python3 still not >=3.11 after install (resolved: $(command -v python3 || true), $(python3 --version 2>&1 | head -1 || true))"
    return 1
  fi
  local detail
  detail="$(python3 --version 2>&1 | head -1 || true) via $(command -v python3)"
  if [[ ${pip_ok} != 1 ]]; then
    detail="${detail} (pip unavailable: no python3.11-pip package and ensurepip failed)"
  fi
  record PASS python3.11 "${detail}"
}

# --- rwx authentication -----------------------------------------------------
# Validate FIRST via the env var (rwx reads RWX_ACCESS_TOKEN on its own),
# persist ONLY on success — a bad token must never overwrite a valid token
# left by a previous `rwx login`. The persisted file is byte-identical to
# what `rwx login` writes, so later shells work without the env var; it is
# created 600 from the start (umask inside a subshell) rather than chmod'd
# after the fact. A pre-existing token file is validated and reported
# instead of ignored; and the stage skips cleanly when rwx failed to
# install, rather than recording a misleading "token rejected" row.
rwx_auth() {
  if ! command -v rwx >/dev/null 2>&1; then
    record SKIP rwx-auth "rwx not installed — skipping auth (see the rwx install row above)"
    return 0
  fi
  if [[ -n "${RWX_ACCESS_TOKEN:-}" ]]; then
    if rwx whoami; then
      mkdir -p "${HOME}/.config/rwx"
      # Atomic persist: write a temp file in the same directory, then mv -f
      # (rename) into place. A truncate-then-write redirect could destroy a
      # previously valid token when the write itself fails mid-way
      # (ENOSPC/EIO); a failed rename leaves the old file intact. The temp
      # file is created 600 via the umask subshell and mv carries those
      # perms to the final name; rm -f on the failure path so a broken
      # persist leaves nothing behind.
      local token_tmp="${HOME}/.config/rwx/accesstoken.tmp"
      if (umask 077; printf '%s' "${RWX_ACCESS_TOKEN}" > "${token_tmp}") &&
        mv -f "${token_tmp}" "${HOME}/.config/rwx/accesstoken"; then
        record PASS rwx-auth "token validated (rwx whoami) and persisted to ~/.config/rwx/accesstoken"
      else
        rm -f "${token_tmp}"
        record FAIL rwx-auth "token validated but persisting to ~/.config/rwx/accesstoken failed; any previously persisted token was left untouched"
        return 1
      fi
    else
      record FAIL rwx-auth "RWX_ACCESS_TOKEN rejected — rwx whoami failed (expired or wrong token?); any previously persisted token was left untouched"
      return 1
    fi
  elif [[ -s "${HOME}/.config/rwx/accesstoken" ]]; then
    if rwx whoami; then
      record PASS rwx-auth "no RWX_ACCESS_TOKEN, but the existing ~/.config/rwx/accesstoken validated (rwx whoami)"
    else
      record WARN rwx-auth "existing ~/.config/rwx/accesstoken rejected — run rwx login, or set RWX_ACCESS_TOKEN in Conductor environment variables"
    fi
  else
    record WARN rwx-auth "RWX_ACCESS_TOKEN not set — rwx installed but unauthenticated; set it in Conductor environment variables and re-run setup, or run rwx login in a workspace terminal"
  fi
  return 0
}

# --- roborev initialization -------------------------------------------------
# `roborev init` creates ~/.roborev, .roborev.toml in the repo, installs the
# post-commit hook, and starts the daemon. Init only when the repo has no
# .roborev.toml — a committed one is the repo's own configuration and is
# never clobbered. The hook is ensured INDEPENDENTLY of init (a committed
# .roborev.toml in a fresh checkout must not leave the hook missing:
# .git/hooks is never cloned), never over an existing non-roborev hook, and
# never — including via init itself, which installs the hook and has no
# flag to suppress it — when core.hooksPath points at a machine-global
# hooks dir (often another tool's, e.g. git-lfs's). Everything is anchored
# to `git rev-parse --show-toplevel` so running setup from a subdirectory
# cannot misfire.
ROBOREV_AGENT_DEFAULT="claude-code"

# ensure_daemon <stage>: status → PASS "daemon running"; start → PASS
# "daemon revived"; neither → FAIL under <stage> (deferred setup failure).
# Shared by the hooks_external and normal paths so a future daemon-handling
# fix lands in one place, not in two copy-pasted blocks that already report
# the same failure under different stage names (roborev review finding).
ensure_daemon() {
  local stage="$1"
  if roborev status >/dev/null 2>&1; then
    record PASS "${stage}" "daemon running"
  elif roborev daemon start; then
    record PASS "${stage}" "daemon revived"
  else
    record FAIL "${stage}" "daemon not running and 'roborev daemon start' failed"
    return 1
  fi
}

roborev_setup() {
  local agent="${ROBOREV_AGENT:-${ROBOREV_AGENT_DEFAULT}}"
  # `git roborev ...` (the push-gate spelling): native git-subcommand
  # resolution via the git-roborev symlink, plus a global alias as backup.
  git config --global alias.roborev '!roborev' || true
  if ! command -v roborev >/dev/null 2>&1; then
    record SKIP roborev-init "roborev not installed — skipping init (see the roborev install row above)"
    return 0
  fi
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    record WARN roborev-init "cwd is not a git worktree — skipping roborev init; run it manually in the repo"
    return 0
  fi
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  cd "${repo_root}"
  # Hoisted ABOVE init: roborev init installs the post-commit hook itself
  # and has no flag to suppress that (only --agent/--no-daemon), so when
  # core.hooksPath points at a machine-global dir, init must not run either
  # — the guard has to cover every code path that can install a hook, not
  # just the explicit install-hook step (roborev review finding).
  local hook hooks_external=0
  hook="$(git rev-parse --git-path hooks/post-commit)"
  if [[ -n "$(git config core.hooksPath)" ]]; then
    hooks_external=1
  fi
  if [[ ${hooks_external} == 1 ]]; then
    if [[ ! -f "${repo_root}/.roborev.toml" ]]; then
      record WARN roborev-init "core.hooksPath is set — skipping roborev init, which would install a post-commit hook into the machine-global hooks dir; run 'roborev init --agent ${agent}' manually if wanted"
    else
      record PASS roborev-init ".roborev.toml already present; init not needed (core.hooksPath set)"
    fi
    ensure_daemon roborev-daemon || return 1
    record WARN roborev-hook "core.hooksPath is set — hooks resolve to a machine-global dir this script will not touch; run 'roborev install-hook' manually if auto-review on commit is wanted"
  else
    if [[ ! -f "${repo_root}/.roborev.toml" ]]; then
      if roborev init --agent "${agent}"; then
        record PASS roborev-init "initialized (agent: ${agent}); daemon started"
      else
        record FAIL roborev-init "roborev init failed (see output above)"
        return 1
      fi
    else
      record PASS roborev-init ".roborev.toml already present"
      ensure_daemon roborev-init || return 1
    fi
    # Hook ensure, independent of init: a committed .roborev.toml in a fresh
    # checkout must not leave the hook missing (.git/hooks is never cloned).
    # `git rev-parse --git-path` resolves worktrees correctly.
    if [[ -f "${hook}" ]] && grep -q roborev "${hook}"; then
      record PASS roborev-hook "post-commit hook present (${hook})"
    elif [[ -f "${hook}" ]]; then
      record WARN roborev-hook "a non-roborev post-commit hook exists at ${hook} — left untouched; run 'roborev install-hook --force' manually to replace it"
    elif roborev install-hook; then
      record PASS roborev-hook "post-commit hook installed (${hook})"
    else
      record WARN roborev-hook "roborev install-hook failed — auto-review on commit is off; manual 'git roborev review' still works"
    fi
  fi
  # Smoke-check that the review agent actually responds — this is what makes
  # reviews work end to end. Non-fatal: a wrong agent choice or a transient
  # failure shouldn't fail setup when roborev itself installed and initialized.
  if roborev check-agents --agent "${agent}" --timeout 30 >/dev/null 2>&1; then
    record PASS roborev-agent "${agent} answered a smoke prompt — reviews are live"
  else
    record WARN roborev-agent "${agent} failed its smoke check — reviews may not run; inspect with roborev check-agents, or set ROBOREV_AGENT and re-run setup"
  fi
}

# --- run -------------------------------------------------------------------
# STARTUP_BEST_EFFORT=1 (exported by this repo's settings.toml) keeps the
# former cloud-install contract: tool-stage failures are recorded but do
# not fail the run (gtm-sdk#702's fallback-installer idiom). Default
# (pasted standalone): any FAIL row fails the run. Python 3.11 on the
# target class is a hard requirement either way; its SKIP paths return 0
# and never reach the FAILED assignment.
BEST_EFFORT="${STARTUP_BEST_EFFORT:-0}"

maybe_fail() { # tool-stage failure: fatal unless best-effort mode is on
  if [[ "${BEST_EFFORT}" != "1" ]]; then
    FAILED=1
  fi
}

log "host: $(uname -srm), user: $(id -un), pwd: $(pwd)"

if roborev_install; then :; else record FAIL roborev "provisioning failed — see messages above"; maybe_fail; fi
if trunk_stage; then :; else record FAIL trunk "provisioning failed — see messages above"; maybe_fail; fi
if rwx_install; then :; else record FAIL rwx "provisioning failed — see messages above"; maybe_fail; fi
if python311_stage; then :; else FAILED=1; record FAIL python3.11 "provisioning failed — see messages above"; fi
if rwx_auth; then :; else maybe_fail; fi
if roborev_setup; then :; else maybe_fail; fi

log ""
log "---- workspace startup summary ----"
printf '%s' "${RESULTS}"
echo
if [[ -n "${LOCAL_FALLBACK_TOOLS}" ]]; then
  log ""
  log "warning: tools landed in ~/.local/bin (no writable /usr/local/bin, no passwordless sudo):${LOCAL_FALLBACK_TOOLS}"
  log "warning: that directory is not on the default PATH of later setup steps — this repo's .conductor/settings.toml exports it for the rest of setup; other callers must add it themselves"
fi
log "-------------------------------------"
log "full log: $SETUP_LOG"
# Surface the summary + log path on the original stdout too (fd 3, saved
# before the redirect): it is the one block a human must see even when the
# log file is not open (roborev review finding). The bare echo terminates
# the summary's last row — printf format strings stay backslash-free
# because a literal backslash sequence in this file is itself a
# paste-safety hazard (see the header).
printf '%s' "${RESULTS}" >&3 || true
echo >&3 || true
if [[ -n "${LOCAL_FALLBACK_TOOLS}" ]]; then
  echo "warning: tools landed in ~/.local/bin (not on later steps' default PATH):${LOCAL_FALLBACK_TOOLS}" >&3 || true
fi
echo "full log: $SETUP_LOG" >&3 || true
echo "=== setup finished $(date -u +%FT%TZ) ==="

# Deferred failure (so the summary above always completes): by default a
# provisioning or auth failure in the tools this workspace exists for must
# fail setup loudly, not pass silently — every stage still ran and reported
# above, so this is loud-and-late, never an early abort. Under
# STARTUP_BEST_EFFORT=1 only a target-class Python 3.11 failure reaches
# this exit; tool FAIL rows were recorded and the run exits 0 (the
# gtm-sdk#702 idiom this repo's settings.toml contracts for). The error
# goes to the original stderr (fd 4) as well as the log.
if [[ "${FAILED}" != 0 ]]; then
  log "error: setup finished with FAIL rows — see the summary and $SETUP_LOG"
  echo "error: setup finished with FAIL rows — see the summary and $SETUP_LOG" >&4 || true
  exit 1
fi
