#!/usr/bin/env bash
# shellcheck disable=SC2312  # $(...) in assignments and rows: stage failures surface through the stages' own || returns and the summary, not by killing the script mid-row
# The single Conductor workspace startup script: roborev + trunk + rwx +
# Python 3.11 + the opt-in Python dev tools (uv/pytest/reflex) + the opt-in
# issue #40 workstreams (flox bootstrap, FloxHub token, host-repo env
# activation; headless trunk merge login), then the auth/init that makes
# them work rather than merely exist.
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
#   flox     opt-in (STARTUP_FLOX_ENV=1, issue #40 Workstream A — the
#            gtm-sdk#506 completion): three stages. flox-bootstrap makes
#            flox work on a fresh Linux sandbox (stable-channel rpm via
#            dnf, deb via apt-get elsewhere, /dev/fd created when the
#            sandbox ships without it, the nix-daemon hand-started because
#            systemd is offline here, plus a ~/.bashrc guard so later
#            shells re-start the daemon after a death); floxhub-token
#            resolves FLOXHUB_TOKEN (environment, the host repo's
#            .env.local, then Infisical — with a best-effort standalone
#            infisical CLI install first, because auth must precede the
#            activation that would otherwise provide infisical) and
#            exports it as FLOX_FLOXHUB_TOKEN, Flox's documented CI
#            pattern — no flox auth login, no keyring write, so the
#            sandbox is never persistently authenticated; flox-activate
#            materializes the host repo's committed .flox env in run mode
#            (private-catalog manifests such as gtm-sdk's elvis/roborev
#            pin resolve through the token) and proves the run bin dir
#            landed under .flox/run. Fatal under BOTH postures when the
#            requested surface fails — the pytools contract.
#   trunk-   opt-in (STARTUP_TRUNK_MERGE_AUTH=1, issue #40 Workstream B —
#   merge-   the gtm-sdk#702 completion): provisions the headless
#   auth     ~/.cache/trunk/user.yaml login from TRUNK_USER_YAML (the same
#            lookup order as the token stage). trunk check is fully
#            unauthenticated by design; only trunk merge consumes the
#            login, and no env-var auth exists for it (trunk login is
#            browser-only — findings/20261005-152730Z). Never clobbers an
#            existing login, 0600, shape-checked, never echoed. Same
#            fatal-under-both contract.
#
# Pins: ROBOREV_PIN/RWX_PIN/UV_PIN/PYTEST_PIN/REFLEX_PIN and every sha256
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
# gtm-sdk#944 — this file is now the pin's only executable home.)
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
# their FAIL rows but do not fail the run, and only a Python 3.11 failure
# on the AL2023 target class (the stated >=3.11 requirement), a
# pytools-stage failure when STARTUP_PY_DEV_TOOLS=1 requested them
# (issue #44: a requested tool that cannot be provisioned must never
# leave a workspace that appears ready but lacks it), or a failure in the
# issue #40 opt-in stages when their flags requested them — the same
# requested-surface contract — exits non-zero.
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
#                     is the semantic check. Defaults to claude-code,
#                     which Conductor cloud sandboxes ship
#                     pre-authenticated.
#   STARTUP_BEST_EFFORT  set to 1 (this repo's settings.toml does) to make
#                     the tool stages recorded-but-non-fatal; see the
#                     failure-semantics section above.
#   STARTUP_PY_DEV_TOOLS  set to 1 (this repo's settings.toml does) to
#                     provision uv/pytest/reflex; see the tool list and
#                     the pytools stage body. Unset or any other value
#                     records a SKIP row and changes nothing else — the
#                     paste-ready consumer's surface stays as it was.
#   STARTUP_FLOX_ENV  set to 1 (issue #40 Workstream A) to provision the
#                     flox workstream: bootstrap, FloxHub token, host-repo
#                     env activation — see the flox section's stage bodies
#                     for what each stage does and its SKIP shapes. Unset
#                     or any other value records SKIP rows and changes
#                     nothing else. A failure in a requested stage exits
#                     non-zero under BOTH postures.
#   STARTUP_TRUNK_MERGE_AUTH  set to 1 (issue #40 Workstream B) to
#                     provision the headless trunk merge login from
#                     TRUNK_USER_YAML. Unset or any other value records a
#                     SKIP row and changes nothing else; trunk check never
#                     needs it. Same fatal contract as STARTUP_FLOX_ENV.
#   The flag-on stages also read (same never-inline rule):
#   FLOXHUB_TOKEN     a FloxHub token from flox auth token on an
#                     authenticated machine (a dedicated service account
#                     per Flox's CI docs); validated with flox auth status
#                     before use. Also readable from the host repo's
#                     .env.local or, under the name
#                     FLOXHUB_TOKEN_SECRET_NAME (default FLOXHUB_TOKEN),
#                     from Infisical via the INFISICAL_TOKEN machine
#                     identity (INFISICAL_PROJECT_ID strongly recommended:
#                     a fresh workspace has no .infisical.json context).
#   FLOXHUB_ACTIVATE_DIR  optional override pointing the activation stage
#                     at any directory holding a committed .flox env (the
#                     default is the host repo root, the gtm-sdk shape);
#                     a set-but-wrong override FAILs loudly.
#   TRUNK_USER_YAML   the contents of ~/.cache/trunk/user.yaml from a
#                     trunk login on an authenticated machine; same
#                     .env.local / Infisical (TRUNK_USER_YAML_SECRET_NAME,
#                     default TRUNK_USER_YAML) lookup order as the token.
#                     It carries a session access token with no refresh —
#                     budget for periodic rotation (re-login, re-store).
#   INFISICAL_ENV     optional Infisical environment for both lookups
#                     (default dev).
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

