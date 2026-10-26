#!/usr/bin/env bash
# shellcheck disable=SC2312  # $(...) in assignments and rows: stage failures surface through the stages' own || returns and the summary, not by killing the script mid-row
# The single Conductor workspace startup script: roborev + trunk + rwx +
# Python 3.11 + the opt-in Python dev tools (uv/pytest/reflex), then the
# auth/init that makes them work rather than merely exist.
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
#      hand-carried. Where provisioning fixes land: in THIS file only. The
#      paste is a hand-refreshed snapshot that does not track this repo,
#      and a consuming repo never gains setup logic of its own (gtm-sdk
#      has carried none since gtm-sdk#944 and must never regain it), so a
#      fresh workspace missing tools means a stale or missing paste, or an
#      env var a stage needs left unset in the consuming repo's Conductor
#      settings — fixed by changing this file and re-pasting, never by
#      editing the consuming repo (issue #50 is the cautionary tale). It
#      also runs standalone, unchanged:
#
#        bash scripts/conductor-startup-script-cloud.sh
#
#      Repo-agnostic by design: no repo paths, no repo scripts, nothing that
#      assumes a particular project — safe in any workspace, local or cloud.
#      The trunk and python stages are reuse-if-present and SKIP cleanly off
#      the target class, so pasting this into a repo that needs neither
#      costs nothing. The uv/pytest/reflex stage (issue #44) is opt-in via
#      STARTUP_PY_DEV_TOOLS=1 and SKIPs when unset, so the paste surface is
#      exactly what it was before that stage existed — only this repo's
#      own settings.toml turns it on.
#
# What "work" means here, beyond the binaries landing on PATH:
#   roborev  installed (pinned, checksum-verified) + `git roborev` alias +
#            repo config (.roborev.toml written directly) + daemon ensured +
#            agent smoke check. Reviews are ON DEMAND and BLOCKING — the
#            push gate the repo's agent instructions and create-pr prompt
#            define is `roborev review --wait` — so NO post-commit
#            auto-review hook is ever installed: `roborev init` is never run
#            (it installs the post-commit/post-rewrite hooks and has no flag
#            to suppress that), and a leftover roborev hook from an older
#            setup is actively removed — `roborev post-commit`, the hook
#            entry point, can only enqueue a background daemon job (no
#            --wait), which is exactly the posture this script must not
#            leave behind. When core.hooksPath points at a machine-global
#            hooks dir (often another tool's, e.g. git-lfs's), nothing is
#            ever written there — a WARN tells the user to remove any
#            roborev hook found in it by hand.
#   trunk    the official launcher, content-pinned by sha256: trunk
#            publishes no versioned launcher URL (trunk.io/releases/trunk
#            is latest-only), but the artifact is a portable bash script
#            that stayed byte-stable from 2024-11-06 until its 2026-10-06
#            update to launcher 1.3.5 (S3 last-modified) — fail closed on
#            any upstream change, bump deliberately. What the
#            launcher then fetches is trunk's own managed update channel,
#            out of this script's control. Same download as
#            scripts/conductor-trunk-preflight.sh, which this repo's setup
#            runs first, so this stage is normally verify-only reuse there.
#   rwx      installed (pinned, checksum-verified) + token validated BEFORE
#            it is persisted (a bad token never overwrites a good one), so
#            every later shell is authenticated, not just setup.
#   python3.11  installed ALONGSIDE 3.9, never as a replacement, on the
#            AL2023 class only (see the stage body for the shadow-safety
#            facts); SKIP elsewhere. The only always-on stage whose failure
#            is a stated requirement rather than a nice-to-have.
#   uv/pytest/reflex  opt-in (STARTUP_PY_DEV_TOOLS=1, this repo's
#            settings.toml): uv as a pinned, checksum-verified release
#            binary placed like every other tool; pytest and reflex as
#            pinned packages in one uv-managed venv, ~/.conductor-pytools
#            (Python 3.11), with their console scripts symlinked into the
#            same bin dirs so later agent shells get `uv`, `pytest`, and
#            `reflex` as commands. The venv is the intended Python
#            environment for the two packages — the documented module
#            invocations are ~/.conductor-pytools/bin/python -m pytest and
#            ... -c 'import reflex' (issue #44's managed-environment
#            allowance). A failure in this stage is fatal under BOTH
#            postures: it only runs when the workspace explicitly asked
#            for these tools, and a requested tool that failed to
#            provision must fail setup loudly, never leave a workspace
#            that appears ready but lacks them.
#
# Pins: ROBOREV_PIN/RWX_PIN/UV_PIN/PYTEST_PIN/REFLEX_PIN/ENTIRE_PIN and every sha256
# below are the single in-repo home of those constants. The roborev pin is
# kept in sync with envs/repackage/.flox/env/manifest.toml's [build.roborev]
# and envs/floxhub-provision's roborev.version; the uv pin is kept in sync
# with envs/prebuilt and envs/floxhub-provision's uv.version —
# scripts/validate-pins.sh cross-checks both families in CI. Bump runbooks:
# roborev: new pin + sha256s from the release's checksums file, then
# republish the FloxHub package — don't hand-edit any lock. uv: new pin +
# sha256s (hand-hash the release tarballs), then bump both Flox manifests
# and re-lock their envs together. pytest/reflex: no Flox counterpart —
# the pins live only here, and validate-pins.sh asserts they stay exact
# x.y.z pins. (The rwx block's former sibling copy in gtm-sdk's
# conductor-workspace-setup.sh went away when that repo retired the script,
# gtm-sdk#944 — this file is now the pin's only executable home.) ENTIRE_PIN
# + the four ENTIRE_SHA256_* constants are single-home pins with no Flox
# counterpart (issue #91): the entire CLI is a binary release with no
# manifest build, so the only sync surface is here — validate-pins.sh
# asserts the pin stays an exact x.y.z AND that every supported platform
# has a sha256 constant set. Re-pin runbook: bump ENTIRE_PIN, then re-hash
# the four release tarballs from
# https://install.entire.com/v${ENTIRE_PIN}/entire_<platform>.tar.gz (which
# mirrors what GitHub releases also publish; both URLs produce byte-identical
# content, hand-checked at the original pin) and update the four
# ENTIRE_SHA256_* constants in the same commit.
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
# tool stages (roborev/trunk/rwx install, rwx auth, roborev
# config/daemon) record
# their FAIL rows but do not fail the run (the pi stage never fails it under
# either posture: a failed install is a WARN row and pi stays uninstalled), and only a Python 3.11 failure
# on the AL2023 target class (the stated >=3.11 requirement) or a
# pytools-stage failure when STARTUP_PY_DEV_TOOLS=1 requested them
# (issue #44: a requested tool that cannot be provisioned must never
# leave a workspace that appears ready but lacks it) exits non-zero.
#
# Environment variables (set them in Conductor's environment variables
# settings — never inline them in this script: settings values are plain
# strings with no masking):
#   RWX_ACCESS_TOKEN  RWX personal access token (cloud.rwx.com -> Settings ->
#                     Personal access tokens). Without it, rwx installs but
#                     stays unauthenticated (warning, not failure).
#   ROBOREV_AGENT     optional review-agent override; any lowercase agent
#                     slug (codex, claude-code, gemini, copilot, opencode,
#                     cursor, kiro, kilo, pi, ...) — deliberately not a
#                     hard allowlist: the accepted set differs across
#                     roborev versions, and the check-agents smoke step
#                     is the semantic check. Defaults to pi — issue #85's
#                     rollover from claude-code, because the sandbox's
#                     pre-authenticated claude-code never reaches a sandbox
#                     in practice and codex returns 401. Issue #101's
#                     override guard: a claude-code or codex value is
#                     recorded as a louder WARN that names the override and
#                     points at the script's pi default — pi stays
#                     uninstalled in that case, so reviews cannot run. Do
#                     not set ROBOREV_AGENT=claude-code/codex without also
#                     installing/authenticating the agent on the sandbox; a
#                     workspace that needs to review must use pi (or an
#                     agent that actually authenticates here).
#   ROBOREV_MODEL     optional model override written into .roborev.toml
#                     alongside `agent`. Defaults to
#                     `fireworks/accounts/fireworks/models/glm-5p3` —
#                     issue #85's verified-working pair with Pi + Fireworks.
#                     The default applies only when the agent is pi; other
#                     agents get no model line unless this is set.
#                     Empty disables the line so no model is written.
#                     The `fireworks/` provider prefix is required; a bare
#                     `accounts/fireworks/models/...` is rejected by
#                     roborev's call as `Model ... not found`, and
#                     `~/.pi/agent/settings.json`'s `defaultProvider`
#                     does NOT fix it (issue #85's gotcha).
#   FIREWORKS_API_KEY required when ROBOREV_AGENT=pi (the default) and the
#                     model resolves through Fireworks. Pi calls Fireworks
#                     directly under the configured `model`; without the
#                     key, the smoke check WARNs and reviews cannot run.
#                     Truncate to a stub for local development — but a
#                     sandbox that ships an unset FIREWORKS_API_KEY is
#                     configured-but-broken until the key is set.
#   STARTUP_BEST_EFFORT  set to 1 (this repo's settings.toml does) to make
#                     the tool stages recorded-but-non-fatal; see the
#                     failure-semantics section above.
#   STARTUP_PY_DEV_TOOLS  set to 1 (this repo's settings.toml does) to
#                     provision uv/pytest/reflex; see the tool list and
#                     the pytools stage body. Unset or any other value
#                     records a SKIP row and changes nothing else — the
#                     paste-ready consumer's surface stays as it was. A
#                     consuming repo that wants these tools must set this
#                     env var in ITS OWN Conductor env-var settings; a
#                     pasted script alone never turns the stage on.
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

