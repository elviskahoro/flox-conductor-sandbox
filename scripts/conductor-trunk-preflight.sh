#!/usr/bin/env bash
# Provision the Trunk Launcher before the full Conductor setup.
#
# Trunk's launcher is deliberately installed outside a process-scoped Flox
# activation so subsequent agent commands can invoke `trunk check`. The
# operation is safe to repeat: an existing executable is reused and a new
# launcher is installed through an atomic rename.
set -euo pipefail

log() { printf '[trunk preflight] %s\n' "$*"; }

TRUNK_BIN="$(command -v trunk || true)"
if [[ -n "${TRUNK_BIN}" && -x "${TRUNK_BIN}" ]]; then
  log "reusing existing Trunk launcher: ${TRUNK_BIN}"
else
  command -v curl >/dev/null 2>&1 || {
    log "error: curl is required to install the Trunk launcher"
    exit 1
  }
  command -v mktemp >/dev/null 2>&1 || {
    log "error: mktemp is required to install the Trunk launcher"
    exit 1
  }

  INSTALL_DIR="/usr/local/bin"
  INSTALL_PATH="${INSTALL_DIR}/trunk"
  if [[ ! -d "${INSTALL_DIR}" ]]; then
    if ! mkdir -p "${INSTALL_DIR}" 2>/dev/null; then
      command -v sudo >/dev/null 2>&1 || {
        log "error: ${INSTALL_DIR} is unavailable and sudo is not installed"
        exit 1
      }
      sudo -n mkdir -p "${INSTALL_DIR}" || {
        log "error: cannot create ${INSTALL_DIR}; passwordless sudo is required"
        exit 1
      }
    fi
  fi

  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/trunk-preflight.XXXXXX")"
  cleanup() { rm -rf "${TMP_DIR}"; }
  trap cleanup EXIT HUP INT TERM
  TMP_BIN="${TMP_DIR}/trunk"

  log "downloading the official Trunk launcher"
  curl -fsSL https://trunk.io/releases/trunk -o "${TMP_BIN}"
  chmod 755 "${TMP_BIN}"

  if [[ -w "${INSTALL_DIR}" ]]; then
    mv -f "${TMP_BIN}" "${INSTALL_PATH}"
  else
    command -v sudo >/dev/null 2>&1 || {
      log "error: ${INSTALL_DIR} is not writable and sudo is not installed"
      exit 1
    }
    sudo -n mv -f "${TMP_BIN}" "${INSTALL_PATH}" || {
      log "error: cannot install ${INSTALL_PATH}; passwordless sudo is required"
      exit 1
    }
  fi
  TRUNK_BIN="${INSTALL_PATH}"
  hash -r 2>/dev/null || true
  log "installed Trunk launcher at ${TRUNK_BIN}"
fi

[[ -x "${TRUNK_BIN}" ]] || {
  log "error: Trunk launcher is not executable: ${TRUNK_BIN}"
  exit 1
}

TRUNK_PATH="$(command -v trunk || true)"
[[ -n "${TRUNK_PATH}" ]] || {
  log "error: trunk is not on PATH after installation"
  exit 1
}

TRUNK_VERSION="$(trunk --version 2>&1)" || {
  log "error: installed Trunk launcher failed its version check"
  exit 1
}
log "ready: ${TRUNK_PATH} (${TRUNK_VERSION%%$'\n'*})"