# --- flox workstream (opt-in, issue #40): bootstrap + token + env activation --
# Workstream A of issue #40 (the gtm-sdk#506 completion, wired here after
# gtm-sdk#944 retired that repo's own setup script and made this file the
# single provisioning home). All three stages run only when
# STARTUP_FLOX_ENV=1 asked for them; flag-off runs record one SKIP row per
# stage and the paste surface is exactly what it was (the pytools gate
# shape, issue #44). Provenance: scripts/sandbox-test.sh Stage 1 is the
# bootstrap reference (the harness form of the recipe gtm-sdk's retired
# script carried), and scripts/floxhub-provision.sh is the token +
# activation reference (Stage 7 + the dagger provision check) — this
# inline copy is the paste-ready form, self-contained because pasted
# workspaces have no checkout of this repo.
#
# Failure contract: fatal under BOTH postures (see the header's
# failure-semantics section) — a workspace that asked for its flox env
# must never be left looking ready without it. The deliberate SKIP shapes
# (non-Linux host without flox, flox missing after a failed bootstrap,
# no token, no host-repo env) record SKIP rows and return 0; every SKIP
# names the row that explains it, so a SKIP never hides a provisioning
# failure.
#
# Security posture, load-bearing: the token is exported as
# FLOX_FLOXHUB_TOKEN for this process only — never echoed, logged, or
# written to a file, no flox auth login, no keyring write — so the
# sandbox stays unauthenticated on disk and remains usable as a fresh
# Stage 4 (H4) tester (the same property scripts/floxhub-provision.sh
# documents). That is also why this repo's own settings.toml deliberately
# does NOT set the flag: sandbox-test.sh needs unauthenticated sandboxes.

