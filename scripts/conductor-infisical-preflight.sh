#!/usr/bin/env bash
# Provision infisical for later agent commands during Conductor workspace
# setup (.conductor/settings.toml [scripts].setup runs this after the
# harness).
#
# Why this script exists: the inline `flox activate` it replaced (#34) ran
# unconditionally and, under `set -e`, killed the whole setup with
# "command not found: flox" on every local Mac workspace at creation — flox
# is only provisioned on the cloud Linux sandbox class (the harness Stage 1
# installs it there; non-Linux hosts get the Stage 1 SKIP "install flox
# manually", see scripts/sandbox-test.sh). --self-test codifies every
# branch (roborev review finding: the setup script is the only gate for
# workspace creation, so a regression here fails every future workspace at
# creation).
#
# Resolution, most-pinned-first, degrading only when a source is unusable:
#   1. Linux AND flox installed AND passwordless sudo → the original #34
#      behavior: activate envs/prebuilt, link its pinned infisical into
#      /usr/local/bin for later shells (flox activation is process-scoped).
#      This is the deterministic cloud-sandbox contract: on that class the
#      pinned env always wins, so a stray PATH infisical can never silently
#      shadow it. The Linux gate mirrors the harness Stage 1 bootstrap
#      (sandbox-test.sh) and guarantees non-Linux hosts never enter this
#      branch — a Mac with flox and warm/NOPASSWD sudo must not get its
#      /usr/local/bin mutated by a workspace setup (roborev finding), and
#      local hosts own their tooling ("install flox manually").
#   2. otherwise, an infisical already runnable on PATH — local Macs
#      (homebrew; the harness never provisions flox there) and Linux dev
#      boxes without flox or passwordless sudo. Reused as-is, no link.
#   3. neither → loud failure: a workspace without the secrets CLI must
#      not look ready.
#
# A Linux host where flox exists but cannot activate still fails loudly
# (branch 1 runs, the guard errors) — that is a real provisioning failure
# worth failing on, not something to paper over with a PATH binary.
#
# Safe to repeat: the branch-1 re-run re-activates and atomically re-links
# (ln -sfn), branch 2 is a pure PATH check.
#
# Design rules inherited from gtm-sdk's conductor-workspace-setup.sh:
# no process substitution anywhere (Conductor sandboxes can lack /dev/fd,
# gtm-sdk#279).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { printf '[infisical preflight] %s\n' "$*"; }

self_test() {
  local work stubbin floxbin sudobin pwdbin hostbin floxenv localbin realbin markdir
  work="$(mktemp -d "${TMPDIR:-/tmp}/infisical-preflight-test.XXXXXX")"
  # Cleanup on EXIT; signals terminate with 130 so the EXIT trap still
  # runs once and the script actually stops (roborev finding: a bare
  # signal trap that only cleans up would resume the test instead).
  trap 'rm -rf "${work}"' EXIT
  trap 'exit 130' INT TERM HUP
  stubbin="${work}/stub-bin"    # always-present stubs (uname)
  floxbin="${work}/flox-bin"    # flox stub (flox-branch cases only)
  sudobin="${work}/sudo-bin"    # passwordless-sudo stub
  pwdbin="${work}/pwd-bin"      # sudo stub that demands a password
  hostbin="${work}/host-bin"    # a preinstalled PATH infisical
  floxenv="${work}/flox-env"    # the pinned env's infisical
  localbin="${work}/local-bin"  # stand-in for /usr/local/bin
  realbin="${work}/real-bin"    # the real externals the child needs
  markdir="${work}/marks"       # stub call markers (flox-called, ...)
  mkdir -p "${stubbin}" "${floxbin}" "${sudobin}" "${pwdbin}" "${hostbin}" \
    "${floxenv}/bin" "${localbin}" "${realbin}" "${markdir}"

  # The child PATH below is ONLY these dirs — no /usr/bin:/bin — so the
  # cases are deterministic on any host (roborev finding: a host with its
  # own infisical in /usr/bin broke the "no infisical anywhere" case).
  # real-bin carries the real externals the child script and the stubs
  # need; everything else is a stub or a fake binary.
  local tool
  for tool in bash dirname mkdir ln basename; do
    ln -s "$(command -v "${tool}")" "${realbin}/${tool}"
  done

  # stub uname: STUB_UNAME selects the host class under test. The flox
  # branch is gated on it (mirroring the harness Stage 1 gate) and the
  # fallback warning reads it — cases 1, 2, 6, 7, 8 and 9 depend on this
  # stub, so it is load-bearing, never cosmetic.
  cat >"${stubbin}/uname" <<'EOS'
#!/bin/sh
printf '%s\n' "${STUB_UNAME}"
EOS

  # stub flox: STUB_FLOX_RESULT selects the activate outcome. Any call
  # drops a marker file so the self-test can assert the flox branch was
  # never entered on hosts where it must not run (case 7). `ok` also
  # asserts the activate targeted envs/prebuilt, so an arg-drift regression
  # fails the test rather than silently linking some other env.
  cat >"${floxbin}/flox" <<'EOS'
#!/bin/sh
: > "${STUB_MARK_DIR}/flox-called"
case "${STUB_FLOX_RESULT}" in
  ok)
    case "$*" in
      *envs/prebuilt*) ;;
      *) echo "stub-flox: activate called without envs/prebuilt: $*" >&2; exit 1 ;;
    esac
    printf '%s\n' "${STUB_FLOX_ENV}/bin/infisical"
    ;;
  broken) exit 1 ;;
  bogus) printf '%s\n' "${STUB_FLOX_ENV}/bin/not-infisical" ;;
