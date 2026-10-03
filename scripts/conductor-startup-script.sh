#!/usr/bin/env bash
# shellcheck disable=SC2312  # $(...) in assignments and rows: stage failures surface through the stages' own || returns and the summary, not by killing the script mid-row
# Generic, repo-agnostic Conductor workspace setup: roborev + rwx.
#
# This is the canonical, version-controlled copy of the paste-ready setup
# script for Conductor workspaces in repos that have no committed
# .conductor/settings.toml setup of their own: open the workspace/repo
# settings in the Conductor GUI and paste this file's contents into the
# setup-script field (stored there as scripts.setup — "Shell script run when
# a workspace is created"). Conductor exposes no API for setting that field,
# so the GUI paste is the only mechanism; this file exists so the pasted
# text is reviewable and pin-checked instead of hand-carried. It also runs
# standalone, unchanged:
#
#   bash scripts/conductor-startup-script.sh
#
# Repo-agnostic by design: no repo paths, no repo scripts, nothing that
# assumes a particular project — safe in any workspace, local or cloud.
# (This repo's own .conductor/settings.toml deliberately does NOT call it:
# its setup is repo-specific — the flox harness, infisical, FloxHub.)
#
# What "work" means here, beyond the binaries landing on PATH:
#   roborev  installed (pinned, checksum-verified) + `git roborev` alias +
#            repo init when unconfigured (daemon started) + post-commit hook
#            ensured independently of init + agent smoke check. When
#            core.hooksPath points at a machine-global hooks dir (often
#            another tool's, e.g. git-lfs's), init is skipped too — roborev
#            init installs the hook itself — and no hook is ever written.
#   rwx      installed (pinned, checksum-verified) + token validated BEFORE
#            it is persisted (a bad token never overwrites a good one), so
#            every later shell is authenticated, not just setup
#
# Pins: ROBOREV_PIN/RWX_PIN and every sha256 below are deliberately
# duplicated from scripts/conductor-cloud-install.sh (the repo-specific
# provisioner of the same binaries) — scripts/validate-pins.sh cross-checks
# them in CI; bump both files together, per its bump runbook.
#
# Paste-safety constraints (load-bearing for the GUI field, which Conductor
# serializes into a TOML multiline string): NO triple-double-quote sequences
# and NO backslash line-continuations anywhere in this file — a future editor
# must keep long commands on one line. Same sandbox rules as every
# provisioning
# script here: no process substitution (sandboxes can lack /dev/fd and
# `set -e` then kills the script silently); log to ~/.conductor-setup.log via
# a plain append redirect, not tee; idempotent (reuse-if-present, safe to
# re-run); one WORK dir cleaned by a single EXIT trap; per-CLI failures
# recorded and summarized, with the hard failure deferred to the very end so
# every step still gets a chance to run and report.
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
set -euo pipefail

# Save the original stdout/stderr as fd 3/4 BEFORE the log redirect: the
# summary and any final error are surfaced there as well, so a failing
# setup is visible wherever its output is presented, not only in the log
# file. Pure fd duplication — no process substitution (the /dev/fd rule).
exec 3>&1 4>&2
SETUP_LOG="$HOME/.conductor-setup.log"
: > "$SETUP_LOG"
exec >> "$SETUP_LOG" 2>&1
echo "=== setup started $(date -u +%FT%TZ) ==="

# ~/.local/bin is the no-sudo fallback install location; keep it on PATH for
# the rest of setup (later shells normally have it via the profile).
export PATH="${HOME}/.local/bin:${PATH}"

LOCAL_BIN="/usr/local/bin"
RESULTS=""
FAILED=0

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

log() { echo "[workspace-setup] $*"; }

record() { # <status> <name> <detail> — one summary row + one log line
  RESULTS="${RESULTS}
 ${2} | ${1} | ${3}"
  log "[${1}] ${2} — ${3}"
}

# install_bin <src> <name>: place a file as an executable under
# /usr/local/bin when root or passwordless sudo allows it, else under
# ~/.local/bin. Echoes the installed path on success (nothing on failure).
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
# git subcommand).
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

# --- roborev --------------------------------------------------------------
# Pinned release binary, fail-closed sha256 (same pins the sandbox repos
# cross-check in CI). Reuse-if-present keeps re-runs cheap.
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
  link_bin "${path}" git-roborev || true
  hash -r 2>/dev/null || true
  if ! command -v roborev >/dev/null 2>&1; then
    log "error: roborev installed at ${path} but not on PATH"
    return 1
  fi
  record PASS roborev "v${ROBOREV_PIN} (${path})"
}

# --- rwx ------------------------------------------------------------------
# Pinned static release binary (RWX is not in nixpkgs/Flox; their docs
# recommend pinning for scripted use). Reuse-if-present.
RWX_PIN="v3.25.0"

rwx_install() {
  if command -v rwx >/dev/null 2>&1; then
    record PASS rwx "reused $(command -v rwx) ($(rwx --version 2>&1 | head -1 || true))"
    return 0
  fi
  local os arch sha256 binary path
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m | sed s/arm64/aarch64/)"
  case "${os}-${arch}" in
  linux-x86_64) sha256="eb6b4488914e7751a94e194fc5f73efd74a2b4dc4acee4970993b986c697e291" ;;
  linux-aarch64) sha256="f7945f82a1be281a6350948895ac15f0ac1c5ef890fb3c7d0eaabe169d05883f" ;;
  darwin-x86_64) sha256="d46eac9b52e250122d79a76e17a360875d0b0a848120f828eb9a008d45f12539" ;;
  darwin-aarch64) sha256="3da82699e2b779fadb3d0574740ddc8812606618030e5e52b6415a7b2c7abb36" ;;
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
  hash -r 2>/dev/null || true
  if ! rwx --version >/dev/null 2>&1; then
    log "error: installed rwx binary failed its version check"
    return 1
  fi
  record PASS rwx "${RWX_PIN} (${path})"
}

# --- rwx authentication ----------------------------------------------------
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
log "host: $(uname -srm), user: $(id -un), pwd: $(pwd)"

if roborev_install; then :; else FAILED=1; record FAIL roborev "provisioning failed — see messages above"; fi
if rwx_install; then :; else FAILED=1; record FAIL rwx "provisioning failed — see messages above"; fi
if rwx_auth; then :; else FAILED=1; fi
if roborev_setup; then :; else FAILED=1; fi

log ""
log "---- roborev + rwx setup summary ----"
printf '%s' "${RESULTS}"
echo
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
echo "full log: $SETUP_LOG" >&3 || true
echo "=== setup finished $(date -u +%FT%TZ) ==="

# Deferred failure (so the summary above always completes): a provisioning
# or auth failure in the two CLIs this workspace exists for must fail setup
# loudly, not pass silently. The error goes to the original stderr (fd 4)
# as well as the log.
if [[ "${FAILED}" != 0 ]]; then
  log "error: setup finished with FAIL rows — see the summary and $SETUP_LOG"
  echo "error: setup finished with FAIL rows — see the summary and $SETUP_LOG" >&4 || true
  exit 1
fi
