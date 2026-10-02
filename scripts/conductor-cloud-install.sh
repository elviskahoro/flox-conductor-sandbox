#!/usr/bin/env bash
# Python 3.11 + priority-CLI provisioning for a Conductor cloud workspace.
#
# Target class (per https://vercel.com/docs/sandbox/concepts/runtimes — the
# legacy runtimes Conductor cloud workspaces provision on): Amazon Linux
# 2023 base, `dnf` for system packages, passwordless `sudo`, code running as
# the `vercel-sandbox` user, and the sandbox proxy CA already trusted
# system-wide (SSL_CERT_FILE and friends are preset), so plain `curl`
# downloads just work. Vercel deprecates runtimes in favor of managed images,
# but Conductor cloud is still on the AL2023 class, so `dnf` stays the
# system-package path.
#
# Installs, in the user-set priority order (context: gtm-sdk#702 for trunk,
# gtm-sdk#506 for roborev):
#   roborev      reuse if present → defer to the FloxHub path when
#                FLOXHUB_TOKEN is set (the production path —
#                .conductor/settings.toml provisions it right after this
#                script) → pinned kenn-io release tarball, fail-closed
#                sha256 (same pins as envs/repackage's [build.roborev]).
#   trunk        reuse if present → official launcher binary, the same
#                download scripts/conductor-trunk-preflight.sh installs
#                (direct binary, no piped remote shell — gtm-sdk#702's
#                `curl ... | bash -s -- -y` shape also works but executes
#                a fetched script; prefer the artifact).
#   rwx          reuse if present → pinned static release binary,
#                checksum-verified; idiom and pins lifted from the rwx
#                block gtm-sdk#699 added to conductor-workspace-setup.sh.
#   python3.11   AL2023's default `python3` is 3.9 while pyproject.toml
#                requires >=3.11. FATAL when this is the target class and
#                3.11 cannot be provided (a stated requirement, not a
#                nice-to-have).
#
# Design rules inherited from this repo's / gtm-sdk's provisioning scripts:
#   - NO process substitution (`<(...)`) anywhere: Conductor cloud sandboxes
#     lack /dev/fd, and under `set -e` an unopenable process-substitution
#     fd kills the script silently before it does anything (gtm-sdk#279).
#   - Idempotent: every stage reuses an already-present tool; safe to re-run.
#   - Non-fatal per CLI tool (gtm-sdk#702's stated fallback-installer
#     idiom): a failed tool is recorded in the summary and setup continues.
#     Only a Python 3.11 failure on the target class aborts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '[cloud-install] %s\n' "$*"; }

# ~/.local/bin is the no-sudo fallback location for the tool stages.
export PATH="${HOME}/.local/bin:${PATH}"

LOCAL_BIN="/usr/local/bin"
RESULTS=""
PYTHON_OK=1

record() { # <status> <name> <detail> — one summary row + one log line
  RESULTS="${RESULTS}$(printf ' %-10s | %-4s | %s' "$2" "$1" "$3")"$'\n'
  log "[$1] $2 — $3"
}

# TARGET_CLASS: this is the real AL2023/Vercel/Conductor-cloud environment
# (Linux + dnf + root or passwordless sudo). Python 3.11 failure is fatal
# only here; other hosts (a local mac, a stripped container) degrade to a
# recorded warning instead of breaking whatever shell invoked this.
TARGET_CLASS=0
if [[ "$(uname -s)" == "Linux" ]] && command -v dnf >/dev/null 2>&1 && {
  [[ "$(id -u)" == 0 ]] ||
    { command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; }
}; then
  TARGET_CLASS=1
fi

# install_bin <src> <name>: place a file as an executable under
# /usr/local/bin (the convention this repo's setup already uses for
# bd/roborev/infisical/trunk) when root or passwordless sudo allows it,
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
  printf '%s\n' "${dir}/${name}"
}

# link_bin <target> <name>: symlink <name> -> <target> in the target's own
# directory (e.g. git-roborev -> roborev, so `git roborev ...` works — the
# same convention settings.toml's FloxHub roborev block uses). Derives the
# directory from <target> itself: callers run install_bin inside command
# substitution, so any directory state set there never propagates out.
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
# `shasum -a 256` (macOS), which accept the same "<hash>  <file>" stdin
# format — the gtm-sdk#699 idiom.
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

# --- roborev (priority 1) ----------------------------------------------------
ROBOREV_PIN="0.63.0"
# Keep in sync with envs/repackage/.flox/env/manifest.toml's [build.roborev]
# and envs/floxhub-provision's roborev.version (^0.63.0). Bump runbook: new
# pin + sha256s from the release's checksums file, then republish the
# FloxHub package — don't hand-edit any lock.

