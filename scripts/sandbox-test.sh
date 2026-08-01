#!/usr/bin/env bash
# Hypothesis harness for gtm-sdk#445: can bd/roborev move from in-sandbox
# flake source builds to build-once/publish-to-FloxHub prebuilt packages?
#
# Design rules, inherited from gtm-sdk/scripts/conductor-workspace-setup.sh:
#   - NO process substitution (`<(...)`) anywhere: Conductor cloud sandboxes
#     lack /dev/fd until we create it, and with an unopenable fd bash dies
#     silently (gtm-sdk#279).
#   - Never abort on a stage failure: every stage records PASS/FAIL/SKIP with
#     evidence into findings/report-*.md. A failed stage IS a finding.
#
# Stages:
#   0  environment fingerprint (Nix sandbox/build-users state, /dev/fd, ...)
#   1  flox bootstrap (rpm via dnf like gtm-sdk, deb via apt as fallback)
#   2  H1: activate envs/prebuilt (catalog packages only) atomically
#   3  H3: flox build conductor-workspace-floxhub-01 + bd repackage, then bd flag surface
#   4  H4: fetch a package from FloxHub unauthenticated (needs Phase A3 publish)
#   5  H2: opt-in (FLAKE_REPRO=1) flake source-build failure repro
#   6  Phase D' prototype: opt-in (TEST_AUTH_PLUMBING=1) — authenticate via
#      scripts/floxhub-login.sh, then activate envs/floxhub-consume (a real
#      pkg-path manifest, not the ad hoc `flox install` Stage 4 uses) to
#      prove the FloxHub auth-token recipe works end to end. NEVER wired
#      into .conductor/settings.toml's default path, same as
#      floxhub-login.sh itself: authenticating a sandbox must stay opt-in so
#      Stage 4 can keep testing genuinely unauthenticated sandboxes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

export FLOX_DISABLE_METRICS=true
FLOXHUB_TEST_PKG="${FLOXHUB_TEST_PKG:-elvis/conductor-workspace-floxhub-01}"
FLAKE_REPRO="${FLAKE_REPRO:-0}"
FLAKE_REPRO_TIMEOUT="${FLAKE_REPRO_TIMEOUT:-1800}"
TEST_AUTH_PLUMBING="${TEST_AUTH_PLUMBING:-0}"

STAMP="$(date -u +%Y%m%d-%H%M%SZ)"
mkdir -p findings
REPORT="findings/report-${STAMP}.md"
FULL_LOG="findings/full-log-${STAMP}.txt"
BODY="$(mktemp)"
SUMMARY_ROWS=""

log() { printf '%s\n' "$*" | tee -a "${FULL_LOG}"; }

# run_logged <logfile> <cmd...>: run a command, mirror output to the full log,
# return its status. No pipefail surprises: capture status explicitly.
run_logged() {
  local out="$1"
  shift
  log "\$ $*"
  "$@" >"${out}" 2>&1
  local status=$?
  cat "${out}" >>"${FULL_LOG}"
  return "${status}"
}

# record <stage-id> <PASS|FAIL|SKIP> <one-line detail>
record() {
  SUMMARY_ROWS="${SUMMARY_ROWS}| $1 | **$2** | $3 |"$'\n'
  log "==> [$1] $2 — $3"
}

section() {
  printf '\n## %s\n\n' "$1" >>"${BODY}"
}

note() { printf '%s\n' "$*" >>"${BODY}"; }

# note_cmd <label> <cmd...>: run a command, embed its output in the report.
note_cmd() {
  local label="$1"
  shift
  local out
  out="$("$@" 2>&1)"
  local status=$?
  {
    printf '**%s** (`%s`, exit %d):\n\n```\n%s\n```\n\n' "${label}" "$*" "${status}" "${out}"
  } >>"${BODY}"
  printf '%s\n' "${out}" >>"${FULL_LOG}"
  return "${status}"
}