# privileged <cmd...>: run a command as root when the script already runs
# as root, else through passwordless sudo (the Conductor sandbox class
# ships it; the caller checks it exists first). Returns the command's own
# status.
privileged() {
  if [[ "$(id -u)" == 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

# lookup_infisical_secret <name>: print one Infisical secret's value, or
# nothing. Requires the machine identity (INFISICAL_TOKEN) and the CLI on
# PATH; passes --projectId when INFISICAL_PROJECT_ID is set because a
# fresh workspace has no .infisical.json context and the CLI does not
# auto-detect a project. Failures are silent: callers treat empty as "not
# available" and fall through to the next lookup step or their FAIL row
# (gtm-sdk's reviewed shape). The value only ever travels this function's
# stdout — never argv, never a log line.
lookup_infisical_secret() {
  local secret_name="$1"
  [[ -n "${INFISICAL_TOKEN:-}" ]] || return 0
  command -v infisical >/dev/null 2>&1 || return 0
  local args=(--env="${INFISICAL_ENV:-dev}" --plain --silent)
  if [[ -n "${INFISICAL_PROJECT_ID:-}" ]]; then
    args+=(--projectId "${INFISICAL_PROJECT_ID}")
  fi
  infisical secrets get "${secret_name}" "${args[@]}" 2>/dev/null || true
}

# ensure_infisical_cli: best-effort standalone install of the infisical CLI
# for the flag-on secret lookups. Only runs when the machine identity is
# present but the CLI is absent, and only on dnf hosts with root or
# passwordless sudo (the Conductor sandbox class — the one place the
# chicken-and-egg exists: FloxHub auth must precede the activation that
# would otherwise provide infisical inside the env). Best-effort by
# design: on failure the environment/.env.local path stays authoritative
# and the calling stage FAILs with instructions instead of silently
# skipping. The installer is Infisical's own setup.rpm.sh channel — the
# same one gtm-sdk's retired setup script used (gtm-sdk#944); unpinned
# like the flox stable-channel rpm (a rolling channel; a broken channel
# surfaces as the lookup failing closed, never as a wrong secret used).
ensure_infisical_cli() {
  command -v infisical >/dev/null 2>&1 && return 0
  [[ -n "${INFISICAL_TOKEN:-}" ]] || return 0
  command -v dnf >/dev/null 2>&1 || return 0
  local can_install=0
  if [[ "$(id -u)" == 0 ]]; then
    can_install=1
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    can_install=1
  fi
  [[ ${can_install} == 1 ]] || return 0
  local install_ok=0
  if [[ "$(id -u)" == 0 ]]; then
    if curl -1sLf 'https://artifacts-cli.infisical.com/setup.rpm.sh' | bash >/dev/null 2>&1 &&
      dnf install -y infisical >/dev/null 2>&1; then
      install_ok=1
    fi
  else
    if curl -1sLf 'https://artifacts-cli.infisical.com/setup.rpm.sh' | sudo -E bash >/dev/null 2>&1 &&
      sudo dnf install -y infisical >/dev/null 2>&1; then
      install_ok=1
    fi
  fi
  if [[ ${install_ok} == 1 ]]; then
    log "installed the infisical CLI for the flag-on secret lookups"
  else
    log "warning: standalone infisical CLI install failed; secret lookups stay limited to the environment and .env.local"
  fi
}

flox_bootstrap_stage() {
  if [[ "${STARTUP_FLOX_ENV:-0}" != "1" ]]; then
    record SKIP flox-bootstrap "not requested — set STARTUP_FLOX_ENV=1 for the flox workstream (bootstrap, FloxHub token, host-repo env activation)"
    return 0
  fi
  # Off-Linux hosts: there is no unattended flox install (Homebrew or an
  # interactive .pkg), so reuse when present and SKIP with instructions
  # otherwise (the python311 stage's not-the-target-class shape — not a
  # FAIL, this script simply cannot install flox here).
  if [[ "$(uname -s)" != "Linux" ]]; then
    if command -v flox >/dev/null 2>&1; then
      record PASS flox-bootstrap "reused $(command -v flox) on $(uname -s) ($(flox --version 2>&1 | head -1 || true)) — no bootstrap needed off Linux"
      return 0
    fi
    record SKIP flox-bootstrap "not Linux and no flox on PATH — the bootstrap installs via rpm/deb on Linux only; install flox by hand and re-run"
    return 0
  fi
  local can_priv=0
  if [[ "$(id -u)" == 0 ]]; then
    can_priv=1
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    can_priv=1
  fi
  # /dev/fd: Vercel-class sandboxes ship without it and flox's activate
  # helpers need it (the gtm-sdk#279 trap). Best-effort creation; a host
  # that cannot create it fails loudly at the activation stage instead.
  if [[ ! -e /dev/fd ]]; then
    if [[ ${can_priv} == 1 ]]; then
      privileged ln -sfn /proc/self/fd /dev/fd 2>/dev/null || true
      [[ -e /dev/fd ]] && log "created /dev/fd -> /proc/self/fd (was missing)"
    fi
    if [[ ! -e /dev/fd ]]; then
      record WARN flox-bootstrap "/dev/fd is missing and could not be created (no root/passwordless sudo) — activation may fail, see gtm-sdk#279"
      return 0
    fi
  fi
  # Install flox when absent: the stable-channel rpm via dnf (the
  # Conductor/Vercel AL2023 class — gtm-sdk's exact path), deb via
  # apt-get as the generic Linux fallback (sandbox-test.sh Stage 1's
  # shape). xz is an undeclared runtime dep of the rpm's scriptlets on
  # minimal AL2023 images.
  local installed=0
  local install_note=""
  if command -v flox >/dev/null 2>&1; then
    installed=1
    install_note="reused $(command -v flox)"
  elif [[ ${can_priv} != 1 ]]; then
    record FAIL flox-bootstrap "Linux host without flox and without root/passwordless sudo — cannot install; provision flox by hand and re-run"
    return 1
  elif command -v dnf >/dev/null 2>&1; then
    local pkg="${WORK}/flox.rpm"
    privileged dnf install -y xz >/dev/null 2>&1 || true
    if curl -fsSLo "${pkg}" "https://downloads.flox.dev/by-env/stable/rpm/flox.$(uname -m)-linux.rpm" &&
      privileged rpm --import https://downloads.flox.dev/by-env/stable/rpm/flox-archive-keyring.asc &&
      privileged rpm -ivh "${pkg}"; then
      installed=1
      install_note="installed via the flox stable-channel rpm (dnf)"
    fi
    rm -f "${pkg}"
  elif command -v apt-get >/dev/null 2>&1; then
    local pkg="${WORK}/flox.deb"
    if curl -fsSLo "${pkg}" "https://downloads.flox.dev/by-env/stable/deb/flox.$(uname -m)-linux.deb" &&
      privileged apt-get install -y "${pkg}"; then
      installed=1
      install_note="installed via the flox stable-channel deb (apt-get)"
    fi
    rm -f "${pkg}"
  else
    record FAIL flox-bootstrap "Linux host without flox and with neither dnf nor apt-get — cannot install"
    return 1
  fi
  if [[ ${installed} != 1 ]]; then
    record FAIL flox-bootstrap "flox install failed (download or install) — see messages above"
    return 1
  fi
  hash -r 2>/dev/null || true
  local version_out
  version_out="$(flox --version 2>&1 | head -1 || true)"
  if [[ -z "${version_out}" ]] || ! flox --version >/dev/null 2>&1; then
    record FAIL flox-bootstrap "flox on PATH but flox --version failed (resolved: $(command -v flox || true))"
    return 1
  fi
  # nix-daemon: flox uses multi-user Nix, and these sandboxes have systemd
  # installed but offline (PID 1 is sandbox-init), so nix-daemon.socket
  # never activates. Start the daemon by hand when its socket is absent
  # (known locations first, then PATH), and leave a ~/.bashrc guard so
  # later shells self-heal after a daemon death (the gtm-sdk#944 recipe).
  # A missing socket is a WARN-grade note on the PASS row, not a FAIL:
  # single-user operation may still work and the activation stage below
  # is the decider — its FAIL would carry flox's own error.
  local daemon_bin=""
  local cand
  for cand in /usr/sbin/nix-daemon /usr/bin/nix-daemon; do
    [[ -x "${cand}" ]] && daemon_bin="${cand}" && break
  done
  [[ -z "${daemon_bin}" ]] && daemon_bin="$(command -v nix-daemon || true)"
  local daemon_note="nix-daemon socket already up"
  if [[ ! -S /nix/var/nix/daemon-socket/socket ]]; then
    if [[ -n "${daemon_bin}" && ${can_priv} == 1 ]]; then
      # The redirect is applied by this (unprivileged) shell on purpose:
      # the log stays user-owned, only the daemon runs as root (gtm-sdk's
      # reviewed shape). nohup for the root path so the daemon survives
      # this script's exit; sudo -b backgrounds it on the sudo path.
      if [[ "$(id -u)" == 0 ]]; then
        nohup "${daemon_bin}" --daemon >/tmp/nix-daemon.log 2>&1 &
      else
        # shellcheck disable=SC2024  # the log is meant to be user-owned; only the daemon needs root
        sudo -bn "${daemon_bin}" --daemon >/tmp/nix-daemon.log 2>&1
      fi
      local _i
      for _i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -S /nix/var/nix/daemon-socket/socket ]] && break
        sleep 1
      done
    fi
    if [[ -S /nix/var/nix/daemon-socket/socket ]]; then
      daemon_note="nix-daemon hand-started (${daemon_bin}); socket up"
    elif [[ -n "${daemon_bin}" ]]; then
      daemon_note="no nix-daemon socket (start failed or no privileges) — flox may only work single-user; later shells self-heal via the ~/.bashrc guard where sudo exists"
    else
      daemon_note="no nix-daemon socket and no nix-daemon binary found — flox may only work single-user"
    fi
  fi
  # The self-heal guard, idempotent by grep -F: later shells re-start the
  # daemon when its socket is gone. sudo -bn so the guard never prompts;
  # only written when a daemon binary exists and privileges allow the
  # hand-start (a guard that cannot work is noise).
  if [[ -n "${daemon_bin}" && ${can_priv} == 1 ]]; then
    local guard="[ -S /nix/var/nix/daemon-socket/socket ] || sudo -bn ${daemon_bin} --daemon >/dev/null 2>&1 || true"
    if ! grep -qF "${guard}" "${HOME}/.bashrc" 2>/dev/null; then
      printf '\n# conductor-startup-script-cloud.sh: keep the nix-daemon alive for flox (no systemd in these sandboxes)\n%s\n' "${guard}" >>"${HOME}/.bashrc"
      log "wrote the nix-daemon self-heal guard to ${HOME}/.bashrc"
    fi
  fi
  record PASS flox-bootstrap "flox ${version_out} at $(command -v flox) — ${install_note}; ${daemon_note}"
  return 0
}

floxhub_token_stage() {
  if [[ "${STARTUP_FLOX_ENV:-0}" != "1" ]]; then
    record SKIP floxhub-token "not requested — the STARTUP_FLOX_ENV=1 gate covers this stage too"
    return 0
  fi
  if ! command -v flox >/dev/null 2>&1; then
    record SKIP floxhub-token "flox not installed — see the flox-bootstrap row above"
    return 0
  fi
  # Lookup order (this workspace's secrets convention, no interactive
  # fallback): FLOXHUB_TOKEN already in the environment (Conductor env
  # vars or the host repo's .env.local, sourced flag-gated in the run
  # section — ENV_LOCAL_PROVIDED distinguishes the two), then the
  # Infisical secret, after a best-effort standalone CLI install.
  local source_label="the environment"
  case " ${ENV_LOCAL_PROVIDED:-} " in
  *" FLOXHUB_TOKEN "*) source_label="${ENV_LOCAL_ROOT:-the host repo}/.env.local" ;;
  esac
  if [[ -z "${FLOXHUB_TOKEN:-}" ]]; then
    source_label=""
    ensure_infisical_cli
    local secret_name="${FLOXHUB_TOKEN_SECRET_NAME:-FLOXHUB_TOKEN}"
    local token_from_infisical
    token_from_infisical="$(lookup_infisical_secret "${secret_name}")"
    if [[ -n "${token_from_infisical}" ]]; then
      FLOXHUB_TOKEN="${token_from_infisical}"
      source_label="Infisical (${secret_name})"
    fi
    unset -v token_from_infisical
  fi
  if [[ -z "${FLOXHUB_TOKEN:-}" ]]; then
    record FAIL floxhub-token "FLOXHUB_TOKEN not set and no Infisical lookup was possible — set it (from flox auth token on an authenticated machine) in the environment or the host repo's .env.local, or store it as the ${FLOXHUB_TOKEN_SECRET_NAME:-FLOXHUB_TOKEN} secret with INFISICAL_TOKEN (+ INFISICAL_PROJECT_ID), and re-run"
    return 1
  fi
  # Flox's documented CI pattern: every flox invocation that needs FloxHub
  # auth reads FLOX_FLOXHUB_TOKEN from the process environment. Process-
  # scoped only — the token is never persisted (see the section header).
  export FLOX_FLOXHUB_TOKEN="${FLOXHUB_TOKEN}"
  # Validate up front so a bad/expired token surfaces as an unambiguous
  # auth error here, not as a generic activation failure downstream.
  if ! flox auth status >/dev/null 2>&1; then
    record FAIL floxhub-token "FLOX_FLOXHUB_TOKEN was not accepted by FloxHub (invalid or expired) — rotate the token (flox auth token on an authenticated machine) and re-store it"
    return 1
  fi
  record PASS floxhub-token "FLOXHUB_TOKEN resolved from ${source_label:-the environment} and accepted (flox auth status); exported as FLOX_FLOXHUB_TOKEN for this run only — never persisted (no flox auth login, no keyring write)"
  return 0
}

