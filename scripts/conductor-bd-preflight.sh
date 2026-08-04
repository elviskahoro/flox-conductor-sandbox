#!/usr/bin/env bash
# Provision the repository-pinned bd CLI before the full Conductor harness.
# Safe to run repeatedly: an existing result-bd artifact is reused and the
# stable launcher is replaced atomically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/envs/repackage"
BD_RESULT="${BUILD_DIR}/result-bd/bin/bd"

log() { printf '[bd preflight] %s\n' "$*"; }

bootstrap_flox() {
  command -v flox >/dev/null 2>&1 && return 0
  if [[ "$(uname -s)" != Linux ]]; then
    log "error: flox is not installed; install Flox before provisioning bd on $(uname -s)"
    return 1
  fi
  if ! command -v curl >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
    log "error: cannot bootstrap Flox (curl, sudo, and passwordless sudo are required)"
    return 1
  fi
  local tmp_pkg
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y xz >/dev/null 2>&1
    tmp_pkg="$(mktemp --suffix=.rpm)"
    curl -fsSLo "${tmp_pkg}" "https://downloads.flox.dev/by-env/stable/rpm/flox.$(uname -m)-linux.rpm"
    sudo rpm --import https://downloads.flox.dev/by-env/stable/rpm/flox-archive-keyring.asc
    sudo rpm -ivh "${tmp_pkg}"
  elif command -v apt-get >/dev/null 2>&1; then
    tmp_pkg="$(mktemp --suffix=.deb)"
    curl -fsSLo "${tmp_pkg}" "https://downloads.flox.dev/by-env/stable/deb/flox.$(uname -m)-linux.deb"
    sudo apt-get install -y "${tmp_pkg}"
  else
    log "error: no supported package manager found to install Flox"
    return 1
  fi
  rm -f "${tmp_pkg}"
}

ensure_proc_fd() {
  [[ "$(uname -s)" == Linux ]] || return 0
  [[ -e /dev/fd ]] && return 0
  if ! sudo -n ln -sfn /proc/self/fd /dev/fd 2>/dev/null; then
    log "error: /dev/fd is missing and could not be created (passwordless sudo is required)"
    return 1
  fi
  log "created /dev/fd -> /proc/self/fd"
}

start_nix_daemon_if_needed() {
  [[ -S /nix/var/nix/daemon-socket/socket ]] && return 0
  local daemon=""
  for candidate in /usr/sbin/nix-daemon /usr/bin/nix-daemon; do
    if [[ -x "${candidate}" ]]; then daemon="${candidate}"; break; fi
  done
  [[ -n "${daemon}" ]] || daemon="$(command -v nix-daemon || true)"
  if [[ -n "${daemon}" ]]; then
    sudo -b "${daemon}" --daemon >/tmp/nix-daemon.log 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [[ -S /nix/var/nix/daemon-socket/socket ]] && return 0
      sleep 1
    done
  fi
}

if [[ -x "${BD_RESULT}" ]]; then
  # Keep the workspace result path rather than resolving it with GNU
  # readlink, which is unavailable on macOS. The kernel follows the result
  # symlink when /usr/local/bin/bd is invoked.
  BD_BIN="${BD_RESULT}"
  log "reusing existing pinned bd artifact: ${BD_BIN}"
else
  bootstrap_flox
  ensure_proc_fd
  start_nix_daemon_if_needed
  log "pinned bd artifact missing; building ${BUILD_DIR}"
  flox build --dir "${BUILD_DIR}" bd
  [[ -x "${BD_RESULT}" ]] || {
    log "error: flox build completed without producing ${BD_RESULT}"
    exit 1
  }
  BD_BIN="${BD_RESULT}"
fi

[[ -x "${BD_BIN}" ]] || {
  log "error: resolved bd binary is not executable: ${BD_BIN}"
  exit 1
}

sudo install -d -m 755 /usr/local/bin
tmp_link="$(mktemp /tmp/bd-link.XXXXXX)"
rm -f "${tmp_link}"
ln -s "${BD_BIN}" "${tmp_link}"
# Rename over the existing file/symlink; this is atomic and works with both
# GNU coreutils and macOS's BSD mv (which has no -T option).
sudo mv -f "${tmp_link}" /usr/local/bin/bd
hash -r 2>/dev/null || true

BD_PATH="$(command -v bd || true)"
[[ "${BD_PATH}" == /usr/local/bin/bd ]] || {
  log "error: bd did not resolve through /usr/local/bin after installation (resolved: ${BD_PATH:-<missing>})"
  exit 1
}
BD_VERSION="$(bd version 2>&1)" || {
  log "error: installed bd failed its version check"
  exit 1
}
log "ready: ${BD_PATH} -> ${BD_BIN} (${BD_VERSION%%$'\n'*})"