esac
EOS

  # stub sudo (usable): `sudo -n true` succeeds; install/ln are performed
  # against FAKE_LOCAL_BIN instead of /usr/local/bin; anything else is a
  # tripwire for unexpected sudo use.
  cat >"${sudobin}/sudo" <<'EOS'
#!/bin/sh
case "$1" in
  -n) [ "$2" = true ] && exit 0
      echo "stub-sudo: unexpected -n call: $*" >&2; exit 1 ;;
  install) mkdir -p "${FAKE_LOCAL_BIN}" ;;
  ln) ln -sfn "$3" "${FAKE_LOCAL_BIN}/$(basename "$4")" ;;
  *) echo "stub-sudo: unexpected call: $*" >&2; exit 1 ;;
esac
EOS

  # stub sudo (passworded): `sudo -n true` fails — the local-dev-box shape.
  cat >"${pwdbin}/sudo" <<'EOS'
#!/bin/sh
echo "stub-sudo: a password is required" >&2
exit 1
EOS

  # Two distinct fake infisicals so assertions can tell which one ran:
  # hostbin = an infisical preinstalled on the PATH (Mac/homebrew case),
  # floxenv = the one resolved from the pinned flox environment.
  printf '#!/bin/sh\necho host-infisical-selftest 9.9.9\n' >"${hostbin}/infisical"
  printf '#!/bin/sh\necho env-infisical-selftest 9.9.9\n' >"${floxenv}/bin/infisical"
  chmod +x "${stubbin}/uname" "${floxbin}/flox" "${sudobin}/sudo" \
    "${pwdbin}/sudo" "${hostbin}/infisical" "${floxenv}/bin/infisical"

  local failures=0 out exit_code

  check() {
    # check <label> <actual> <expected>
    if [[ "$2" == "$3" ]]; then
      printf 'PASS %s\n' "$1"
    else
      printf 'FAIL %s: expected %q, got %q\n' "$1" "$3" "$2"
      failures=$((failures + 1))
    fi
  }

  assert_in() {
    # assert_in <label> <literal substring> — asserts against the last
    # $out. String match, no grep pipe: `printf | grep -q` under pipefail
    # can SIGPIPE the printf side and flake (roborev finding).
    if [[ "${out}" == *"$2"* ]]; then
      printf 'PASS %s\n' "$1"
    else
      printf 'FAIL %s: %q not found in: %s\n' "$1" "$2" "${out}"
      failures=$((failures + 1))
    fi
  }

  assert_file() {
    # assert_file <label> <must-exist:yes|no> <path>
    if [[ "$2" == yes && -e "$3" ]] || [[ "$2" == no && ! -e "$3" ]]; then
      printf 'PASS %s\n' "$1"
    else
      printf 'FAIL %s: exists=%s required=%s (%s)\n' "$1" \
        "$([[ -e "$3" ]] && echo yes || echo no)" "$2" "$3"
      failures=$((failures + 1))
    fi
  }

  # run_preflight <child-PATH> <STUB_UNAME> <STUB_FLOX_RESULT>
  # Captures combined output into $out and the exit code into $exit_code;
  # never aborts the parent on the child's intended failure. The child
  # bash is invoked by absolute path so `env` execs it directly — no PATH
  # lookup, which behaves differently between GNU and BSD `env` (roborev
  # finding: the self-test must not depend on env's lookup semantics).
  run_preflight() {
    exit_code=0
    out="$(env PATH="$1" STUB_UNAME="$2" STUB_FLOX_RESULT="$3" \
      STUB_FLOX_ENV="${floxenv}" FAKE_LOCAL_BIN="${localbin}" \
      STUB_MARK_DIR="${markdir}" \
      "${realbin}/bash" "${BASH_SOURCE[0]}" 2>&1)" || exit_code=$?
  }

  printf '== CASE 1: no flox, infisical on PATH (local Mac) → reuse, exit 0 ==\n'
  rm -f "${localbin}/infisical" "${markdir}/flox-called"
  run_preflight "${realbin}:${stubbin}:${hostbin}" Darwin ok
  check "case-1 exit code" "${exit_code}" 0
  assert_in "case-1 reuse message" 'reusing infisical already on PATH'
  assert_in "case-1 version via PATH binary" 'host-infisical-selftest'

  printf '== CASE 2: no flox, no infisical → loud error, exit 1 ==\n'
  rm -f "${localbin}/infisical" "${markdir}/flox-called"
  run_preflight "${realbin}:${stubbin}" Darwin ok
  check "case-2 exit code" "${exit_code}" 1
  assert_in "case-2 install hint" 'install infisical'
  if [[ ! -e "${localbin}/infisical" ]]; then
    printf 'PASS case-2 no link attempted\n'
  else
    printf 'FAIL case-2 no link attempted\n'
    failures=$((failures + 1))
  fi

  printf '== CASE 3: flox + passwordless sudo, activate ok → pinned env link, exit 0 ==\n'
  rm -f "${localbin}/infisical" "${markdir}/flox-called"
  run_preflight "${realbin}:${stubbin}:${floxbin}:${sudobin}:${localbin}" Linux ok
  check "case-3 exit code" "${exit_code}" 0
  if [[ -x "${localbin}/infisical" ]]; then
    printf 'PASS case-3 link created\n'
  else
    printf 'FAIL case-3 link created\n'
    failures=$((failures + 1))
  fi
  check "case-3 link target" "$(readlink "${localbin}/infisical")" \
    "${floxenv}/bin/infisical"
  assert_in "case-3 version via linked env binary" 'env-infisical-selftest'
  assert_file "case-3 flox branch entered" yes "${markdir}/flox-called"

  printf '== CASE 4: flox + sudo, activate fails → loud error with exit code, exit 1 ==\n'
  rm -f "${localbin}/infisical" "${markdir}/flox-called"
  run_preflight "${realbin}:${stubbin}:${floxbin}:${sudobin}:${localbin}" Linux broken
  check "case-4 exit code" "${exit_code}" 1
  assert_in "case-4 clear error" \
    'did not yield a runnable infisical command (flox exit 1)'
  if [[ ! -e "${localbin}/infisical" ]]; then
    printf 'PASS case-4 no link created\n'
  else
    printf 'FAIL case-4 no link created\n'
    failures=$((failures + 1))
  fi

  printf '== CASE 5: flox + sudo, activate resolves a non-executable path → loud error, exit 1 ==\n'
  rm -f "${localbin}/infisical" "${markdir}/flox-called"
  run_preflight "${realbin}:${stubbin}:${floxbin}:${sudobin}:${localbin}" Linux bogus
  check "case-5 exit code" "${exit_code}" 1
  assert_in "case-5 clear error" 'did not yield a runnable infisical'
  if [[ ! -e "${localbin}/infisical" ]]; then
    printf 'PASS case-5 no link created\n'
  else
    printf 'FAIL case-5 no link created\n'
    failures=$((failures + 1))
  fi

  printf '== CASE 6: Linux, flox present but sudo needs a password → PATH reuse, no link, exit 0 ==\n'
  rm -f "${localbin}/infisical" "${markdir}/flox-called"
  run_preflight "${realbin}:${stubbin}:${floxbin}:${pwdbin}:${hostbin}:${localbin}" Linux ok
  check "case-6 exit code" "${exit_code}" 0
  assert_in "case-6 fallback warning" \
    'warning: flox present but passwordless sudo unavailable'
  assert_in "case-6 reuse message" 'reusing infisical already on PATH'
  assert_in "case-6 version via PATH binary" 'host-infisical-selftest'
  assert_file "case-6 no link created" no "${localbin}/infisical"

  printf '== CASE 7: Mac with flox and passwordless sudo → PATH reuse, flox branch never entered, exit 0 ==\n'
  rm -f "${localbin}/infisical" "${markdir}/flox-called"
  run_preflight "${realbin}:${stubbin}:${floxbin}:${sudobin}:${hostbin}:${localbin}" Darwin ok
  check "case-7 exit code" "${exit_code}" 0
  assert_in "case-7 reuse message" 'reusing infisical already on PATH'
  assert_in "case-7 version via PATH binary" 'host-infisical-selftest'
  assert_file "case-7 flox never called" no "${markdir}/flox-called"
  assert_file "case-7 no link created" no "${localbin}/infisical"

  printf '== CASE 8: Linux without flox, infisical on PATH → reuse, exit 0 ==\n'
  rm -f "${localbin}/infisical" "${markdir}/flox-called"
  run_preflight "${realbin}:${stubbin}:${hostbin}" Linux ok
  check "case-8 exit code" "${exit_code}" 0
  assert_in "case-8 reuse message" 'reusing infisical already on PATH'
  assert_in "case-8 version via PATH binary" 'host-infisical-selftest'
  assert_file "case-8 flox never called" no "${markdir}/flox-called"

  printf '== CASE 9: Linux without flox, no infisical → loud error, exit 1 ==\n'
  rm -f "${localbin}/infisical" "${markdir}/flox-called"
  run_preflight "${realbin}:${stubbin}" Linux ok
  check "case-9 exit code" "${exit_code}" 1
  assert_in "case-9 install hint" 'install infisical'
  assert_file "case-9 flox never called" no "${markdir}/flox-called"

  printf '\nself-test: %d failure(s)\n' "${failures}"
  # 0/1 exit, not the raw count (roborev finding: a count wraps mod 256,
  # so 256 failures would read as success); no bare `[[ ]]` test either —
  # its failure under `set -e` aborts mid-function and races the EXIT
  # trap's cleanup.
  exit $((failures > 0 ? 1 : 0))
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  # Guard against a future refactor turning self_test's exits into
  # returns: falling through here would run real provisioning (sudo ln
  # into /usr/local/bin) at the end of a self-test. shellcheck cannot
  # model function exits, so it cannot see that self_test exits on every
  # path and would flag the exit below as unreachable.
  # shellcheck disable=SC2317
  exit $?