elapsed() { printf '%ds' "$(($(date +%s) - $1))"; }

# note_excerpt <logfile>: embed a readable failure excerpt in the report.
# flox prints its error message FIRST and then a long Rust backtrace, so
# `tail` alone captures only backtrace frames — keep the head plus any
# error-looking lines, and drop numbered backtrace frames.
note_excerpt() {
  note '```'
  {
    head -15 "$1"
    grep -iE 'error|warning|fail' "$1" | grep -vE '^\s*[0-9]+:' | head -10
  } | awk '!seen[$0]++' >>"${BODY}"
  note '```'
}

# ---------------------------------------------------------------------------
# Stage 0: environment fingerprint
# ---------------------------------------------------------------------------
section "Stage 0 — environment fingerprint"
note_cmd "kernel/arch" uname -srm
note_cmd "os-release" sh -c 'head -2 /etc/os-release 2>/dev/null || echo "no /etc/os-release"'
note_cmd "nix.conf" sh -c 'cat /etc/nix/nix.conf 2>/dev/null || echo "no /etc/nix/nix.conf"'
note_cmd "nixbld build users" sh -c 'getent group nixbld || echo "no nixbld group"'
note_cmd "/dev/fd" sh -c 'ls -ld /dev/fd 2>/dev/null || echo "MISSING (gtm-sdk#279 territory)"'
note_cmd "/homeless-shelter" sh -c 'ls -ld /homeless-shelter 2>/dev/null || echo "absent (good)"'
note_cmd "nix-daemon socket" sh -c 'ls -l /nix/var/nix/daemon-socket/socket 2>/dev/null || echo "absent"'
note_cmd "preexisting flox/nix" sh -c 'command -v flox nix || echo "neither on PATH"'
record "0 fingerprint" "PASS" "recorded (see report body)"

# ---------------------------------------------------------------------------
# Stage 1: flox bootstrap
# ---------------------------------------------------------------------------
section "Stage 1 — flox bootstrap"
STAGE1_START=$(date +%s)
BOOTSTRAP_OK=0
if [[ "$(uname -s)" != "Linux" ]]; then
  record "1 flox bootstrap" "SKIP" "non-Linux host; install flox manually"
