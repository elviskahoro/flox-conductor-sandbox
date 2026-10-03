#!/usr/bin/env bash
# Codified container verification for scripts/conductor-cloud-install.sh.
#
# Runs INSIDE a throwaway amazonlinux:2023 container — the real Conductor
# cloud / Vercel runtime class — replicating the sandbox shape: a non-root
# user with passwordless sudo (user code runs as `vercel-sandbox` there).
# The minimal base image lacks sudo/tar/useradd/su that a real AL2023
# sandbox ships, so those are installed first (the same documented gap the
# repo's dagger bootstrap compensates for).
#
# Usage, from the repo root on any docker host (the CI workflow runs the
# same natively on x86_64):
#
#   docker run --platform linux/amd64 --rm -v "$PWD":/src:ro -w /src \
#     amazonlinux:2023 bash scripts/conductor-cloud-install-test.sh
#
# Covers what the roborev review asked to be codified: fresh + idempotent
# install runs with no FAIL rows, every tool resolving under
# /usr/local/bin, /usr/bin/python3 staying 3.9 (dnf's interpreter), and the
# python3-shadow safety facts the install script's comment records (dnf's
# absolute shebang, zero env-python3 system consumers, dnf still working
# after the shadow). RUN 3/4 do the same for the generic
# conductor-setup-script.sh: a fresh run (the RUN 1/2 binaries are
# removed first, so its own pinned download path is exercised, not the
# reuse branch) and an idempotent re-run, both from a non-git cwd with no
# RWX_ACCESS_TOKEN — exactly the container's reality — asserting pinned
# versions resolve and auth/init take their WARN rows rather than FAIL.
# RUN 5/6 codify the two headline guards of the generic script: a
# core.hooksPath-injected run (git's env-config mechanism, the same one
# the live verification used; roborev stubbed so only the guard branch's
# own behavior is under test) must skip init and leave the machine-global
# hooks dir untouched, and a stubbed-rwx run must land the token file
# atomically — content replaced, no accesstoken.tmp leftover.
# Exits non-zero on the first broken assertion.
set -euo pipefail

INSTALL_SCRIPT="/src/scripts/conductor-cloud-install.sh"

fail() { echo "TEST FAIL: $*" >&2; exit 1; }

dnf install -y sudo shadow-utils util-linux tar >/dev/null
useradd -m sandbox-user
echo "sandbox-user ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/sandbox-user
chmod 440 /etc/sudoers.d/sandbox-user

# Shadow-safety fact 1: dnf's own interpreter must be reached by an absolute
# shebang — not /usr/bin/env python3, which PATH would resolve through
# /usr/local/bin and the 3.11 shadow.
DNF_SHEBANG="$(head -1 /usr/bin/dnf)"
echo "dnf shebang: ${DNF_SHEBANG}"
[[ "${DNF_SHEBANG}" == '#!/usr/bin/python3' ]] ||
  fail "expected /usr/bin/dnf shebang #!/usr/bin/python3, got: ${DNF_SHEBANG}"

# Shadow-safety fact 2 (tripwire): no /usr/bin or /usr/sbin script may
# resolve its interpreter through PATH. A future AL2023 image that adds an
# env-shebang system tool fails here, forcing the shadow argument to be
# re-checked before the install script's comment stays truthful. (grep
# exits 1 on zero matches — the expected outcome here — so neutralize it
# for set -e/pipefail instead of dying silently.)
ENV_PY3_CONSUMERS="$({ grep -rl '^#!/usr/bin/env python3' /usr/bin /usr/sbin 2>/dev/null || true; } | tr '\n' ' ')"
echo "env-python3 consumers in /usr/bin /usr/sbin: ${ENV_PY3_CONSUMERS:-none}"
[[ -z "${ENV_PY3_CONSUMERS}" ]] ||
  fail "unexpected /usr/bin/env python3 system consumers: ${ENV_PY3_CONSUMERS}"

echo "=== RUN 1: fresh install (login shell of non-root sandbox-user) ==="
RUN1_OUTPUT="$(su - sandbox-user -c "bash ${INSTALL_SCRIPT}")" ||
  fail "fresh conductor-cloud-install.sh exited non-zero"
printf '%s\n' "${RUN1_OUTPUT}"
case "${RUN1_OUTPUT}" in
*FAIL*) fail "fresh run recorded FAIL row(s)" ;;
esac