fi

if [[ "$(uname -s)" == "Linux" ]] && command -v flox >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  # Pinned-env path (#34, the cloud-sandbox contract): activate
  # envs/prebuilt and link its infisical into /usr/local/bin for later
  # shells. Only Linux hosts with flox and passwordless sudo reach this
  # (the cloud sandbox class) — the uname gate mirrors the harness Stage 1
  # bootstrap and keeps a Mac with warm sudo out of a system-level
  # mutation. The activate exit code is captured (not swallowed by set -e)
  # so the guard below can say what actually happened; flox's own stderr
  # still reaches the console, command substitution only captures stdout.
  flox_rc=0
  INFISICAL_BIN="$(flox activate --dir "${REPO_ROOT}/envs/prebuilt" --mode run -- sh -c 'command -v infisical')" || flox_rc=$?
  if [[ -z "${INFISICAL_BIN}" || ! -x "${INFISICAL_BIN}" ]]; then
    log "error: flox activate of envs/prebuilt did not yield a runnable infisical command (flox exit ${flox_rc})"
    exit 1
  fi
  sudo install -d -m 755 /usr/local/bin
  sudo ln -sfn "${INFISICAL_BIN}" /usr/local/bin/infisical
  log "linked ${INFISICAL_BIN} -> /usr/local/bin/infisical"
elif command -v infisical >/dev/null 2>&1; then
  # No usable flox. On a Linux host where flox IS installed this means
  # passwordless sudo was unavailable — on the cloud sandbox class that is
  # a provisioning regression (sudoers misconfiguration), so warn loudly
  # rather than silently degrading. Deliberately fail-open only when a
  # PATH infisical actually exists to fall back to (a Linux dev box with
  # its own infisical): a fresh cloud sandbox with a sudoers regression
  # has no PATH infisical and still fails in the branch below. The
  # warning lands in ~/.conductor-setup.log, the audited setup artifact.
  if [[ "$(uname -s)" == "Linux" ]] && command -v flox >/dev/null 2>&1; then
    log "warning: flox present but passwordless sudo unavailable; reusing PATH infisical instead of the pinned envs/prebuilt one"
  fi
  # Local Macs and Linux hosts without flox: reuse as-is, no link needed.
  log "reusing infisical already on PATH: $(command -v infisical)"
else
  log "error: no infisical on PATH and no usable flox (installed + passwordless sudo) to activate envs/prebuilt — install infisical (e.g. brew install infisical) or fix flox provisioning, then re-create the workspace"
  exit 1
fi

infisical --version