else
  # Vercel sandboxes ship no /dev/fd; flox's activate helpers need it.
  if [[ ! -e /dev/fd ]]; then
    sudo -n ln -sfn /proc/self/fd /dev/fd 2>/dev/null &&
      note "Created /dev/fd -> /proc/self/fd (was missing)."
  fi

  if command -v flox >/dev/null 2>&1; then
    note "flox already present: $(command -v flox)"
    BOOTSTRAP_OK=1
  elif command -v dnf >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    # gtm-sdk's exact path (AL2023 / Vercel-class sandboxes).
    sudo dnf install -y xz >/dev/null 2>&1
    tmp_pkg="/tmp/flox.rpm"
    if run_logged "$(mktemp)" curl -fsSLo "${tmp_pkg}" \
      "https://downloads.flox.dev/by-env/stable/rpm/flox.$(uname -m)-linux.rpm"; then
      sudo rpm --import https://downloads.flox.dev/by-env/stable/rpm/flox-archive-keyring.asc 2>>"${FULL_LOG}"
      run_logged "$(mktemp)" sudo rpm -ivh "${tmp_pkg}" && BOOTSTRAP_OK=1
      rm -f "${tmp_pkg}"
    fi
  elif command -v apt-get >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    # Generic Debian/Ubuntu path so the harness also runs outside the
    # Vercel sandbox class (e.g. other CI/dev containers).
    tmp_pkg="/tmp/flox.deb"
    if run_logged "$(mktemp)" curl -fsSLo "${tmp_pkg}" \
      "https://downloads.flox.dev/by-env/stable/deb/flox.$(uname -m)-linux.deb"; then
      run_logged "$(mktemp)" sudo apt-get install -y "${tmp_pkg}" && BOOTSTRAP_OK=1
      rm -f "${tmp_pkg}"
    fi
  else
    note "No usable package manager + passwordless sudo combination found."
  fi

  if [[ ${BOOTSTRAP_OK} == 1 ]]; then
    note_cmd "flox version" flox --version
    # Flox uses multi-user Nix. Sandboxes with offline systemd never activate
    # nix-daemon.socket — start the daemon by hand when the socket is absent
    # (mirrors gtm-sdk). Probe known daemon locations.
    if [[ ! -S /nix/var/nix/daemon-socket/socket ]]; then
      NIX_DAEMON_BIN=""
      for cand in /usr/sbin/nix-daemon /usr/bin/nix-daemon; do
        [[ -x "${cand}" ]] && NIX_DAEMON_BIN="${cand}" && break
      done
      [[ -z ${NIX_DAEMON_BIN} ]] && NIX_DAEMON_BIN="$(command -v nix-daemon || true)"
      if [[ -n ${NIX_DAEMON_BIN} ]]; then
        sudo -b "${NIX_DAEMON_BIN}" --daemon >/tmp/nix-daemon.log 2>&1
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          [[ -S /nix/var/nix/daemon-socket/socket ]] && break
          sleep 1
        done
      fi
      if [[ -S /nix/var/nix/daemon-socket/socket ]]; then
        note "Started nix-daemon by hand (${NIX_DAEMON_BIN}); socket is up."
      else
        note "WARNING: no nix-daemon socket. flox may still work single-user; recorded, not fatal."
      fi
    else
      note "nix-daemon socket already present."
    fi
    note_cmd "effective nix.conf after install" sh -c 'cat /etc/nix/nix.conf 2>/dev/null || echo "no /etc/nix/nix.conf"'
    record "1 flox bootstrap" "PASS" "flox installed and responding ($(elapsed "${STAGE1_START}"))"
  else
    record "1 flox bootstrap" "FAIL" "could not install flox — all later stages blocked"
  fi
fi

# ---------------------------------------------------------------------------
# Stage 2 (H1): atomic activation of the prebuilt-only environment
# ---------------------------------------------------------------------------
section "Stage 2 — H1: prebuilt-only manifest materializes atomically"
if ! command -v flox >/dev/null 2>&1; then
  record "2 H1 prebuilt activate" "SKIP" "no flox"