roborev_stage() {
  if command -v roborev >/dev/null 2>&1; then
    record PASS roborev "reused $(command -v roborev) ($(roborev version 2>&1 | head -1 || true))"
    return 0
  fi
  # FloxHub-published roborev is the production path (gtm-sdk#506): when
  # this setup runs with a FloxHub token, settings.toml's roborev block
  # provisions elvis/roborev right after this script — don't double-install
  # a second copy from the fallback path. The sibling-script check keeps
  # this defer scoped to this repo's setup flow; standalone/ported runs
  # always take the pinned-binary path below.
  if [[ -n "${FLOXHUB_TOKEN:-}" ]] && [[ -f "${SCRIPT_DIR}/floxhub-provision.sh" ]]; then
    record SKIP roborev "FLOXHUB_TOKEN set; deferring to FloxHub provisioning (the production path, gtm-sdk#506)"
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
  local tmp path
  tmp="$(mktemp -d)"
  if ! curl -fsSLo "${tmp}/${asset}" \
    "https://github.com/kenn-io/roborev/releases/download/v${ROBOREV_PIN}/${asset}"; then
    rm -rf "${tmp}"
    return 1
  fi
  if ! checksum_verify "${sha256}" "${tmp}/${asset}"; then
    rm -rf "${tmp}"
    return 1
  fi
  if ! tar -xzf "${tmp}/${asset}" -C "${tmp}" || [[ ! -x "${tmp}/roborev" ]]; then
    rm -rf "${tmp}"
    log "error: roborev tarball did not yield an executable ./roborev"
    return 1
  fi
  path="$(install_bin "${tmp}/roborev" roborev || true)"
  rm -rf "${tmp}"
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

# --- trunk (priority 2) ------------------------------------------------------
trunk_stage() {
  if command -v trunk >/dev/null 2>&1; then
    record PASS trunk "reused $(command -v trunk) ($(trunk --version 2>&1 | head -1 || true))"
    return 0
  fi
  # Same launcher download as scripts/conductor-trunk-preflight.sh (which
  # .conductor/settings.toml runs before this script, so this stage is
  # normally verify-only reuse there). Kept inline so the script stays a
  # self-contained recipe for porting (gtm-sdk#702).
  local tmp path
  tmp="$(mktemp)"
  if ! curl -fsSL https://trunk.io/releases/trunk -o "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  chmod 755 "${tmp}"
  path="$(install_bin "${tmp}" trunk || true)"
  rm -f "${tmp}"
  if [[ -z "${path}" ]]; then
    log "error: could not place the trunk launcher in a bin directory"
    return 1
  fi
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

# --- rwx (priority 3) --------------------------------------------------------
RWX_PIN="v3.25.0"
# Keep in sync with gtm-sdk's conductor-workspace-setup.sh rwx block (PR
# #699): RWX isn't packaged in Flox/nixpkgs, and their docs recommend
# pinning for scripted use (the 3.x series isn't guaranteed backwards
# compatible), so this installs the single static release binary.

rwx_stage() {
  if command -v rwx >/dev/null 2>&1; then
    record PASS rwx "reused $(command -v rwx) ($(rwx --version 2>&1 | head -1 || true))"
    return 0
  fi
  local os arch sha256 tmp path
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
  tmp="$(mktemp)"
  if ! curl -fsSLo "${tmp}" "https://github.com/rwx-cloud/rwx/releases/download/${RWX_PIN}/rwx-${os}-${arch}"; then
    rm -f "${tmp}"
    return 1
  fi
  if ! checksum_verify "${sha256}" "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  chmod 755 "${tmp}"
  path="$(install_bin "${tmp}" rwx || true)"
  rm -f "${tmp}"
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

# --- python3.11 --------------------------------------------------------------
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
  # callers (dnf's own machinery). /usr/local/bin precedes /usr/bin on PATH
  # in these sandboxes (the same convention every other tool in this repo's
  # setup relies on), so symlinks there shadow PATH lookups only.
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

log "host: $(uname -srm), user: $(id -un), target-class: ${TARGET_CLASS}"

if roborev_stage; then :; else record FAIL roborev "provisioning failed — see messages above"; fi
if trunk_stage; then :; else record FAIL trunk "provisioning failed — see messages above"; fi
if rwx_stage; then :; else record FAIL rwx "provisioning failed — see messages above"; fi
if ! python311_stage; then
  PYTHON_OK=0
  record FAIL python3.11 "provisioning failed — see messages above"
fi

log ""
log "---- conductor-cloud-install summary ----"
printf '%s' "${RESULTS}"
log "------------------------------------------"

if [[ ${PYTHON_OK} != 1 && ${TARGET_CLASS} == 1 ]]; then
  log "error: Python 3.11 is required on this sandbox class (pyproject.toml requires >=3.11) and could not be provided; aborting"
  exit 1
fi
if [[ ${PYTHON_OK} != 1 ]]; then
  log "warning: Python 3.11 was not provided on this non-target host; continuing"
fi
log "done"