flox_activate_stage() {
  if [[ "${STARTUP_FLOX_ENV:-0}" != "1" ]]; then
    record SKIP flox-activate "not requested — the STARTUP_FLOX_ENV=1 gate covers this stage too"
    return 0
  fi
  if ! command -v flox >/dev/null 2>&1; then
    record SKIP flox-activate "flox not installed — see the flox-bootstrap row above"
    return 0
  fi
  # Gated on a VALIDATED token, never activated unauthenticated:
  # private-catalog manifests (gtm-sdk's elvis/roborev pin) cannot resolve
  # without it, and a tokenless activation would only fail later with an
  # auth error this SKIP row explains up front.
  if [[ -z "${FLOX_FLOXHUB_TOKEN:-}" ]]; then
    record SKIP flox-activate "no validated FloxHub token — see the floxhub-token row above; this stage never activates unauthenticated"
    return 0
  fi
  # The env dir: FLOXHUB_ACTIVATE_DIR when set (any committed .flox env,
  # e.g. this repo's envs/floxhub-provision), else the host repo root when
  # it carries a committed env (the gtm-sdk shape). A set-but-wrong
  # override is an explicit misconfiguration and FAILs; a host repo simply
  # lacking an env is a SKIP — plenty of repos have none.
  local env_dir=""
  if [[ -n "${FLOXHUB_ACTIVATE_DIR:-}" ]]; then
    env_dir="${FLOXHUB_ACTIVATE_DIR}"
    if [[ ! -f "${env_dir}/.flox/env/manifest.toml" ]]; then
      record FAIL flox-activate "FLOXHUB_ACTIVATE_DIR=${env_dir} has no committed .flox env (no .flox/env/manifest.toml) — fix the override or unset it to use the host repo's root env"
      return 1
    fi
  else
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      record SKIP flox-activate "cwd is not a git worktree and FLOXHUB_ACTIVATE_DIR is unset — no host-repo .flox env to activate"
      return 0
    fi
    env_dir="$(git rev-parse --show-toplevel)"
    if [[ ! -f "${env_dir}/.flox/env/manifest.toml" ]]; then
      record SKIP flox-activate "host repo has no committed .flox env (${env_dir}/.flox/env/manifest.toml absent) — nothing to activate"
      return 0
    fi
  fi
  # --mode run everywhere: flox refuses a dev-mode activation while
  # another shell (an agent's) holds a run-mode activation of the same env.
  if ! flox activate --dir "${env_dir}" --mode run -- true; then
    record FAIL flox-activate "flox activate failed for ${env_dir} — see messages above (manifest/lock resolution, catalog auth, or the nix store/daemon)"
    return 1
  fi
  # Materialization proof, not exit-code trust: the run bin dir must have
  # landed (the glob covers flox's .flox/run/<system>.<env>-run/bin naming;
  # the -run-suffixed form first, the generic form as a naming fallback).
  local run_bin=""
  local d
  for d in "${env_dir}/.flox/run/"*"-run/bin"; do
    [[ -d "${d}" ]] && run_bin="${d}" && break
  done
  if [[ -z "${run_bin}" ]]; then
    for d in "${env_dir}/.flox/run/"*"/bin"; do
      [[ -d "${d}" ]] && run_bin="${d}" && break
    done
  fi
  if [[ -z "${run_bin}" ]]; then
    record FAIL flox-activate "activation exited 0 but no run bin dir materialized under ${env_dir}/.flox/run — see messages above"
    return 1
  fi
  # On PATH for the rest of this run (activation is process-scoped; later
  # shells re-run setup or activate by hand — the row records where the
  # tools live). Guarded so re-runs never stack duplicate PATH entries.
  case ":${PATH}:" in
  *":${run_bin}:"*) ;;
  *) export PATH="${run_bin}:${PATH}" ;;
  esac
  record PASS flox-activate "activated ${env_dir}'s committed flox env (run mode) — tools on PATH for this run under ${run_bin}"
  return 0
}