echo "=== VERIFY: every deliverable resolves as sandbox-user ==="
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  pin_roborev=\"\$(sed -n 's/^ROBOREV_PIN=\"\([^\"]*\)\".*/\1/p' ${INSTALL_SCRIPT})\"
  pin_rwx=\"\$(sed -n 's/^RWX_PIN=\"\([^\"]*\)\".*/\1/p' ${INSTALL_SCRIPT})\"

  [ \"\$(command -v python3)\" = /usr/local/bin/python3 ] ||
    fail \"python3 resolved to \$(command -v python3), expected /usr/local/bin/python3\"
  python3 --version 2>&1 | grep -q '^Python 3\.11\.' ||
    fail \"python3 is not 3.11: \$(python3 --version 2>&1)\"
  pip3 --version 2>&1 | grep -q 'python 3\.11' ||
    fail \"pip3 does not run on python 3.11: \$(pip3 --version 2>&1)\"

  [ \"\$(command -v roborev)\" = /usr/local/bin/roborev ] ||
    fail \"roborev resolved to \$(command -v roborev)\"
  roborev version 2>&1 | grep -q \"v\${pin_roborev}\" ||
    fail \"roborev version does not report the pinned v\${pin_roborev}: \$(roborev version 2>&1)\"
  [ \"\$(command -v git-roborev)\" = /usr/local/bin/git-roborev ] ||
    fail \"git-roborev resolved to \$(command -v git-roborev)\"
  git-roborev version >/dev/null 2>&1 ||
    fail \"git-roborev is not runnable\"

  trunk --version >/dev/null 2>&1 ||
    fail \"trunk --version failed: \$(trunk --version 2>&1)\"

  rwx --version 2>&1 | grep -q \"\${pin_rwx}\" ||
    fail \"rwx does not report the pinned \${pin_rwx}: \$(rwx --version 2>&1)\"

  /usr/bin/python3 --version 2>&1 | grep -q '^Python 3\.9\.' ||
    fail \"/usr/bin/python3 must stay 3.9 for dnf: \$(/usr/bin/python3 --version 2>&1)\"

  sudo dnf repolist >/dev/null 2>&1 ||
    fail \"dnf stopped working after the python3 shadow (sudo dnf repolist)\"
" || fail "verification as sandbox-user failed"

echo "=== RUN 2: idempotent re-run ==="
RUN2_OUTPUT="$(su - sandbox-user -c "bash ${INSTALL_SCRIPT}")" ||
  fail "second conductor-cloud-install.sh exited non-zero"
printf '%s\n' "${RUN2_OUTPUT}"
case "${RUN2_OUTPUT}" in
*FAIL*) fail "second run recorded FAIL row(s) — not idempotent" ;;
*"~/.local/bin"*) fail "second run used the ~/.local/bin fallback — unexpected on the target class" ;;
esac

echo "=== RUN 3: fresh run of the generic roborev+rwx setup script ==="
# Remove the binaries RUN 1/2 installed so the generic script exercises its
# OWN pinned download path (same pins as the sibling, per validate-pins.sh)
# instead of the reuse branch. Run as sandbox-user from a non-git cwd: this
# container has no RWX_ACCESS_TOKEN and no agent auth, so the auth and init
# stages must take their WARN rows and the run must still exit 0 — proving
# the non-fatal paths rather than pretending to test authenticated ones.
rm -f /usr/local/bin/roborev /usr/local/bin/git-roborev /usr/local/bin/rwx
GENERIC_SCRIPT="/src/scripts/conductor-setup-script.sh"
RUN3_OUTPUT="$(su - sandbox-user -c "cd /tmp && bash ${GENERIC_SCRIPT}")" ||
  fail "fresh conductor-setup-script.sh exited non-zero"
printf '%s' "${RUN3_OUTPUT}"
case "${RUN3_OUTPUT}" in
*FAIL*) fail "generic fresh run recorded FAIL row(s)" ;;
*reused*) fail "generic fresh run recorded a reused row — the rm above did not take effect" ;;
esac
# Positive assertions: the WARN rows must actually appear. Absence-of-FAIL
# checks alone would stay green if a stage regressed into a silent no-op
# that records no summary row at all (roborev review finding).
case "${RUN3_OUTPUT}" in *"cwd is not a git worktree"*) ;; *) fail "generic fresh run missing the non-git-init WARN row" ;; esac
case "${RUN3_OUTPUT}" in *"RWX_ACCESS_TOKEN not set"*) ;; *) fail "generic fresh run missing the no-token WARN row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  pin_roborev=\"\$(sed -n 's/^ROBOREV_PIN=\"\([^\"]*\)\".*/\1/p' ${GENERIC_SCRIPT})\"
  pin_rwx=\"\$(sed -n 's/^RWX_PIN=\"\([^\"]*\)\".*/\1/p' ${GENERIC_SCRIPT})\"
  [ \"\$(command -v roborev)\" = /usr/local/bin/roborev ] ||
    fail \"roborev resolved to \$(command -v roborev), expected /usr/local/bin/roborev\"
  roborev version 2>&1 | grep -q \"v\${pin_roborev}\" ||
    fail \"roborev version does not report the pinned v\${pin_roborev}: \$(roborev version 2>&1)\"
  [ \"\$(command -v rwx)\" = /usr/local/bin/rwx ] ||
    fail \"rwx resolved to \$(command -v rwx), expected /usr/local/bin/rwx\"
  rwx --version 2>&1 | grep -q \"\${pin_rwx}\" ||
    fail \"rwx does not report the pinned \${pin_rwx}: \$(rwx --version 2>&1)\"
" || fail "generic-script verification as sandbox-user failed"

echo "=== RUN 4: generic script idempotent re-run ==="
RUN4_OUTPUT="$(su - sandbox-user -c "cd /tmp && bash ${GENERIC_SCRIPT}")" ||
  fail "second conductor-setup-script.sh exited non-zero"
printf '%s' "${RUN4_OUTPUT}"
case "${RUN4_OUTPUT}" in
*FAIL*) fail "generic second run recorded FAIL row(s) — not idempotent" ;;
*"~/.local/bin"*) fail "generic second run used the ~/.local/bin fallback — unexpected on the target class" ;;
esac
# Positive assertion: the second run must show REUSE rows — a re-download
# instead of reuse would pass the FAIL/fallback checks above unnoticed
# (roborev review finding).
case "${RUN4_OUTPUT}" in *"reused"*) ;; *) fail "generic second run missing reuse rows — re-downloaded instead of reusing" ;; esac

