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

  # Content-pin the launcher (roborev review finding: it was previously
  # downloaded unpinned and executed). Trunk publishes no versioned launcher
  # URL — trunk.io/releases/trunk is latest-only — but the artifact is a
  # portable bash script that has been byte-stable since 2024-11-06 (S3
  # last-modified), so fail closed on any upstream change and bump this
  # deliberately. Keep in sync with conductor-cloud-install.sh's
  # TRUNK_LAUNCHER_SHA256; scripts/validate-pins.sh cross-checks the two.
  TRUNK_LAUNCHER_SHA256="89fbdd8c7b63649eeb1479415757b898903c041e73b49b78028dbd64eca3087a"
  LAUNCHER_CHECK_TOOL="sha256sum"
  if ! command -v sha256sum >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
    LAUNCHER_CHECK_TOOL="shasum -a 256"
  fi
  # shellcheck disable=SC2086  # intentional two-word command (shasum -a 256), not a path to quote
  if ! echo "${TRUNK_LAUNCHER_SHA256}  ${TMP_BIN}" | ${LAUNCHER_CHECK_TOOL} -c -; then
    log "error: Trunk launcher checksum mismatch (expected ${TRUNK_LAUNCHER_SHA256}); refusing to install"
    exit 1
  fi

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