# --- trunk merge auth (opt-in, issue #40 Workstream B) -----------------------
# The headless trunk merge login (the gtm-sdk#702 completion). trunk check
# is fully unauthenticated and needs nothing; trunk merge has NO env-var
# auth (no TRUNK_TOKEN/TRUNK_API_TOKEN equivalent — verified empirically
# against the 1.25.0 binary — and trunk login is browser-only), so the one
# non-interactive path is the login file itself: ~/.cache/trunk/user.yaml,
# a portable credential an operator produces with trunk login on an
# authenticated machine and stores as the TRUNK_USER_YAML secret
# (findings/20261005-152730Z-trunk-merge-headless-auth.md is the research
# record; scripts/trunk-merge-auth.sh is the by-hand form of this recipe —
# the container test asserts the two forms install byte-identical files
# for the same input, the same drift guard validate-pins.sh plays for the
# duplicated pins). Safety properties, all load-bearing: never clobbers an
# existing login (an interactive login is strictly better than a
# provisioned copy), the yaml is a bearer credential written only to a
# 0600 file — never echoed, logged, or passed through argv — and it is
# shape-checked before install (a trunk_user key must be present) so a
# wrong-stored secret fails loudly here instead of as a mysteriously
# logged-out trunk merge later. The yaml carries a session access token
# with no refresh token: when it expires, re-login on the authenticated
# machine and re-store the secret (the rotation posture of FLOXHUB_TOKEN).
trunk_merge_auth_stage() {
  if [[ "${STARTUP_TRUNK_MERGE_AUTH:-0}" != "1" ]]; then
    record SKIP trunk-merge-auth "not requested — set STARTUP_TRUNK_MERGE_AUTH=1 to provision the headless trunk merge login (trunk check needs no auth by design)"
    return 0
  fi
  local login_path="${HOME}/.cache/trunk/user.yaml"
  if [[ -f "${login_path}" ]]; then
    record PASS trunk-merge-auth "trunk login already present at ${login_path} — left untouched (an interactive login is strictly better than a provisioned copy)"
    return 0
  fi
  # Same lookup order as the FloxHub token stage: TRUNK_USER_YAML in the
  # environment (or the host repo's .env.local, flagged by
  # ENV_LOCAL_PROVIDED), then the Infisical secret after a best-effort
  # standalone CLI install. No interactive fallback either way.
  local source_label="the environment"
  case " ${ENV_LOCAL_PROVIDED:-} " in
  *" TRUNK_USER_YAML "*) source_label="${ENV_LOCAL_ROOT:-the host repo}/.env.local" ;;
  esac
  local yaml="${TRUNK_USER_YAML:-}"
  if [[ -z "${yaml}" ]]; then
    source_label=""
    ensure_infisical_cli
    local secret_name="${TRUNK_USER_YAML_SECRET_NAME:-TRUNK_USER_YAML}"
    local yaml_from_infisical
    yaml_from_infisical="$(lookup_infisical_secret "${secret_name}")"
    if [[ -n "${yaml_from_infisical}" ]]; then
      yaml="${yaml_from_infisical}"
      source_label="Infisical (${secret_name})"
    fi
    unset -v yaml_from_infisical
  fi
  if [[ -z "${yaml}" ]]; then
    record FAIL trunk-merge-auth "TRUNK_USER_YAML not set and no Infisical lookup was possible — on an authenticated machine run trunk login, then store the contents of ~/.cache/trunk/user.yaml as the ${TRUNK_USER_YAML_SECRET_NAME:-TRUNK_USER_YAML} secret (or set the env var / .env.local entry) and re-run"
    return 1
  fi
  # Write through a 0600 temp file, shape-check the FILE (not the variable
  # — the value never travels through argv), then atomically install.
  local tmp
  tmp="$(mktemp)"
  chmod 600 "${tmp}"
  printf '%s\n' "${yaml}" >"${tmp}"
  if ! grep -q "trunk_user" "${tmp}"; then
    rm -f "${tmp}"
    record FAIL trunk-merge-auth "the resolved TRUNK_USER_YAML did not look like a trunk login file (no trunk_user key) — check the stored secret's value"
    return 1
  fi
  mkdir -p "${HOME}/.cache/trunk"
  chmod 700 "${HOME}/.cache/trunk" 2>/dev/null || true
  mv -f "${tmp}" "${login_path}"
  unset -v yaml
  record PASS trunk-merge-auth "provisioned headless trunk login at ${login_path} (0600) from ${source_label:-the environment} — trunk merge works without a browser; trunk check stays unauthenticated by design"
  return 0
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
ROBOREV_AGENT_DEFAULT="claude-code"