else
  STAGE2_START=$(date +%s)
  ACT_LOG="$(mktemp)"
  if run_logged "${ACT_LOG}" flox activate --dir "${REPO_ROOT}/envs/prebuilt" --mode run -- true; then
    DUR="$(elapsed "${STAGE2_START}")"
    SYSTEM="$(uname -m | sed s/arm64/aarch64/)-$(uname -s | tr '[:upper:]' '[:lower:]')"
    FLOX_BIN="${REPO_ROOT}/envs/prebuilt/.flox/run/${SYSTEM}.prebuilt-run/bin"
    if [[ ! -d ${FLOX_BIN} ]]; then
      # Fall back to a glob in case flox's run-dir naming differs.
      for d in "${REPO_ROOT}/envs/prebuilt/.flox/run/"*"/bin"; do
        [[ -d "${d}" ]] && FLOX_BIN="${d}" && break
      done
    fi
    if [[ -d ${FLOX_BIN} ]]; then
      note "Activation succeeded in ${DUR} (includes in-sandbox lock/resolution: no manifest.lock is committed)."
      note "FLOX_BIN: \`${FLOX_BIN}\`"
      TOOL_FAILURES=0
      OLD_PATH="${PATH}"
      export PATH="${FLOX_BIN}:${PATH}"
      while read -r tool version_flag; do
        tool_path="$(command -v "${tool}" || true)"
        if [[ ${tool_path} != "${FLOX_BIN}"/* ]]; then
          note "- \`${tool}\`: FAIL — resolved to \`${tool_path:-<missing>}\`, not under FLOX_BIN"
          TOOL_FAILURES=$((TOOL_FAILURES + 1))
        elif ! out="$("${tool}" "${version_flag}" 2>&1)"; then
          note "- \`${tool}\`: FAIL — found under FLOX_BIN but \`${tool} ${version_flag}\` errored: ${out}"
          TOOL_FAILURES=$((TOOL_FAILURES + 1))
        else
          note "- \`${tool}\`: OK — $(printf '%s' "${out}" | head -1)"
        fi
      done <<'EOF'
uv --version
dolt version
infisical --version
gh --version
git --version
EOF
      export PATH="${OLD_PATH}"
      if [[ ${TOOL_FAILURES} == 0 ]]; then
        record "2 H1 prebuilt activate" "PASS" "all 5 tools resolve under .flox/run and execute (${DUR})"
      else
        record "2 H1 prebuilt activate" "FAIL" "activation OK but ${TOOL_FAILURES} tool(s) failed verification"
      fi
    else
      record "2 H1 prebuilt activate" "FAIL" "activation OK but no run bin dir found"
    fi
  else
    note_excerpt "${ACT_LOG}"
    record "2 H1 prebuilt activate" "FAIL" "flox activate failed — see report body"
  fi
fi

# ---------------------------------------------------------------------------
# Stage 3 (H3): manifest builds — hello smoke test, then the bd repackage
# ---------------------------------------------------------------------------
section "Stage 3 — H3: flox manifest builds (Option-A repackage shape)"
if ! command -v flox >/dev/null 2>&1; then
  record "3a hello build" "SKIP" "no flox"
  record "3b bd repackage build" "SKIP" "no flox"
  record "3c bd flag surface" "SKIP" "no flox"
else
  STAGE3_START=$(date +%s)
  BUILD_DIR="${REPO_ROOT}/envs/repackage"
  HELLO_LOG="$(mktemp)"
  if run_logged "${HELLO_LOG}" flox build --dir "${BUILD_DIR}" conductor-workspace-floxhub-01 &&
    "${BUILD_DIR}/result-conductor-workspace-floxhub-01/bin/conductor-workspace-floxhub-01" >/dev/null 2>&1; then
    record "3a hello build" "PASS" "trivial no-network build + run OK ($(elapsed "${STAGE3_START}"))"
  else
    note_excerpt "${HELLO_LOG}"
    record "3a hello build" "FAIL" "trivial build failed — flox build mechanics broken here; see body"
  fi

  BD_START=$(date +%s)
  BD_LOG="$(mktemp)"
  if run_logged "${BD_LOG}" flox build --dir "${BUILD_DIR}" bd; then
    BD_BIN="${BUILD_DIR}/result-bd/bin/bd"
    if out="$("${BD_BIN}" version 2>&1)"; then
      record "3b bd repackage build" "PASS" "built + \`bd version\` → $(printf '%s' "${out}" | head -1) ($(elapsed "${BD_START}"))"
      # Flag-surface check (#445 Phase C3): every flag the gtm-sdk setup
      # script passes to bd must still exist on v1.1.2.
      HELP_INIT="$("${BD_BIN}" init --help 2>&1)"
      HELP_ROOT="$("${BD_BIN}" --help 2>&1)"
      MISSING=""
      for flag in --non-interactive --skip-agents --skip-hooks --init-if-missing --remote; do
        printf '%s' "${HELP_INIT}" | grep -qe "${flag}" || MISSING="${MISSING} ${flag}(init)"
      done
      printf '%s' "${HELP_ROOT}" | grep -qe '-C' || MISSING="${MISSING} -C(global)"
      if [[ -z ${MISSING} ]]; then
        record "3c bd flag surface" "PASS" "all conductor-workspace-setup.sh flags present on v1.1.2"
      else
        record "3c bd flag surface" "FAIL" "missing:${MISSING} — v1.1.0→v1.1.2 drift (publish v1.1.0 like-for-like instead)"
      fi
    else
      record "3b bd repackage build" "FAIL" "built but binary does not run: ${out}"
      record "3c bd flag surface" "SKIP" "no runnable bd binary"
    fi
  else
    note_excerpt "${BD_LOG}"
    record "3b bd repackage build" "FAIL" "repackage build failed — see body"
    record "3c bd flag surface" "SKIP" "no bd build"
  fi
fi

# ---------------------------------------------------------------------------
# Stage 4 (H4): FloxHub catalog fetch, unauthenticated
# ---------------------------------------------------------------------------
section "Stage 4 — H4: FloxHub catalog fetch (the Phase A fork in the road)"
if ! command -v flox >/dev/null 2>&1; then
  record "4 FloxHub fetch" "SKIP" "no flox"
else
  note_cmd "flox auth status (expect logged-out on a fresh sandbox)" sh -c 'flox auth status 2>&1 || true'
  SHOW_LOG="$(mktemp)"
  if run_logged "${SHOW_LOG}" flox show "${FLOXHUB_TEST_PKG}"; then
    FETCH_DIR="$(mktemp -d)"
    FETCH_LOG="$(mktemp)"
    if (cd "${FETCH_DIR}" && flox init >/dev/null 2>&1 &&
      flox install "${FLOXHUB_TEST_PKG}") >"${FETCH_LOG}" 2>&1; then
      cat "${FETCH_LOG}" >>"${FULL_LOG}"
      record "4 FloxHub fetch" "PASS" "unauthenticated install of ${FLOXHUB_TEST_PKG} works — no token plumbing needed (#445 §6 is dead code)"
    else
      cat "${FETCH_LOG}" >>"${FULL_LOG}"
      note_excerpt "${FETCH_LOG}"
      record "4 FloxHub fetch" "FAIL" "package visible but install failed — likely auth; token plumbing (#445 §6) required"
    fi
  else
    note_excerpt "${SHOW_LOG}"
    record "4 FloxHub fetch" "SKIP" "'flox show ${FLOXHUB_TEST_PKG}' failed — publish a throwaway pkg from a Mac (#445 Phase A3: flox publish from envs/repackage covers conductor-workspace-floxhub-01), then re-run with FLOXHUB_TEST_PKG=<owner>/<pkg>. NOTE: not-found here is ambiguous between 'not published' and 'published but private/auth-gated' — check which."
  fi
fi

# ---------------------------------------------------------------------------
# Stage 5 (H2, opt-in): flake source-build failure repro
# ---------------------------------------------------------------------------
section "Stage 5 — H2: flake source-build failure repro (control)"
if [[ ${FLAKE_REPRO} != 1 ]]; then
  record "5 H2 flake repro" "SKIP" "opt-in: re-run with FLAKE_REPRO=1 (costs a doomed Go build, ~minutes)"
elif ! command -v flox >/dev/null 2>&1; then
  record "5 H2 flake repro" "SKIP" "no flox"
else
  STAGE5_START=$(date +%s)
  REPRO_LOG="$(mktemp)"
  if run_logged "${REPRO_LOG}" timeout "${FLAKE_REPRO_TIMEOUT}" \
    flox activate --dir "${REPO_ROOT}/envs/flake-repro" --mode run -- true; then
    record "5 H2 flake repro" "FAIL" "flake build SUCCEEDED ($(elapsed "${STAGE5_START}")) — this sandbox does NOT reproduce #445's defect; H1's PASS is weaker evidence here"
  elif grep -q 'homeless-shelter' "${REPRO_LOG}"; then
    note '```'
    grep -n 'homeless-shelter' "${REPRO_LOG}" | head -5 >>"${BODY}"
    note '```'
    record "5 H2 flake repro" "PASS" "reproduced the exact /homeless-shelter purity failure ($(elapsed "${STAGE5_START}"))"
  else
    note_excerpt "${REPRO_LOG}"
    record "5 H2 flake repro" "FAIL" "flake build failed but NOT with /homeless-shelter — different failure mode, see body ($(elapsed "${STAGE5_START}"))"
  fi
fi

# ---------------------------------------------------------------------------
# Stage 6 (opt-in): Phase D' prototype — authenticated FloxHub consumption
# ---------------------------------------------------------------------------
section "Stage 6 — Phase D' prototype: authenticated FloxHub consumption"
if [[ ${TEST_AUTH_PLUMBING} != 1 ]]; then
  record "6 auth plumbing" "SKIP" "opt-in: re-run with TEST_AUTH_PLUMBING=1 FLOXHUB_TOKEN=<token> (permanently authenticates this sandbox — never run on the one testing Stage 4)"
elif ! command -v flox >/dev/null 2>&1; then
  record "6 auth plumbing" "SKIP" "no flox"
else
  STAGE6_START=$(date +%s)
  LOGIN_LOG="$(mktemp)"
  if run_logged "${LOGIN_LOG}" bash "${SCRIPT_DIR}/floxhub-login.sh"; then
    ACT6_LOG="$(mktemp)"
    if run_logged "${ACT6_LOG}" flox activate --dir "${REPO_ROOT}/envs/floxhub-consume" --mode run -- true; then
      DUR6="$(elapsed "${STAGE6_START}")"
      SYSTEM6="$(uname -m | sed s/arm64/aarch64/)-$(uname -s | tr '[:upper:]' '[:lower:]')"
      FLOX_BIN6="${REPO_ROOT}/envs/floxhub-consume/.flox/run/${SYSTEM6}.floxhub-consume-run/bin"
      if [[ ! -d ${FLOX_BIN6} ]]; then
        for d in "${REPO_ROOT}/envs/floxhub-consume/.flox/run/"*"/bin"; do
          [[ -d "${d}" ]] && FLOX_BIN6="${d}" && break
        done
      fi
      if [[ -x "${FLOX_BIN6}/conductor-workspace-floxhub-01" ]]; then
        note "Authenticated activation succeeded in ${DUR6}; pkg-path resolved under \`${FLOX_BIN6}\`."
        record "6 auth plumbing" "PASS" "flox auth login --token-file + flox activate against a pkg-path manifest works end to end (${DUR6})"
      else
        record "6 auth plumbing" "FAIL" "activation OK but conductor-workspace-floxhub-01 not found under run bin dir"
      fi
    else
      note_excerpt "${ACT6_LOG}"
      record "6 auth plumbing" "FAIL" "authenticated but 'flox activate --dir envs/floxhub-consume' failed — see body"
    fi
  else
    note_excerpt "${LOGIN_LOG}"
    record "6 auth plumbing" "FAIL" "scripts/floxhub-login.sh failed — see body (likely FLOXHUB_TOKEN unset/invalid)"
  fi
fi

# ---------------------------------------------------------------------------
# Compose the report
# ---------------------------------------------------------------------------
{
  echo "# gtm-sdk#445 sandbox findings — ${STAMP}"
  echo
  echo "Harness: \`scripts/sandbox-test.sh\` @ $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown rev')"
  echo "Options: FLAKE_REPRO=${FLAKE_REPRO}, FLOXHUB_TEST_PKG=${FLOXHUB_TEST_PKG}"
  echo
  echo "| Stage | Result | Detail |"
  echo "|---|---|---|"
  printf '%s' "${SUMMARY_ROWS}"
  cat "${BODY}"
} >"${REPORT}"
rm -f "${BODY}"

log ""
log "Report: ${REPORT}"
log "Full log: ${FULL_LOG}"
log ""
log "$(grep -E '^\| ' "${REPORT}" | head -20)"