# expose_link <target> <name>: symlink <name> -> <target> as a command in
# /usr/local/bin (the repo's persistent-tool convention) when root or
# passwordless sudo allows it, else under ~/.local/bin — the same
# placement rules as install_bin, but a symlink instead of a copy, so the
# source (the pytools venv) stays the single source of truth: re-running
# setup or upgrading a package updates the command too. ln -sfn makes it
# naturally idempotent. Echoes the link path on success (nothing on
# failure). Like install_bin, it does NOT call note_placement itself:
# callers run it inside command substitution, where the variable update
# would be lost with the subshell (the trap link_bin's comment warns
# about) — callers note the returned path instead.
expose_link() {
  local target="$1" name="$2" dir
  if [[ "$(id -u)" == 0 || -w "${LOCAL_BIN}" ]]; then
    ln -sfn "${target}" "${LOCAL_BIN}/${name}" || return 1
    dir="${LOCAL_BIN}"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo ln -sfn "${target}" "${LOCAL_BIN}/${name}" || return 1
    dir="${LOCAL_BIN}"
  else
    mkdir -p "${HOME}/.local/bin" || return 1
    ln -sfn "${target}" "${HOME}/.local/bin/${name}" || return 1
    dir="${HOME}/.local/bin"
  fi
  printf '%s' "${dir}/${name}"
  echo
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

# sha512_verify <sha512-hex> <file>: the SRI form npm's `dist.integrity`
# gives (`sha512-<base64>`) decodes to the file's full 128-char hex sha512.
# sha256sum cannot verify it, so a separate helper calls sha512sum /
# `shasum -a 512` with the same stdin shape as checksum_verify.
sha512_verify() {
  local expected="$1" file="$2"
  local tool="sha512sum"
  if ! command -v sha512sum >/dev/null 2>&1; then
    if ! command -v shasum >/dev/null 2>&1; then
      log "error: no sha512 tool (sha512sum or shasum) to verify ${file}"
      return 1
    fi
    tool="shasum -a 512"
  fi
  # shellcheck disable=SC2086  # intentional two-word command (shasum -a 512), not a path to quote
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

# --- pi ----------------------------------------------------------------------
# Pinned tarball + SRI sha512 (the same npm registry `dist.integrity` field).
# Pi 0.73.1 lived under `@mariozechner/pi-coding-agent`; the package was
# renamed to `@earendil-works/pi-coding-agent` after that release (the Earendil
# Works handoff, see pi.dev changelog 2026-05). The pinned v1.3.0 is the
# continuation of that same line, not a fork. ROBOREV_AGENT=pi is the new
# default review agent (issue #85's rollover from claude-code): claude-code
# never reaches a Conductor cloud sandbox in practice and codex returns 401,
# so roborev's `agent = ...` had no working default for cloud workspaces.
# Issue #101 sharpens this: a claude-code or codex ROBOREV_AGENT override
# is now recorded as WARN (not SKIP) so the operator sees it — those two
# slugs are known-cloudsandbox-broken (issue #85's verified facts) and pi
# stays uninstalled under the override. Other agent slugs keep the quiet
# SKIP row because some future version may actually work. Cloud workspaces
# that need to review must use pi (or an agent that actually authenticates
# on the sandbox).
#
# Pi's engines field requires Node >=22.19.0. AL2023's stock nodejs is 18 and
# amazon-linux-2023 extras do not carry a 22 — installing Node 22 from
# Nodesource or a third-party repo would significantly expand the script's
# surface (out of scope: the script's design floor is reuse-what's-there plus
# minimal installs), so this stage SKIPs when npm is missing instead of
# bringing in a Node toolchain. Consumers that want a different agent
# (opencode — issue #85's stated fallback when Pi proves unworkable) can
# override ROBOREV_AGENT for their own workspaces.
PI_PIN="1.3.0"
# SRI base64 SHA512 of the registry tarball. The pair PI_PIN + PI_INTEGRITY
# is the in-repo pin surface validate-pins.sh cross-checks against itself
# (single-home, no Flox counterpart). Re-pin by running
# `npm view @earendil-works/pi-coding-agent@<NEW_PIN> dist` and capturing
# `integrity` verbatim — don't compute it locally.
PI_INTEGRITY="sha512-V/WoCjA2hQSe3QLWIUB24cTRdtEdeLiIzkDqU5RMXV6VWuD+KGZnzVBMhglwdnQTySkehZsjt8a3g6Jd2g4nnw=="
PI_TARBALL_URL="https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${PI_PIN}.tgz"
# Node floor from the pinned package's `engines` field (major.minor). A
# re-pin must re-check it with `npm view
# @earendil-works/pi-coding-agent@<NEW_PIN> engines`: a stale floor lets an
# older Node past the SKIP and fail setup at npm install instead.
PI_NODE_MIN="22.19"
# The PI_PIN the floor above was read from; validate-pins.sh fails CI until
# it matches PI_PIN, so a re-pin cannot leave the floor unchecked.
# shellcheck disable=SC2034  # read by validate-pins.sh, not at runtime
PI_NODE_MIN_PIN="1.3.0"
PI_NODE_MIN_MAJOR="${PI_NODE_MIN%%.*}"
PI_NODE_MIN_MINOR="${PI_NODE_MIN#*.}"

# sri_to_hex <sri-sha512>: decode the base64 portion of an SRI string into a
# lowercase hex digest that sha512sum can verify. Strip the "sha512-" prefix
# from $1, base64-decode, hex-print, strip spaces+newlines. The result is the
# 128-char hex that pairs with the tarball content sha512sum sees. Uses
# `od -An -v -tx1` for the hex (alphabetically portable: xxd is missing on
# stock amazonlinux:2023, but `od` ships in coreutils).
sri_to_hex() {
  local b64="${1#sha512-}" hex
  # macOS 12 and older spell the decode flag -D.
  hex="$({ printf '%s' "${b64}" | base64 -d 2>/dev/null || printf '%s' "${b64}" | base64 -D; } |
    od -An -v -tx1 | tr -d ' \n')"
  # tr ends the pipeline, so its status hides a failed decode; a sha512 is
  # exactly 64 bytes, so anything but 128 hex chars means the pin is bad.
  [[ ${#hex} -eq 128 ]] || return 1
  printf '%s' "${hex}"
}

pi_install() {
  # An explicit, well-formed non-pi ROBOREV_AGENT opts out of the default,
  # so don't download or globally install an agent nobody will use. (A
  # malformed value falls back to pi in roborev_setup, so it still installs.)
  if [[ "${ROBOREV_AGENT:-}" =~ ^[a-z0-9][a-z0-9-]*$ && "${ROBOREV_AGENT}" != "pi" ]]; then
    # Issue #101: claude-code never reaches a Conductor cloud sandbox in
    # practice and codex returns 401 (issue #85's verified facts). A SKIP
    # row is easy to lose in a long summary when the override is the
    # specific cause of an apparent hold-up — promote this case to a
    # higher-severity WARN that names the override, points at issue #101,
    # and tells the operator how to get reviews working (unset the override
    # to let pi install). Other agent slugs keep the quiet SKIP because
    # some future version may actually work.
    if [[ "${ROBOREV_AGENT}" == "claude-code" || "${ROBOREV_AGENT}" == "codex" ]]; then
      if command -v pi >/dev/null 2>&1; then
        # pi is already installed from a prior run, but the override was
        # since set (the operator's likely intent here: evaluate how the
        # override behaves without disturbing a working config). The
        # override changes only what gets written to NEW .roborev.toml
        # files — a committed `.roborev.toml` whose agent line was set
        # under the pi default keeps winning (per roborev_setup's
        # file-agent recalibration), so reviews in THIS workspace are
        # still live. The WARN still fires so an empty-repo re-clone
        # under the same override doesn't silently land a broken agent.
        record WARN pi "ROBOREV_AGENT=${ROBOREV_AGENT} is a known-cloudsandbox-broken review agent (issue #101): pi is already installed and a committed agent = \"pi\" .roborev.toml keeps reviews live in this workspace, but a future fresh repo under the same override would land a broken agent — unset the override (or set ROBOREV_AGENT=pi) to make pi the workspace-wide default"
      else
        record WARN pi "ROBOREV_AGENT=${ROBOREV_AGENT} points at a known-cloudsandbox-broken review agent (issue #101) — pi is not installed, reviews will not run; unset the override (or set ROBOREV_AGENT=pi) so the script's pi default installs"
      fi
    else
      record SKIP pi "ROBOREV_AGENT=${ROBOREV_AGENT} selects another review agent — pi not installed"
    fi
    return 0
  fi
  if command -v pi >/dev/null 2>&1; then
    record PASS pi "reused $(command -v pi) ($(pi --version 2>&1 | head -1 || true))"
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    record SKIP pi "npm not installed — install Node ${PI_NODE_MIN}+ separately (Pi's engines field requires >=${PI_NODE_MIN}) and re-run setup, or set ROBOREV_AGENT=opencode / an already-installed agent. Conductor cloud sandboxes without npm come up reviews-only-via-roborev (no agent installed)."
    return 0
  fi
  # pi is only the default agent, so a Node below its engines floor (e.g. a
  # dnf nodejs18 pulled in for other tooling) SKIPs like a missing npm
  # instead of failing setup for a user who never asked for pi.
  local node_ver node_major node_minor
  node_ver="$(node --version 2>/dev/null || true)"
  node_ver="${node_ver#v}"
  node_major="${node_ver%%.*}"
  node_minor="${node_ver#*.}"
  node_minor="${node_minor%%.*}"
  # A version without a minor ("22") would leave node_minor == node_major;
  # treat it as unparseable so it SKIPs rather than passing the floor.
  [[ "${node_ver}" == *.* ]] || node_minor=""
  if ! [[ "${node_major}" =~ ^[0-9]+$ && "${node_minor}" =~ ^[0-9]+$ ]] ||
    ((node_major < PI_NODE_MIN_MAJOR || (node_major == PI_NODE_MIN_MAJOR && node_minor < PI_NODE_MIN_MINOR))); then
    record SKIP pi "Node ${node_ver:-<none>} is below Pi's engines requirement (>=${PI_NODE_MIN}) — install Node ${PI_NODE_MIN}+ and re-run setup, or set ROBOREV_AGENT=opencode / an already-installed agent."
    return 0
  fi
  local tarball_pi="${WORK}/pi-coding-agent-${PI_PIN}.tgz"
  if ! curl -fsSLo "${tarball_pi}" "${PI_TARBALL_URL}"; then
    log "error: failed to download ${PI_TARBALL_URL}"
    return 1
  fi
  local expected_hex
  if ! expected_hex="$(sri_to_hex "${PI_INTEGRITY}")"; then
    log "error: could not decode Pi integrity pin"
    return 1
  fi
  if ! sha512_verify "${expected_hex}" "${tarball_pi}"; then
    log "error: pi tarball integrity mismatch (expected ${PI_INTEGRITY})"
    return 1
  fi
  # Match the install_bin convention: /usr/local when writable (root or
  # passwordless sudo), ~/.local otherwise. `--prefix` forces a known install
  # location independent of npm's user rc; it is the same mechanism pi's
  # `env NPM_CONFIG_PREFIX=...` runner use to keep install reproducible.
  local prefix npm_cmd=()
  if [[ "$(id -u)" == 0 || -w "${LOCAL_BIN}" ]]; then
    prefix="/usr/local"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    prefix="/usr/local"
    # secure_path would drop a user-local npm (nvm, ~/.local); carry PATH over.
    npm_cmd=(sudo -n env "PATH=${PATH}" npm)
  else
    prefix="${HOME}/.local"
  fi
  if [[ ${#npm_cmd[@]} -eq 0 ]]; then
    npm_cmd=(npm)
  fi
  # Pi's engines field rejects Node below PI_NODE_MIN in npm install; surface the most common
  # cause explicitly instead of letting a generic ENOENT/EBADENGINE error
  # hide behind a generic message. npm's output stays in the setup log
  # (stdout is redirected there) rather than under WORK, which the EXIT
  # trap deletes, so the exact rule that fired is still greppable.
  if ! "${npm_cmd[@]}" install -g --prefix "${prefix}" "${tarball_pi}"; then
    log "error: npm install -g --prefix ${prefix} ${tarball_pi} failed (npm output above in ${SETUP_LOG}); the most common cause on a fresh sandbox is Node below Pi's engines requirement (>=${PI_NODE_MIN}) — install Node ${PI_NODE_MIN}+ and re-run setup"
    return 1
  fi
  hash -r 2>/dev/null || true
  if ! command -v pi >/dev/null 2>&1; then
    log "error: pi installed under --prefix ${prefix} but its bin/ is not on PATH (expected ${prefix}/bin/pi) — add ${prefix}/bin to PATH or symlink pi into ${LOCAL_BIN} by hand"
    return 1
  fi
  if [[ "${prefix}/bin" != "${LOCAL_BIN}" ]]; then
    note_placement "${prefix}/bin/pi"
  fi
  record PASS pi "v${PI_PIN} ($(command -v pi))"
}

# --- trunk ------------------------------------------------------------------
# Same launcher download as scripts/conductor-trunk-preflight.sh (which
# .conductor/settings.toml runs before this script in this repo, so this
# stage is normally verify-only reuse there; the preflight pins the same
# checksum — scripts/validate-pins.sh cross-checks the two constants). Kept
# inline so the script stays a self-contained recipe for pasting (the
# gtm-sdk#702 porting rationale).
TRUNK_LAUNCHER_URL="https://trunk.io/releases/trunk"
TRUNK_LAUNCHER_SHA256="700f8bbedfd226595999ea2202b9a7af75ba8398dd711f5f159f5bbba6cbf322"
# Bump runbook: trunk publishes no versioned launcher URL, so re-download
# ${TRUNK_LAUNCHER_URL} by hand, re-hash it, and update this constant (and
# the preflight's copy) in the same commit. Last bumped 2026-10-09 for the
# 2026-10-06 launcher 1.3.5 artifact (previous pin: the 2024-11-06 one).

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

# --- entire (Entire.io CLI) -------------------------------------------------
# Pinned release tarball, fail-closed per-platform sha256. The tarball ships
# two binaries plus README/LICENSE/completions: `entire` (the CLI itself) and
# `git-remote-entire` (git's handler for `entire://` remotes — needed for
# `entire repo clone` etc.). Per-tool pins section in the header (item below
# `RWX_PIN`) covers ENTIRE_PIN + the per-platform ENTIRE_SHA256_* constants;
# scripts/validate-pins.sh enforces both the x.y.z shape and the
# constant-set/drift surface for them.
#
# Download origin: install.entire.com is the canonical CDN the Entire CLI's
# own install.sh script uses first (it's the published mirror that survives
# GitHub outages — the README/install docs name it as primary; GitHub is the
# documented fallback). Both URLs publish byte-identical tarballs with the
# same sha256, so picking the CDN keeps the script pinned to the same artifact
# the CLI's official installer would pin to. Pins update the same way as
# roborev/rwx: new pin + hand-hashed per-platform sha256 (no checksum file
# is published alongside the release).
#
# Like the other tools in this script, this stage NEVER auto-runs
# `entire enable`: that operator action is what writes .entire/settings.json
# and installs agent hook files, and committing them is a per-repo decision
# (the README documents the workflow). All this stage does is make the
# commands available so an operator can run `entire enable --agent <X>` (or
# read-only queries like `entire checkpoint list`, `entire trail list`,
# `entire review`) in any later shell.
ENTIRE_PIN="0.12.1"
# Per-platform sha256 of the entire_${platform}.tar.gz release artifact (the
# install.entire.com CDN and the GitHub release tarball are byte-identical,
# so either URL yields the same hash). Re-pin runbook in the header.
ENTIRE_SHA256_LINUX_AMD64="15645d3c41cd91e3e3dc42f91a92f02739f57c3f31233236f8f4d7c7e2029ffc"
ENTIRE_SHA256_LINUX_ARM64="371ad9a35665887bb8bff64b57cf358dfca649ceb75da545ba3f4d9ec5a4cac6"
ENTIRE_SHA256_DARWIN_AMD64="c7adf5a3e91320c81685eb3491f8a91d2551f36208ba6f82f6673a9c28ffd360"
ENTIRE_SHA256_DARWIN_ARM64="77f1a9174fd9b503f0503e776f2fa1e913cda1eba2a37772d3a6b97ad67edfb1"

entire_install() {
  # Reuse requires BOTH binaries: this stage's contract is entire plus its
  # git-remote-entire companion (entire:// remotes fail without it), so a
  # pre-existing entire without the companion must fall through to the
  # pinned install below instead of PASSing over a half install.
  if command -v entire >/dev/null 2>&1 && command -v git-remote-entire >/dev/null 2>&1; then
    record PASS entire "reused $(command -v entire) ($(entire version 2>&1 | head -1 || true))"
    return 0
  fi
  local platform asset sha256
  case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    platform="linux_amd64"
    sha256="${ENTIRE_SHA256_LINUX_AMD64:-}"
    ;;
  Linux-aarch64)
    platform="linux_arm64"
    sha256="${ENTIRE_SHA256_LINUX_ARM64:-}"
    ;;
  Darwin-x86_64)
    platform="darwin_amd64"
    sha256="${ENTIRE_SHA256_DARWIN_AMD64:-}"
    ;;
  Darwin-arm64)
    platform="darwin_arm64"
    sha256="${ENTIRE_SHA256_DARWIN_ARM64:-}"
    ;;
  *)
    log "error: no pinned entire asset for $(uname -s)-$(uname -m)"
    return 1
    ;;
  esac
  if [[ -z "${sha256}" ]]; then
    log "error: missing pinned entire sha256 for ${platform} (set ENTIRE_SHA256_${platform^^} in the pins block)"
    return 1
  fi
  asset="entire_${platform}.tar.gz"
  local url="https://install.entire.com/v${ENTIRE_PIN}/${asset}"
  local dir="${WORK}/entire"
  mkdir -p "${dir}"
  if ! curl -fsSLo "${dir}/${asset}" "${url}"; then
    return 1
  fi
  if ! checksum_verify "${sha256}" "${dir}/${asset}"; then
    return 1
  fi
  if ! tar -xzf "${dir}/${asset}" -C "${dir}" ||
    [[ ! -x "${dir}/entire" ]] || [[ ! -x "${dir}/git-remote-entire" ]]; then
    log "error: entire tarball did not yield executable ./entire and ./git-remote-entire"
    return 1
  fi
  local entire_path gre_path
  entire_path="$(install_bin "${dir}/entire" entire || true)"
  gre_path="$(install_bin "${dir}/git-remote-entire" git-remote-entire || true)"
  if [[ -z "${entire_path}" || -z "${gre_path}" ]]; then
    log "error: could not place entire / git-remote-entire in a bin directory (entire=${entire_path:-<none>}, git-remote-entire=${gre_path:-<none>})"
    return 1
  fi
  note_placement "${entire_path}"
  note_placement "${gre_path}"
  hash -r 2>/dev/null || true
  local resolved_entire resolved_gre
  resolved_entire="$(command -v entire 2>/dev/null || true)"
  resolved_gre="$(command -v git-remote-entire 2>/dev/null || true)"
  if [[ -z "${resolved_entire}" || -z "${resolved_gre}" ]]; then
    log "error: entire installed at ${entire_path} but not on PATH (or git-remote-entire missing from PATH)"
    return 1
  fi
  # Both deliverables are placed, but a pre-existing entire earlier on PATH
  # (an operator's manual install in ~/.local/bin — which setup prepends to
  # PATH — is exactly this stage's target machine, issue #91) keeps
  # resolving after the pinned install. Name that state instead of PASSing
  # a pinned-version row over a stale, shadowing binary.
  if [[ "${resolved_entire}" != "${entire_path}" || "${resolved_gre}" != "${gre_path}" ]]; then
    record WARN entire "v${ENTIRE_PIN} installed (entire: ${entire_path}, git-remote-entire: ${gre_path}) but PATH resolves entire to ${resolved_entire} and git-remote-entire to ${resolved_gre} — remove the stale binary or reorder PATH if the pinned entire must run"
    return 0
  fi
  record PASS entire "v${ENTIRE_PIN} (entire: ${entire_path}, git-remote-entire: ${gre_path})"
}

# --- python3.11 -------------------------------------------------------------
python311_stage() {
  # Single probe, no version-string parsing: exit status says whether the
  # current python3 is already >= 3.11 (also covers python3 missing).
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

# --- python dev tools: uv + pytest + reflex (opt-in) -------------------------
# Issue #44: a fresh Conductor cloud workspace has python3 but none of the
# Python dev tools agents need — `uv` and `reflex` are not on PATH (the
# Flox manifests' uv is process-scoped, activation-only) and python3 -m
# pytest fails with "No module named pytest". This stage provisions all
# three into the persistent workspace environment when (and only when)
# STARTUP_PY_DEV_TOOLS=1 asked for them; it runs after python311_stage so
# the AL2023 class's system 3.11 is already in place by then.
#
# Design, and why not the alternatives:
#   uv        a standalone release binary — same pinned, checksum-verified
#             download idiom as roborev/rwx (astral-sh/uv release tarballs;
#             digests hand-hashed from the ${UV_PIN} downloads, the same
#             method as the rwx pin — no checksum file is published on the
#             release), placed by install_bin into /usr/local/bin
#             (~/.local/bin fallback). Never the Flox catalog copy:
#             activation binaries disappear with the process.
#   pytest/   Python packages, not binaries. Installed as exact pins into
#   reflex    ONE uv-managed venv, ~/.conductor-pytools (Python 3.11: the
#             system 3.11 on the AL2023 class, a uv-managed CPython 3.11
#             download elsewhere — uv finds or fetches it either way, no
#             pip needed anywhere), with the console scripts symlinked into
#             the bin dirs by expose_link. The venv is the intended Python
#             environment for these packages (issue #44's
#             managed-environment allowance): `pytest`/`reflex` work as
#             commands from any later shell, and the module invocations
#             are ~/.conductor-pytools/bin/python -m pytest and
#             ~/.conductor-pytools/bin/python -c 'import reflex'. Per-tool
#             isolated shims (uv tool install) were rejected: they would
#             leave python -m pytest and import reflex with no single
#             home. Installing into the system python3's site-packages was
#             rejected too: same bare invocation but dnf-owned interpreter
#             pollution and PEP 668 friction, and it cannot stay clean on
#             local macOS workspaces where this setup also runs.
#
# Idempotence: uv is reuse-if-present (a functional `uv --version` check,
# not just command -v — a present-but-broken binary FAILs instead of being
# trusted; a functional uv of ANY version is reused as-is, the same
# contract as roborev/trunk/rwx — a UV_PIN bump applies to fresh installs,
# and validate-pins.sh guards the file-level drift); the venv is reused
# when its bin/python is functional (a half-created venv from an
# interrupted run is removed and recreated); `uv pip install` only runs
# when the venv does not already satisfy the exact pins, so re-runs reuse
# everything and a package-pin bump upgrades in place — no duplicate or
# competing installs, ever.
#
# Fatal under BOTH postures (see the header's failure-semantics section):
# this stage only runs on explicit request, and a requested tool that
# cannot be provisioned must fail setup loudly.
UV_PIN="0.11.26"
PYTEST_PIN="9.1.1"
REFLEX_PIN="0.9.12"
PYTOOLS_VENV="${HOME}/.conductor-pytools"
PYTOOLS_PY="${PYTOOLS_VENV}/bin/python"

pytools_uv_install() {
  if command -v uv >/dev/null 2>&1; then
    if uv --version >/dev/null 2>&1; then
      record PASS uv "reused $(command -v uv) ($(uv --version 2>&1 | head -1 || true))"
      return 0
    fi
    record FAIL uv "uv present at $(command -v uv) but not functional (uv --version failed) — remove it and re-run setup"
    return 1
  fi
  # Asset names are uv-<arch>-<vendor>-<os>.tar.gz (uv's own naming, NOT
  # the os-arch triple roborev/rwx use); each extracts into a directory of
  # the same name containing ./uv.
  local asset sha256 dir path
  case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    asset="uv-x86_64-unknown-linux-gnu.tar.gz"
    sha256="6426a73c3837e6e2483ee344cbc00f36394d179afcba6183cb77437e67db4af0"
    ;;
  Linux-aarch64)
    asset="uv-aarch64-unknown-linux-gnu.tar.gz"
    sha256="befa1a59c91e96eb601b0fd9a97c03dd666f17baba644b2b4db9c59a767e387e"
    ;;
  Darwin-x86_64)
    asset="uv-x86_64-apple-darwin.tar.gz"
    sha256="922b460202707dd5f4ccacbadbe7f6a546cc46e82a99bf50ca99a7977a78eddd"
    ;;
  Darwin-arm64)
    asset="uv-aarch64-apple-darwin.tar.gz"
    sha256="8f7fbf1708399b921857bce71e1d60f0d3ccf52a30caebc1c1a2f175dce13ab6"
    ;;
  *)
    record FAIL uv "no pinned uv ${UV_PIN} asset for $(uname -s)-$(uname -m)"
    return 1
    ;;
  esac
  dir="${WORK}/uv"
  mkdir -p "${dir}"
  if ! curl -fsSLo "${dir}/${asset}" "https://github.com/astral-sh/uv/releases/download/${UV_PIN}/${asset}"; then
    return 1
  fi
  if ! checksum_verify "${sha256}" "${dir}/${asset}"; then
    return 1
  fi
  if ! tar -xzf "${dir}/${asset}" -C "${dir}" || [[ ! -x "${dir}/${asset%.tar.gz}/uv" ]]; then
    log "error: uv tarball did not yield an executable ${asset%.tar.gz}/uv"
    return 1
  fi
  path="$(install_bin "${dir}/${asset%.tar.gz}/uv" uv || true)"
  if [[ -z "${path}" ]]; then
    log "error: could not place the uv binary in a bin directory"
    return 1
  fi
  note_placement "${path}"
  hash -r 2>/dev/null || true
  if ! uv --version >/dev/null 2>&1; then
    log "error: installed uv binary failed its version check"
    return 1
  fi
  record PASS uv "v${UV_PIN} (${path})"
}