echo "=== RUN 5: core.hooksPath guard skips init, never writes the global hooks dir ==="
# Codifies the hoisted guard. git is installed HERE (after RUN 1-4, whose
# environment stays git-less by design) because the guard's branch is only
# reachable from inside a work tree. core.hooksPath is injected via git's
# env-config mechanism — the same mechanism the live verification used —
# pointing at an empty dir that must still be empty afterward, while a
# fresh repo must NOT gain .roborev.toml and the run must still exit 0.
# roborev itself is stubbed (version/status exit 0) so the assertions
# depend ONLY on the guard branch's own behavior: a real daemon start in
# this never-init'd, agent-less container could red the test spuriously
# (roborev review finding). The tripwire for a guard regression is the
# skip-init WARN row — a regression that calls init anyway records a PASS
# init row instead, and that assertion fails.
dnf install -y git >/dev/null
GLOBAL_HOOKS=/tmp/global-hooks
rm -rf "${GLOBAL_HOOKS}" /tmp/guard-repo /tmp/roborev-stub
mkdir -p "${GLOBAL_HOOKS}" /tmp/roborev-stub
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; esac\nexit 0\n' > /tmp/roborev-stub/roborev
chmod 755 /tmp/roborev-stub/roborev
su - sandbox-user -c "git init -q /tmp/guard-repo"
RUN5_OUTPUT="$(su - sandbox-user -c "cd /tmp/guard-repo && PATH=/tmp/roborev-stub:\$PATH GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=${GLOBAL_HOOKS} bash ${GENERIC_SCRIPT}")" ||
  fail "generic run under core.hooksPath exited non-zero"
printf '%s' "${RUN5_OUTPUT}"
case "${RUN5_OUTPUT}" in
*FAIL*) fail "core.hooksPath run recorded FAIL row(s)" ;;
esac
case "${RUN5_OUTPUT}" in *"skipping roborev init"*) ;; *) fail "core.hooksPath run missing the skip-init WARN row" ;; esac
case "${RUN5_OUTPUT}" in *"roborev-daemon"*) ;; *) fail "core.hooksPath run missing the roborev-daemon row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ ! -e /tmp/guard-repo/.roborev.toml ] ||
    fail \"core.hooksPath run created .roborev.toml despite skipping init\"
  [ ! -e ${GLOBAL_HOOKS}/post-commit ] ||
    fail \"core.hooksPath run wrote a hook into the machine-global dir\"
" || fail "core.hooksPath guard verification failed"

echo "=== RUN 6: atomic token persist (stubbed rwx) ==="
# Codifies the atomic replace: a stub rwx whose whoami succeeds lets the
# persist path run with a fake token; the old token must be replaced and
# no accesstoken.tmp may linger (a truncate-write regression or a failed
# rename would trip one of the two assertions).
rm -rf /tmp/stubbin
mkdir -p /tmp/stubbin
printf '#!/bin/sh\ncase "$1" in whoami) echo stub-ok; exit 0;; esac\nexit 0\n' > /tmp/stubbin/rwx
chmod 755 /tmp/stubbin/rwx
su - sandbox-user -c "mkdir -p ~/.config/rwx && printf '%s' OLD-STUB-TOKEN > ~/.config/rwx/accesstoken && chmod 600 ~/.config/rwx/accesstoken"
RUN6_OUTPUT="$(su - sandbox-user -c "cd /tmp && PATH=/tmp/stubbin:\$PATH RWX_ACCESS_TOKEN=NEW-STUB-TOKEN bash ${GENERIC_SCRIPT}")" ||
  fail "stubbed-rwx run exited non-zero"
printf '%s' "${RUN6_OUTPUT}"
case "${RUN6_OUTPUT}" in
*FAIL*) fail "stubbed-rwx run recorded FAIL row(s)" ;;
esac
case "${RUN6_OUTPUT}" in *"and persisted to ~/.config/rwx/accesstoken"*) ;; *) fail "stubbed-rwx run missing the rwx-auth PASS row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ \"\$(cat ~/.config/rwx/accesstoken)\" = NEW-STUB-TOKEN ] ||
    fail \"atomic persist did not replace the old token\"
  [ ! -e ~/.config/rwx/accesstoken.tmp ] ||
    fail \"accesstoken.tmp leftover after a successful persist\"
" || fail "atomic persist verification failed"

echo "=== ALL CHECKS PASSED ==="