# ensure_daemon <stage>: status → PASS "daemon running"; start → PASS
# "daemon revived"; neither → FAIL under <stage> (deferred setup failure).
# One call site today (roborev-daemon, after the hook posture and the
# repo config) — kept as a helper so a future second caller cannot
# copy-paste the failure handling into divergent variants (roborev
# review finding).
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
    record WARN roborev-config "ROBOREV_AGENT is malformed (expected a lowercase agent slug like claude-code) — using ${ROBOREV_AGENT_DEFAULT}; check the environment variable"
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
    record WARN roborev-config "cwd is not a git worktree — skipping roborev setup; run it manually in the repo"
    return 0
  fi
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  cd "${repo_root}"
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
    record PASS roborev-config ".roborev.toml already present"
  else
    local toml_tmp
    # mktemp IN the repo root so the final mv is a same-filesystem rename —
    # a $TMPDIR temp would make mv a cross-device copy+unlink, not atomic
    # (the same reasoning as the rwx token stage's same-dir temp).
    toml_tmp="$(mktemp "${repo_root}/.roborev.toml.tmp.XXXXXX")"
    if printf '# Written by conductor-startup-script-cloud.sh — reviews here are\n# on demand and blocking (roborev review --wait); no post-commit\n# auto-review hook is installed (see that script for the reasoning).\nagent = "%s"\n' "${agent}" >"${toml_tmp}" &&
      mv -f "${toml_tmp}" "${repo_root}/.roborev.toml"; then
      record PASS roborev-config ".roborev.toml written (agent: ${agent}) — reviews on demand, always with --wait"
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
  # Smoke-check that the review agent actually responds — this is what makes
  # reviews work end to end. Non-fatal: a wrong agent choice or a transient
  # failure shouldn't fail setup when roborev itself installed and the repo
  # config was written.
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
# target class, the pytools stage (when STARTUP_PY_DEV_TOOLS=1 requested
# it), and the issue #40 opt-in stages (when STARTUP_FLOX_ENV=1 or
# STARTUP_TRUNK_MERGE_AUTH=1 requested them — the same requested-surface
# contract) are hard requirements under EITHER posture — their SKIP
# paths return 0 and never reach the FAILED assignment; the gates' SKIP
# rows likewise return 0.
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
if pytools_stage; then :; else FAILED=1; record FAIL pytools "provisioning failed — see the rows above"; fi