# venv_version <dist>: the venv's installed version of distribution <dist>
# via importlib.metadata (works for every installed dist; no import of the
# package itself, which would be slow for reflex). Prints nothing on
# failure.
venv_version() {
  "${PYTOOLS_PY}" -c "import importlib.metadata as m; print(m.version('$1'))" 2>/dev/null || true
}

pytools_stage() {
  if [[ "${STARTUP_PY_DEV_TOOLS:-0}" != "1" ]]; then
    record SKIP pytools "not requested — set STARTUP_PY_DEV_TOOLS=1 to provision uv/pytest/reflex (this repo's settings.toml does)"
    return 0
  fi
  pytools_uv_install || return 1
  # Heal a half-created venv (an interrupted earlier run): a directory
  # without a functional bin/python is removed so uv can recreate it.
  if [[ -d "${PYTOOLS_VENV}" && ! -x "${PYTOOLS_PY}" ]]; then
    log "removing broken pytools venv at ${PYTOOLS_VENV} (no functional bin/python)"
    rm -rf "${PYTOOLS_VENV}"
  fi
  local venv_reused=1
  if [[ ! -x "${PYTOOLS_PY}" ]]; then
    venv_reused=0
    if ! uv venv --python 3.11 "${PYTOOLS_VENV}"; then
      record FAIL pytools-venv "uv venv --python 3.11 ${PYTOOLS_VENV} failed (see output above)"
      return 1
    fi
  fi
  if [[ ! -x "${PYTOOLS_PY}" ]]; then
    record FAIL pytools-venv "venv at ${PYTOOLS_VENV} has no functional bin/python"
    return 1
  fi
  local pyver
  pyver="$("${PYTOOLS_PY}" --version 2>&1 | head -1 || true)"
  if [[ ${venv_reused} == 1 ]]; then
    record PASS pytools-venv "reused ${PYTOOLS_VENV} (${pyver})"
  else
    record PASS pytools-venv "${pyver} at ${PYTOOLS_VENV}"
  fi
  # Packages: install to the exact pins only when the venv does not
  # already satisfy them — a satisfied pin is left untouched (the reuse
  # path stays network-free), a stale or missing one is upgraded/healed in
  # place by the same command.
  local pytest_before reflex_before
  pytest_before="$(venv_version pytest)"
  reflex_before="$(venv_version reflex)"
  if [[ "${pytest_before}" != "${PYTEST_PIN}" || "${reflex_before}" != "${REFLEX_PIN}" ]]; then
    if ! uv pip install --python "${PYTOOLS_PY}" "pytest==${PYTEST_PIN}" "reflex==${REFLEX_PIN}"; then
      record FAIL pytools-pkg "uv pip install pytest==${PYTEST_PIN} reflex==${REFLEX_PIN} failed (see output above)"
      return 1
    fi
  fi
  local pytest_after reflex_after
  pytest_after="$(venv_version pytest)"
  reflex_after="$(venv_version reflex)"
  if [[ "${pytest_after}" != "${PYTEST_PIN}" ]]; then
    record FAIL pytest "venv does not provide pytest ${PYTEST_PIN} after install (resolved: ${pytest_after:-<none>})"
    return 1
  fi
  if [[ "${reflex_after}" != "${REFLEX_PIN}" ]]; then
    record FAIL reflex "venv does not provide reflex ${REFLEX_PIN} after install (resolved: ${reflex_after:-<none>})"
    return 1
  fi
  # Expose the console scripts as commands for later shells. note_placement
  # happens HERE, not inside expose_link: the link helpers run inside
  # command substitution and a subshell's LOCAL_FALLBACK_TOOLS update
  # would die there (the same trap roborev/trunk/rwx sidestep by noting
  # the captured path at the call site).
  local pytest_link reflex_link
  pytest_link="$(expose_link "${PYTOOLS_VENV}/bin/pytest" pytest || true)"
  reflex_link="$(expose_link "${PYTOOLS_VENV}/bin/reflex" reflex || true)"
  if [[ -z "${pytest_link}" || -z "${reflex_link}" ]]; then
    record FAIL pytools "could not expose pytest/reflex commands (pytest link: ${pytest_link:-<none>}, reflex link: ${reflex_link:-<none>})"
    return 1
  fi
  note_placement "${pytest_link}"
  note_placement "${reflex_link}"
  hash -r 2>/dev/null || true
  # Final verification — the acceptance surface itself, re-proven on every
  # run so a REUSED install is proven functional, not just presumed:
  # commands resolve and report versions, and the documented module
  # invocations work in the venv.
  local pytest_cmd reflex_cmd
  pytest_cmd="$(command -v pytest || true)"
  reflex_cmd="$(command -v reflex || true)"
  if [[ -z "${pytest_cmd}" ]] || ! pytest --version >/dev/null 2>&1; then
    record FAIL pytest "pytest command does not resolve or run after exposure (resolved: ${pytest_cmd:-<none>})"
    return 1
  fi
  if [[ -z "${reflex_cmd}" ]] || ! reflex --version >/dev/null 2>&1; then
    record FAIL reflex "reflex command does not resolve or run after exposure (resolved: ${reflex_cmd:-<none>})"
    return 1
  fi
  if ! "${PYTOOLS_PY}" -m pytest --version >/dev/null 2>&1; then
    record FAIL pytest "venv python -m pytest failed — the module is not runnable in the intended environment"
    return 1
  fi
  if ! "${PYTOOLS_PY}" -c 'import reflex' >/dev/null 2>&1; then
    record FAIL reflex "import reflex failed in the intended environment"
    return 1
  fi
  if [[ "${pytest_before}" == "${PYTEST_PIN}" ]]; then
    record PASS pytest "reused ${pytest_after} (command: ${pytest_cmd}; env: ~/.conductor-pytools)"
  else
    record PASS pytest "${pytest_after} installed into ~/.conductor-pytools (command: ${pytest_cmd})"
  fi
  if [[ "${reflex_before}" == "${REFLEX_PIN}" ]]; then
    record PASS reflex "reused ${reflex_after} (command: ${reflex_cmd}; env: ~/.conductor-pytools)"
  else
    record PASS reflex "${reflex_after} installed into ~/.conductor-pytools (command: ${reflex_cmd})"
  fi
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

# --- roborev setup -----------------------------------------------------------
# Reviews in a provisioned workspace run ON DEMAND and BLOCKING: the push
# gate the repo's agent instructions and create-pr prompt define is
# `roborev review --wait`, which enqueues if needed and blocks until a
# verdict exists. A post-commit auto-review hook is the opposite posture —
# `roborev post-commit` (the hook entry point) only enqueues a background
# daemon job, with no blocking form — so this setup NEVER installs one:
# `roborev init` is not run at all (it installs the post-commit and
# post-rewrite hooks and has no flag to suppress that — only
# --agent/--no-daemon), .roborev.toml is therefore written directly (a
# committed one is the repo's own configuration and is never clobbered),
# the daemon is ensured for the blocking reviews, and a roborev hook left
# behind by an older setup of this script (or a bare `roborev init`) is
# actively removed. A machine-global hooks dir (core.hooksPath) is never
# touched — if a roborev hook is found there, a WARN tells the user to
# remove it by hand. Everything is anchored to `git rev-parse
# --show-toplevel` so running setup from a subdirectory cannot misfire.
ROBOREV_AGENT_DEFAULT="pi"
# Default model for ROBOREV_AGENT=pi (issue #85's verified-working pair).
# The `fireworks/` provider prefix is required: a bare
# `accounts/fireworks/models/...` is rejected by roborev as `Model ... not
# found`, and `~/.pi/agent/settings.json`'s `defaultProvider` does NOT fix
# this surface (issue #85's gotcha). Empty string disables the line — roborev
# then decides; the comment in the toml writer explains what each branch
# means.
ROBOREV_MODEL_DEFAULT="fireworks/accounts/fireworks/models/glm-5p3"

# roborev_quiet <args...>: a roborev CLI call whose output is discarded and
# which may touch — or lazily start — the daemon. The daemon is long-lived,
# and this script keeps its original stdout/stderr as fds 3/4 for the whole
# run (the summary surfaces there at the end). A daemon spawned with those
# fds inherited holds the caller's capture pipe open forever, so any
# $(...)-style consumer of this script deadlocks after the script itself
# exits cleanly — the mechanism behind the stalled container runs, where
# RUN 22 was the suite's first execution to run the real (non-stubbed)
# roborev against a down daemon: 'roborev status' lazily starts it. Every
# daemon-touching call therefore runs with stdio redirected and the spare
# fds closed; the CLI already points the daemon's own stdout/stderr at its
# logs.
roborev_quiet() {
  roborev "$@" </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
}

# ensure_daemon <stage>: status → PASS "daemon running"; start → PASS
# "daemon revived"; neither → FAIL under <stage> (deferred setup failure).
# One call site today (roborev-daemon, after the hook posture and the
# repo config) — kept as a helper so a future second caller cannot
# copy-paste the failure handling into divergent variants (roborev
# review finding).

# find_repo_root: discover a git worktree when setup runs from a
# non-worktree cwd (issue #101). Conductor cloud sandboxes run the
# install script from $HOME — "/home/vercel-sandbox", NOT from inside
# the cloned repo — so without help every roborev stage (the .roborev.toml
# write and the hook posture that needs a .git dir) silently SKIPs and
# a fresh workspace comes up "daemon live, no agent smoke check, no toml
# written". Resolution order, conservative by design — auto-discovery
# only fires when the result is unambiguous:
#   1. CONDUCTOR_WORKSPACE_PATH, when set AND resolvable via `git -C <p>
#      rev-parse --show-toplevel`. Conductor exposes this env var to its
#      install scripts (the only place the script can know where the repo
#      sits); operators in a non-Conductor setup can also set it by hand.
#   2. A single git worktree directly under $HOME — the path Conductor
#      clones into. Two or more worktrees at the top level is taken as
#      ambiguous and we fall through (return 1), so a workspace that
#      happens to have multiple clones under $HOME never gets the wrong
#      repo's .roborev.toml silently.
#   3. Otherwise return 1, and the roborev stage records a loud WARN
#      naming the gap and still runs the daemon + smoke check (the parts
#      that don't need a repo root).
# Prints the toplevel on stdout; returns 0 on success, 1 otherwise.
# Never writes anything; never changes cwd. No process substitution
# (gtm-sdk#279: sandboxes can lack /dev/fd, and `set -e` then kills the
# script silently — same rule as every sandbox-bound script in this repo).
find_repo_root() {
  local toplevel found=() dir
  if [[ -n "${CONDUCTOR_WORKSPACE_PATH:-}" ]]; then
    if toplevel="$(git -C "${CONDUCTOR_WORKSPACE_PATH}" rev-parse --show-toplevel 2>/dev/null)"; then
      printf '%s\n' "${toplevel}"
      return 0
    fi
  fi
  # Plain unquoted glob — pathname expansion results are never re-split,
  # so spaces in repo names survive. The path is required to end with a
  # slash via `"${HOME}"/*/`, so plain files at $HOME's top level are
  # skipped automatically (the glob doesn't match them); only directories
  # make it through, then we still require a `.git` child to be a worktree.
  for dir in "${HOME}"/*/; do
    [[ -d "${dir%/}/.git" ]] || continue
    if toplevel="$(git -C "${dir%/}" rev-parse --show-toplevel 2>/dev/null)"; then
      found+=("${toplevel}")
    fi
  done
  if [[ ${#found[@]} -eq 1 ]]; then
    printf '%s\n' "${found[0]}"
    return 0
  fi
  return 1
}

# roborev_smoke_check <agent> <repo_root>: verify the configured agent
# actually answers a smoke prompt — this is what makes reviews work end
# to end. Non-fatal: a wrong agent choice or a transient failure
# shouldn't fail setup when roborev itself installed. <repo_root> is
# empty in the no-worktree fallback (issue #101), in which case there's
# no .roborev.toml to read the configured model from — fall back to a
# best-guess assumption: if the agent is pi (the script's default and
# the most common case), the ROBOREV_MODEL_DEFAULT below would have been
# written to .roborev.toml in the with-worktree path, so treat the
# fireworks_model flag as on so the WARN row points at FIREWORKS_API_KEY
# rather than a generic "agent failed". For pi a generic FAIL row hides
# the FIREWORKS_API_KEY root cause and the operator never fixes it —
# RUN 18 captured that exact regression.
roborev_smoke_check() {
  local agent="$1" repo_root="$2"
  local fireworks_model=0
  if [[ -n "${repo_root}" && -f "${repo_root}/.roborev.toml" ]]; then
    if grep -q '^model = "fireworks/' "${repo_root}/.roborev.toml" 2>/dev/null; then
      fireworks_model=1
    fi
  elif [[ "${agent}" == "pi" ]]; then
    fireworks_model=1
  fi
  # .env.cloud ships a <fireworks-api-key> placeholder; an unreplaced
  # one is as useless as an unset key, so name it rather than fall to
  # the generic row.
  local fireworks_key_state=""
  if [[ -z "${FIREWORKS_API_KEY:-}" ]]; then
    fireworks_key_state="is unset"
  elif [[ "${FIREWORKS_API_KEY}" == "<"*">" ]]; then
    fireworks_key_state="is still the .env.cloud placeholder"
  fi
  # .roborev.toml exists by now in the with-worktree path and is never
  # rewritten, so ROBOREV_AGENT alone cannot change the agent on a
  # re-run: say how to actually switch.
  local switch_hint="or switch agents by editing the agent line in .roborev.toml (it wins over ROBOREV_AGENT), or delete it, set ROBOREV_AGENT, and re-run setup"
  if roborev_quiet check-agents --agent "${agent}" --timeout 30; then
    record PASS roborev-agent "${agent} answered a smoke prompt — reviews are live"
  else
    if [[ "${agent}" == "pi" ]] && ! command -v pi >/dev/null 2>&1; then
      record WARN roborev-agent "pi is not installed (see the pi row above) — install Node ${PI_NODE_MIN}+ and re-run setup, ${switch_hint}"
    elif [[ "${agent}" == "pi" && "${fireworks_model}" == 1 && -n "${fireworks_key_state}" ]]; then
      record WARN roborev-agent "${agent} smoke failed and FIREWORKS_API_KEY ${fireworks_key_state} — Pi + Fireworks cannot review without the key; export it in Conductor env vars (the script header documents it) and re-run setup, ${switch_hint}"
    else
      record WARN roborev-agent "${agent} failed its smoke check — reviews may not run; inspect with roborev check-agents, ${switch_hint}"
    fi
  fi
}
ensure_daemon() {
  local stage="$1"
  if roborev_quiet status; then
    record PASS "${stage}" "daemon running"
  elif roborev_quiet daemon start; then
    record PASS "${stage}" "daemon revived"
  else
    record FAIL "${stage}" "daemon not running and 'roborev daemon start' failed"
    return 1
  fi
}

roborev_setup() {
  local agent="${ROBOREV_AGENT:-${ROBOREV_AGENT_DEFAULT}}" repo_root=""
  # ROBOREV_AGENT gets written into .roborev.toml, so gate it syntactically
  # (a lowercase slug: letters, digits, hyphens) — quotes, newlines, or
  # spaces would corrupt the TOML. Deliberately NOT a hard-coded agent
  # allowlist: the accepted set differs across roborev versions (the pinned
  # 0.63.0 and a reused older binary disagree), so an allowlist here would
  # reject valid agents on the reuse path; the check-agents smoke check
  # below remains the semantic check.
  if [[ -n "${ROBOREV_AGENT:-}" && ! "${agent}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    # The raw value is deliberately NOT replayed in the row: a value with
    # newlines or control characters — exactly what this gate stops — would
    # split or spoof the multi-line setup summary.
    record WARN roborev-config "ROBOREV_AGENT is malformed (expected a lowercase agent slug like pi) — using ${ROBOREV_AGENT_DEFAULT}; check the environment variable"
    agent="${ROBOREV_AGENT_DEFAULT}"
  fi
  # `git roborev ...` (the push-gate spelling): native git-subcommand
  # resolution via the git-roborev symlink, plus a global alias as backup.
  git config --global alias.roborev '!roborev' || true
  if ! command -v roborev >/dev/null 2>&1; then
    record SKIP roborev-config "roborev not installed — skipping setup (see the roborev install row above)"
    return 0
  fi
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local discovered=""
    # Issue #101: Conductor cloud sandboxes run setup from $HOME, not from
    # inside the cloned repo, so without auto-discovery every roborev
    # stage below (the .roborev.toml write + the hook posture that needs
    # a .git dir) silently SKIPs and a fresh workspace comes up "daemon
    # live, no agent smoke check, no toml written". Try find_repo_root:
    # the daemon ensure still needs to run when cwd isn't a worktree, so
    # even a discovery miss shouldn't bail us out before that. A short
    # log line surfaces the auto-discovery — it doesn't earn a summary
    # row because the later .roborev.toml-write or no-worktree-fallback
    # rows already carry the result.
    if discovered="$(find_repo_root)"; then
      log "[context] roborev-config — cwd is not a worktree; using ${discovered} (issue #101, find_repo_root)"
      cd "${discovered}"
      repo_root="${discovered}"
    else
      # No worktree to write into. Run the parts that don't need one
      # (the daemon and the smoke check — both daemon-side, neither
      # touches the filesystem) and surface a single loud WARN naming
      # the gap, so the operator knows .roborev.toml never landed and
      # reviews can't read a committed agent.
      record WARN roborev-config "cwd is not a git worktree and no repo found via CONDUCTOR_WORKSPACE_PATH or \$HOME (issue #101) — skipping .roborev.toml + hook posture; run setup from inside the repo, or set CONDUCTOR_WORKSPACE_PATH=/path/to/repo and re-run; daemon + smoke check still ran below"
      mkdir -p "${HOME}/.roborev" 2>/dev/null || true
      ensure_daemon roborev-daemon || return 1
      roborev_smoke_check "${agent}" ""
      return 0
    fi
  else
    repo_root="$(git rev-parse --show-toplevel)"
    cd "${repo_root}"
  fi
  # Hook posture FIRST: no roborev auto-review hook may survive — a
  # leftover from an older setup of this script (or a bare `roborev init`)
  # would keep enqueueing background reviews on every commit. Removal
  # needs neither the repo config nor the daemon, so it runs BEFORE those
  # steps: a degraded run (toml write or daemon start failing) must never
  # leave this repo still auto-reviewing in the background. `git rev-parse
  # --git-path` resolves worktrees correctly; a machine-global hooks dir
  # (core.hooksPath) is never touched. Detection matches what roborev's
  # own installer writes — the "roborev post-commit" / "roborev
  # post-rewrite" hook content — NOT the bare word "roborev": detection
  # here escalates to `roborev uninstall-hook`, and a user's own hook that
  # merely mentions roborev (e.g. one that manually runs
  # `roborev review --wait` after each commit) is foreign and must be
  # left untouched, not removed.
  local hook hook_rw rr_hooks=""
  hook="$(git rev-parse --git-path hooks/post-commit)"
  hook_rw="$(git rev-parse --git-path hooks/post-rewrite)"
  if [[ -f "${hook}" ]] && grep -q 'roborev post-commit' "${hook}"; then rr_hooks=" ${hook}"; fi
  if [[ -f "${hook_rw}" ]] && grep -q 'roborev post-rewrite' "${hook_rw}"; then rr_hooks="${rr_hooks} ${hook_rw}"; fi
  if [[ -n "$(git config core.hooksPath)" ]]; then
    if [[ -n "${rr_hooks}" ]]; then
      record WARN roborev-hook "core.hooksPath resolves to a machine-global hooks dir holding a roborev hook (${rr_hooks}) — this script will not touch it; remove it by hand (roborev uninstall-hook from a repo that resolves there) so reviews stop firing in the background"
    else
      record PASS roborev-hook "machine-global hooks dir (core.hooksPath) left untouched; no roborev auto-review hook — reviews run on demand with --wait"
    fi
  elif [[ -n "${rr_hooks}" ]]; then
    # Snapshot which of the two hooks are FOREIGN (present, but not
    # roborev's) before uninstalling: `roborev uninstall-hook` removes
    # roborev's hook pair, and if it also takes a foreign sibling with it,
    # the post-check below must report that as a WARN naming the path —
    # never a PASS recorded over a deleted user hook. The vanished check
    # runs on BOTH uninstall outcomes: a worst-case uninstaller may
    # delete a foreign sibling AND exit non-zero, and the user must be
    # told what was lost either way.
    local foreign_pc="" foreign_rw=""
    if [[ -f "${hook}" ]] && ! grep -q 'roborev post-commit' "${hook}"; then foreign_pc="${hook}"; fi
    if [[ -f "${hook_rw}" ]] && ! grep -q 'roborev post-rewrite' "${hook_rw}"; then foreign_rw="${hook_rw}"; fi
    local uninstall_rc=0
    roborev uninstall-hook || uninstall_rc=$?
    local vanished=""
    if [[ -n "${foreign_pc}" && ! -f "${foreign_pc}" ]]; then vanished=" ${foreign_pc}"; fi
    if [[ -n "${foreign_rw}" && ! -f "${foreign_rw}" ]]; then vanished="${vanished} ${foreign_rw}"; fi
    if [[ ${uninstall_rc} -ne 0 ]]; then
      if [[ -n "${vanished}" ]]; then
        record WARN roborev-hook "'roborev uninstall-hook' failed AND removed a non-roborev hook as collateral:${vanished} — restore it, remove the roborev hook(s) at${rr_hooks} by hand, and re-run setup"
      else
        record WARN roborev-hook "'roborev uninstall-hook' failed — remove the roborev hook(s) at${rr_hooks} by hand so reviews stop firing in the background"
      fi
    elif [[ -n "${vanished}" ]]; then
      record WARN roborev-hook "'roborev uninstall-hook' removed a non-roborev hook as collateral:${vanished} — restore it and re-run setup; roborev's own hook removal is otherwise complete"
    else
      local leftover=""
      if [[ -f "${hook}" ]] && grep -q 'roborev post-commit' "${hook}"; then leftover=" ${hook}"; fi
      if [[ -f "${hook_rw}" ]] && grep -q 'roborev post-rewrite' "${hook_rw}"; then leftover="${leftover} ${hook_rw}"; fi
      if [[ -z "${leftover}" ]]; then
        record PASS roborev-hook "removed a leftover roborev auto-review hook — reviews are on demand only, always with --wait"
      else
        record WARN roborev-hook "'roborev uninstall-hook' left roborev hook content at${leftover} — remove it by hand so reviews stop firing in the background"
      fi
    fi
  elif [[ -f "${hook}" || -f "${hook_rw}" ]]; then
    record PASS roborev-hook "a non-roborev post-commit/post-rewrite hook exists — left untouched; no roborev auto-review installed"
  else
    record PASS roborev-hook "no post-commit hook — reviews run on demand with --wait, never in the background"
  fi
  # Repo config, written directly — `roborev init` is deliberately never
  # run: it installs the post-commit/post-rewrite auto-review hooks and has
  # no flag to suppress that, and a background-only review posture is
  # exactly what this setup must not leave behind. A committed
  # .roborev.toml is the repo's own configuration and is never clobbered.
  # Sweep a stale temp from an interrupted earlier run first (idempotent by
  # contract); the glob is safe unquoted — pathname-expansion results are
  # never re-split, spaces in repo_root included.
  rm -f "${repo_root}"/.roborev.toml.tmp.* 2>/dev/null || true
  if [[ -f "${repo_root}/.roborev.toml" ]]; then
    # Never rewritten (a script-written file may since have been committed),
    # but one from before issue #85 still names claude-code, which never
    # reaches a cloud sandbox: say so instead of passing it silently.
    if grep -q '^# Written by conductor-startup-script-cloud.sh' "${repo_root}/.roborev.toml" &&
      grep -q '^agent = "claude-code"$' "${repo_root}/.roborev.toml"; then
      record WARN roborev-config ".roborev.toml was written by an earlier setup with agent claude-code, which cannot review in cloud sandboxes (issue #85) — delete it and re-run setup to get the pi default, or edit agent/model by hand"
    else
      record PASS roborev-config ".roborev.toml already present"
    fi
    # ROBOREV_MODEL only applies when the file is written; flag a set value
    # the existing file does not already reflect (value never replayed).
    if [[ -n "${ROBOREV_MODEL+x}" ]]; then
      local model_applied=1
      if [[ -n "${ROBOREV_MODEL}" && ! "${ROBOREV_MODEL}" =~ ^[~a-zA-Z0-9_./:@-]+$ ]]; then
        # Same gate as the write path; a newline would split grep -F's pattern.
        model_applied=0
      elif [[ -n "${ROBOREV_MODEL}" ]]; then
        grep -qxF 'model = "'"${ROBOREV_MODEL}"'"' "${repo_root}/.roborev.toml" || model_applied=0
      elif grep -q '^model' "${repo_root}/.roborev.toml"; then
        model_applied=0
      fi
      if [[ ${model_applied} -eq 0 ]]; then
        record WARN roborev-config "ROBOREV_MODEL is set but .roborev.toml already exists and is never rewritten — edit its model line by hand, or delete the file and re-run setup"
      fi
    fi
    # Reviews run the agent this file names, so smoke-check that one rather
    # than the environment's; same slug gate as ROBOREV_AGENT, since the
    # value lands in summary rows.
    local line file_agent=""
    # `|| [[ -n ... ]]` keeps a last line that has no trailing newline.
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
      'agent = "'*'"')
        file_agent="${line#'agent = "'}"
        file_agent="${file_agent%'"'}"
        break
        ;;
      esac
    done <"${repo_root}/.roborev.toml"
    if [[ "${file_agent}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      agent="${file_agent}"
    fi
  else
    # ROBOREV_MODEL writes a second `model = "..."` line under the agent.
    # Same syntactic gate as agent: a model string lands verbatim in TOML, so
    # quotes/newlines/control chars corrupt the file. Reject them and fall
    # back to no model line (roborev then decides what default model to
    # pick — better than emitting broken TOML).
    # An explicitly empty ROBOREV_MODEL means "no model line" (see the
    # header). Unset takes the default only for pi: the Fireworks slug is
    # pi's verified pair, not a model another agent can resolve.
    local model=""
    if [[ -n "${ROBOREV_MODEL+x}" ]]; then
      model="${ROBOREV_MODEL}"
    elif [[ "${agent}" == "pi" ]]; then
      model="${ROBOREV_MODEL_DEFAULT}"
    fi
    if [[ -n "${model}" && ! "${model}" =~ ^[~a-zA-Z0-9_./:@-]+$ ]]; then
      # The raw value is deliberately NOT replayed in the row: ctrl chars in
      # a value would split or spoof the multi-line summary, the same
      # reason the agent gate above never replays ROBOREV_AGENT raw.
      record WARN roborev-config "ROBOREV_MODEL is malformed — omitting model line; check the environment variable"
      model=""
    fi
    local toml_tmp
    # mktemp IN the repo root so the final mv is a same-filesystem rename —
    # a $TMPDIR temp would make mv a cross-device copy+unlink, not atomic
    # (the same reasoning as the rwx token stage's same-dir temp).
    toml_tmp="$(mktemp "${repo_root}/.roborev.toml.tmp.XXXXXX")"
    local toml_status=0
    local toml_fmt='# Written by conductor-startup-script-cloud.sh — reviews here are\n# on demand and blocking (roborev review --wait); no post-commit\n# auto-review hook is installed (see that script for the reasoning).\nagent = "%s"\n'
    local toml_args=("${agent}") written="agent: ${agent}"
    if [[ -n "${model}" ]]; then
      toml_fmt+='model = "%s"\n'
      toml_args+=("${model}")
      written+=", model: ${model}"
    fi
    # shellcheck disable=SC2059  # the format is the fixed literal above; values go through %s
    printf "${toml_fmt}" "${toml_args[@]}" >"${toml_tmp}" || toml_status=$?
    if [[ ${toml_status} -eq 0 ]] && mv -f "${toml_tmp}" "${repo_root}/.roborev.toml"; then
      record PASS roborev-config ".roborev.toml written (${written}) — reviews on demand, always with --wait"
    else
      rm -f "${toml_tmp}"
      record FAIL roborev-config "could not write ${repo_root}/.roborev.toml"
      return 1
    fi
  fi
  # The daemon serves the blocking reviews (`review --wait` enqueues into
  # it and blocks until the verdict), so it must be up even with no
  # auto-review hook. `roborev init` used to create ~/.roborev as a side
  # effect; with init gone, ensure the dir exists ourselves — daemon start
  # bootstraps it (verified live against the real binary), but the mkdir is
  # cheap insurance across roborev versions on the reuse path.
  mkdir -p "${HOME}/.roborev" 2>/dev/null || true
  ensure_daemon roborev-daemon || return 1
  roborev_smoke_check "${agent}" "${repo_root}"
}

# --- run -------------------------------------------------------------------
# STARTUP_BEST_EFFORT=1 (exported by this repo's settings.toml) keeps the
# former cloud-install contract: tool-stage failures are recorded but do
# not fail the run (gtm-sdk#702's fallback-installer idiom). Default
# (pasted standalone): any FAIL row fails the run. Python 3.11 on the
# target class and the pytools stage (when STARTUP_PY_DEV_TOOLS=1
# requested it) are hard requirements under EITHER posture — their SKIP
# paths return 0 and never reach the FAILED assignment; pytools' gate
# SKIP likewise returns 0.
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
# entire follows rwx in the tool-stage chain (issue #91): a Go release
# binary with a per-platform sha256 pin, README/LICENSE/completions, and a
# companion `git-remote-entire` helper that Git invokes for `entire://`
# remotes. Operator-driven `entire enable` is never run here — committing
# .entire/settings.json and the agent hook files is a per-repo decision the
# README documents separately. Like the other tool stages above, a
# provisioning failure is fatal under the default posture, recorded-but-
# non-fatal under STARTUP_BEST_EFFORT=1.
if entire_install; then :; else record FAIL entire "provisioning failed — see messages above"; maybe_fail; fi
# pi runs before python311 so a fresh sandbox with no Node gets the SKIP row
# (the script never auto-installs Node 22 — that would expand the surface
# past issue #85's intent: a default agent that works where Node is present,
# a clean SKIP where it isn't, and ROBOREV_AGENT for consumers who want
# something else). A pi install failure is never fatal, under either
# posture: pi is left uninstalled with a WARN row (the error, e.g. an
# integrity mismatch, is in the log above it) and the roborev-agent smoke
# row repeats that reviews have no agent. Owner decision: a review agent is
# not worth failing workspace setup over.
if pi_install; then :; else record WARN pi "install failed — pi was not installed (see messages above); fix and re-run setup, or set ROBOREV_AGENT=opencode / an already-installed agent"; fi
if python311_stage; then :; else FAILED=1; record FAIL python3.11 "provisioning failed — see messages above"; fi
if pytools_stage; then :; else FAILED=1; record FAIL pytools "provisioning failed — see the rows above"; fi
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
# STARTUP_BEST_EFFORT=1 only a target-class Python 3.11 failure or a
# pytools-stage failure (the requested-tools requirement, issue #44)
# reaches this exit; tool FAIL rows were recorded and the run exits 0 (the
# gtm-sdk#702 idiom this repo's settings.toml contracts for). The error
# goes to the original stderr (fd 4) as well as the log.
if [[ "${FAILED}" != 0 ]]; then
  log "error: setup finished with FAIL rows — see the summary and $SETUP_LOG"
  echo "error: setup finished with FAIL rows — see the summary and $SETUP_LOG" >&4 || true
  exit 1
fi