# The flag-on secret stages (flox workstream, trunk merge auth) also read
# the host repo's .env.local — the credential channel gtm-sdk's AGENTS.md
# documents for Conductor workspaces (INFISICAL_TOKEN/INFISICAL_PROJECT_ID
# plus operator-pre-placed secrets). Sourced once, best-effort, only when
# a flag asked for those stages; set -a exports what it defines, and the
# exports naturally persist for the rest of this run (an .env.local
# RWX_ACCESS_TOKEN reaches the rwx-auth stage below, for instance).
# ENV_LOCAL_PROVIDED records which of the stage secrets the file provided
# (names only — never values) so the stages can name their source in the
# summary rows.
if [[ "${STARTUP_FLOX_ENV:-0}" == "1" || "${STARTUP_TRUNK_MERGE_AUTH:-0}" == "1" ]]; then
  ENV_LOCAL_ROOT=""
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    ENV_LOCAL_ROOT="$(git rev-parse --show-toplevel)"
  fi
  if [[ -n "${ENV_LOCAL_ROOT}" && -f "${ENV_LOCAL_ROOT}/.env.local" ]]; then
    ENV_LOCAL_FLOXHUB_EMPTY=0
    ENV_LOCAL_TRUNK_EMPTY=0
    [[ -z "${FLOXHUB_TOKEN:-}" ]] && ENV_LOCAL_FLOXHUB_EMPTY=1
    [[ -z "${TRUNK_USER_YAML:-}" ]] && ENV_LOCAL_TRUNK_EMPTY=1
    set -a
    # shellcheck disable=SC1090,SC1091  # runtime-resolved workspace credential file, absent by design in this repo
    . "${ENV_LOCAL_ROOT}/.env.local" 2>/dev/null || true
    set +a
    ENV_LOCAL_PROVIDED=""
    if [[ ${ENV_LOCAL_FLOXHUB_EMPTY} == 1 && -n "${FLOXHUB_TOKEN:-}" ]]; then
      ENV_LOCAL_PROVIDED=" FLOXHUB_TOKEN"
    fi
    if [[ ${ENV_LOCAL_TRUNK_EMPTY} == 1 && -n "${TRUNK_USER_YAML:-}" ]]; then
      ENV_LOCAL_PROVIDED="${ENV_LOCAL_PROVIDED} TRUNK_USER_YAML"
    fi
    unset -v ENV_LOCAL_FLOXHUB_EMPTY ENV_LOCAL_TRUNK_EMPTY
    log "sourced ${ENV_LOCAL_ROOT}/.env.local (the host repo's credential channel; provided:${ENV_LOCAL_PROVIDED:- nothing})"
  fi
fi

# The issue #40 opt-in stages: fatal under BOTH postures when their flag
# requested them (the pytools contract — no aggregate outer row; each
# stage records its own complete specific rows internally, the rwx-auth
# shape). Their SKIP paths return 0 and never reach FAILED.
if flox_bootstrap_stage; then :; else FAILED=1; fi
if floxhub_token_stage; then :; else FAILED=1; fi
if flox_activate_stage; then :; else FAILED=1; fi
if trunk_merge_auth_stage; then :; else FAILED=1; fi

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
# STARTUP_BEST_EFFORT=1 only a target-class Python 3.11 failure, a
# pytools-stage failure (the requested-tools requirement, issue #44), or
# a failure in the issue #40 opt-in stages when their flags requested
# them (the same contract) reaches this exit; tool FAIL rows were recorded
# and the run exits 0 (the gtm-sdk#702 idiom this repo's settings.toml
# contracts for). The error goes to the original stderr (fd 4) as well as
# the log.
if [[ "${FAILED}" != 0 ]]; then
  log "error: setup finished with FAIL rows — see the summary and $SETUP_LOG"
  echo "error: setup finished with FAIL rows — see the summary and $SETUP_LOG" >&4 || true
  exit 1
fi
