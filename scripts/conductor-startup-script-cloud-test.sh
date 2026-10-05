#!/usr/bin/env bash
# Codified container verification for
# scripts/conductor-startup-script-cloud.sh.
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
#     amazonlinux:2023 bash scripts/conductor-startup-script-cloud-test.sh
#
# Covers what the roborev review asked to be codified, against the single
# merged script (it replaced the former two-script pair, so one fresh run
# now exercises every pinned download path):
#
#   - RUN 1: a fresh run from a non-git login shell with no
#     RWX_ACCESS_TOKEN — exactly the container's reality — asserting the
#     pinned roborev/trunk/rwx downloads resolve under /usr/local/bin,
#     python3.11 lands with /usr/bin/python3 staying 3.9 (dnf's
#     interpreter), and the auth/init stages take their WARN rows rather
#     than FAIL (proving the non-fatal paths, not pretending to test
#     authenticated ones). Positive WARN-row assertions: absence-of-FAIL
#     alone would stay green if a stage regressed into a silent no-op
#     (roborev review finding). The pytools stage takes its gate-SKIP row
#     (RUN 1 runs flag-off — the paste-ready consumer's surface).
#   - RUN 2: an idempotent re-run — no FAIL rows, no ~/.local/bin fallback,
#     and REUSE rows present (a re-download instead of reuse would pass
#     the FAIL/fallback checks unnoticed — roborev review finding).
#   - RUN 3: a core.hooksPath-injected run (git's env-config mechanism, the
#     same one the live verification used; roborev stubbed so only the
#     guard branch's own behavior is under test) must skip init and leave
#     the machine-global hooks dir untouched.
#   - RUN 4: a stubbed-rwx run must land the token file atomically —
#     content replaced, no accesstoken.tmp leftover.
#   - RUN 5/6: the failure-semantics contract (roborev review finding on
#     the merge): a rejected RWX_ACCESS_TOKEN (stub rwx whose whoami
#     fails) must FAIL the run and exit non-zero by default — the
#     paste-ready consumer's reviewed posture — while the same failure
#     under STARTUP_BEST_EFFORT=1 (this repo's settings.toml contract,
#     gtm-sdk#702) is still recorded as a FAIL row but exits 0.
#   - RUN 7/8 (issue #44): STARTUP_PY_DEV_TOOLS=1 — the settings.toml
#     posture — provisions uv (real pinned download) plus pytest/reflex
#     (real PyPI install into the ~/.conductor-pytools venv), all
#     resolving under /usr/local/bin as sandbox-user with `python -m
#     pytest` and `import reflex` working in the venv; RUN 8 re-runs and
#     asserts reuse rows (no duplicate/broken installs).
#   - RUN 9/10 (issue #44): the pytools failure contract — a present-but-
#     broken uv (stub whose --version fails) must FAIL the run and exit
#     non-zero under the DEFAULT posture AND under STARTUP_BEST_EFFORT=1:
#     unlike roborev/trunk/rwx tool-stage failures, a requested tool that
#     cannot be provisioned never leaves a workspace that appears ready.
#   - RUN 11/12 (issue #44, roborev finding on c480ca7): the two middle
#     branches of the idempotence matrix, which RUN 7/8 (fresh, exact-pin
#     reuse) never touch — RUN 11 downgrades pytest in the healthy venv
#     and asserts the upgrade-in-place row (with reflex staying a reused
#     row: one install command, mixed state); RUN 12 replaces the venv
#     with a bin/python-less directory (an interrupted uv venv) and
#     asserts the heal branch recreates it (a created, NOT reused,
#     pytools-venv row) and reinstalls both packages.
# Exits non-zero on the first broken assertion.
set -euo pipefail

STARTUP_SCRIPT="/src/scripts/conductor-startup-script-cloud.sh"

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
# re-checked before the startup script's comment stays truthful. (grep
# exits 1 on zero matches — the expected outcome here — so neutralize it
# for set -e/pipefail instead of dying silently.)
ENV_PY3_CONSUMERS="$({ grep -rl '^#!/usr/bin/env python3' /usr/bin /usr/sbin 2>/dev/null || true; } | tr '\n' ' ')"
echo "env-python3 consumers in /usr/bin /usr/sbin: ${ENV_PY3_CONSUMERS:-none}"
[[ -z "${ENV_PY3_CONSUMERS}" ]] ||
  fail "unexpected /usr/bin/env python3 system consumers: ${ENV_PY3_CONSUMERS}"

echo "=== RUN 1: fresh startup run (login shell of non-root sandbox-user, non-git cwd, no token) ==="
RUN1_OUTPUT="$(su - sandbox-user -c "bash ${STARTUP_SCRIPT}")" ||
  fail "fresh conductor-startup-script-cloud.sh exited non-zero"
printf '%s\n' "${RUN1_OUTPUT}"
case "${RUN1_OUTPUT}" in
*FAIL*) fail "fresh run recorded FAIL row(s)" ;;
esac
# Positive assertions: the WARN rows must actually appear. Absence-of-FAIL
# checks alone would stay green if a stage regressed into a silent no-op
# that records no summary row at all (roborev review finding).
case "${RUN1_OUTPUT}" in *"cwd is not a git worktree"*) ;; *) fail "fresh run missing the non-git-init WARN row" ;; esac
case "${RUN1_OUTPUT}" in *"RWX_ACCESS_TOKEN not set"*) ;; *) fail "fresh run missing the no-token WARN row" ;; esac
# The pytools gate: flag-off runs (the paste-ready consumer) must record
# the SKIP row — a regression that provisioned anyway, or one that
# dropped the row entirely, both fail here.
case "${RUN1_OUTPUT}" in *"pytools | SKIP"*) ;; *) fail "fresh run missing the pytools gate SKIP row" ;; esac

echo "=== VERIFY: every deliverable resolves as sandbox-user ==="
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  pin_roborev=\"\$(sed -n 's/^ROBOREV_PIN=\"\([^\"]*\)\".*/\1/p' ${STARTUP_SCRIPT})\"
  pin_rwx=\"\$(sed -n 's/^RWX_PIN=\"\([^\"]*\)\".*/\1/p' ${STARTUP_SCRIPT})\"

  [ \"\$(command -v python3)\" = /usr/local/bin/python3 ] ||
    fail \"python3 resolved to \$(command -v python3), expected /usr/local/bin/python3\"
  python3 --version 2>&1 | grep -q '^Python 3\.11\.' ||
    fail \"python3 is not 3.11: \$(python3 --version 2>&1)\"
  pip3 --version 2>&1 | grep -q 'python 3\.11' ||
    fail \"pip3 does not run on python 3.11: \$(pip3 --version 2>&1)\"

  [ \"\$(command -v roborev)\" = /usr/local/bin/roborev ] ||
    fail \"roborev resolved to \$(command -v roborev)\"
  roborev_version_out=\"\$(roborev version 2>&1)\" || true
  # Capture-then-grep, never a live pipe: a transient once made the piped
  # grep see different output than an immediately-following re-run printed
  # (false FAIL, unreproducible on re-run) — capturing once means the
  # assertion and the failure message always agree. The || true keeps a
  # non-zero tool exit from killing this set -e block before the grep.
  printf '%s' \"\${roborev_version_out}\" | grep -q \"v\${pin_roborev}\" ||
    fail \"roborev version does not report the pinned v\${pin_roborev}: \${roborev_version_out}\"
  [ \"\$(command -v git-roborev)\" = /usr/local/bin/git-roborev ] ||
    fail \"git-roborev resolved to \$(command -v git-roborev)\"
  git-roborev version >/dev/null 2>&1 ||
    fail \"git-roborev is not runnable\"

  trunk --version >/dev/null 2>&1 ||
    fail \"trunk --version failed: \$(trunk --version 2>&1)\"

  rwx_version_out=\"\$(rwx --version 2>&1)\" || true
  # Capture-then-grep for the same reason as the roborev check above: one
  # invocation, one captured string — the assertion and any failure
  # message always agree.
  printf '%s' \"\${rwx_version_out}\" | grep -q \"\${pin_rwx}\" ||
    fail \"rwx does not report the pinned \${pin_rwx}: \${rwx_version_out}\"

  /usr/bin/python3 --version 2>&1 | grep -q '^Python 3\.9\.' ||
    fail \"/usr/bin/python3 must stay 3.9 for dnf: \$(/usr/bin/python3 --version 2>&1)\"

  sudo dnf repolist >/dev/null 2>&1 ||
    fail \"dnf stopped working after the python3 shadow (sudo dnf repolist)\"
" || fail "verification as sandbox-user failed"

echo "=== RUN 2: idempotent re-run ==="
RUN2_OUTPUT="$(su - sandbox-user -c "bash ${STARTUP_SCRIPT}")" ||
  fail "second conductor-startup-script-cloud.sh exited non-zero"
printf '%s\n' "${RUN2_OUTPUT}"
case "${RUN2_OUTPUT}" in
*FAIL*) fail "second run recorded FAIL row(s) — not idempotent" ;;
*"~/.local/bin"*) fail "second run used the ~/.local/bin fallback — unexpected on the target class" ;;
esac
# Positive assertion: the second run must show REUSE rows — a re-download
# instead of reuse would pass the FAIL/fallback checks above unnoticed
# (roborev review finding).
case "${RUN2_OUTPUT}" in *"reused"*) ;; *) fail "second run missing reuse rows — re-downloaded instead of reusing" ;; esac

echo "=== RUN 3: core.hooksPath guard skips init, never writes the global hooks dir ==="
# Codifies the hoisted guard. git is installed HERE (after RUN 1/2, whose
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
# "$1" must stay literal — this printf emits a stub script whose own case
# statement reads "$1", so single quotes are required, not an oversight.
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; esac\nexit 0\n' > /tmp/roborev-stub/roborev
chmod 755 /tmp/roborev-stub/roborev
su - sandbox-user -c "git init -q /tmp/guard-repo"
RUN3_OUTPUT="$(su - sandbox-user -c "cd /tmp/guard-repo && PATH=/tmp/roborev-stub:\$PATH GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=${GLOBAL_HOOKS} bash ${STARTUP_SCRIPT}")" ||
  fail "run under core.hooksPath exited non-zero"
printf '%s' "${RUN3_OUTPUT}"
case "${RUN3_OUTPUT}" in
*FAIL*) fail "core.hooksPath run recorded FAIL row(s)" ;;
esac
case "${RUN3_OUTPUT}" in *"skipping roborev init"*) ;; *) fail "core.hooksPath run missing the skip-init WARN row" ;; esac
case "${RUN3_OUTPUT}" in *"roborev-daemon"*) ;; *) fail "core.hooksPath run missing the roborev-daemon row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ ! -e /tmp/guard-repo/.roborev.toml ] ||
    fail \"core.hooksPath run created .roborev.toml despite skipping init\"
  [ ! -e ${GLOBAL_HOOKS}/post-commit ] ||
    fail \"core.hooksPath run wrote a hook into the machine-global dir\"
" || fail "core.hooksPath guard verification failed"

echo "=== RUN 4: atomic token persist (stubbed rwx) ==="
# Codifies the atomic replace: a stub rwx whose whoami succeeds lets the
# persist path run with a fake token; the old token must be replaced and
# no accesstoken.tmp may linger (a truncate-write regression or a failed
# rename would trip one of the two assertions).
rm -rf /tmp/stubbin
mkdir -p /tmp/stubbin
# Same as RUN 3's stub: "$1" must stay literal inside the emitted script.
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in whoami) echo stub-ok; exit 0;; esac\nexit 0\n' > /tmp/stubbin/rwx
chmod 755 /tmp/stubbin/rwx
su - sandbox-user -c "mkdir -p ~/.config/rwx && printf '%s' OLD-STUB-TOKEN > ~/.config/rwx/accesstoken && chmod 600 ~/.config/rwx/accesstoken"
RUN4_OUTPUT="$(su - sandbox-user -c "cd /tmp && PATH=/tmp/stubbin:\$PATH RWX_ACCESS_TOKEN=NEW-STUB-TOKEN bash ${STARTUP_SCRIPT}")" ||
  fail "stubbed-rwx run exited non-zero"
printf '%s' "${RUN4_OUTPUT}"
case "${RUN4_OUTPUT}" in
*FAIL*) fail "stubbed-rwx run recorded FAIL row(s)" ;;
esac
case "${RUN4_OUTPUT}" in *"and persisted to ~/.config/rwx/accesstoken"*) ;; *) fail "stubbed-rwx run missing the rwx-auth PASS row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ \"\$(cat ~/.config/rwx/accesstoken)\" = NEW-STUB-TOKEN ] ||
    fail \"atomic persist did not replace the old token\"
  [ ! -e ~/.config/rwx/accesstoken.tmp ] ||
    fail \"accesstoken.tmp leftover after a successful persist\"
" || fail "atomic persist verification failed"

echo "=== RUN 5: rejected token fails the run by default (paste-ready posture) ==="
# A stub rwx whose whoami FAILS drives the rwx-auth stage into its FAIL
# row; with no STARTUP_BEST_EFFORT the run must exit non-zero — the
# tools-a-workspace-exists-for must fail loudly contract.
rm -rf /tmp/stubfail
mkdir -p /tmp/stubfail
# Same literal-"$1" rule as RUN 3/4's stubs.
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in whoami) exit 1;; esac\nexit 0\n' > /tmp/stubfail/rwx
chmod 755 /tmp/stubfail/rwx
if RUN5_OUTPUT="$(su - sandbox-user -c "cd /tmp && PATH=/tmp/stubfail:\$PATH RWX_ACCESS_TOKEN=REJECTED-STUB-TOKEN bash ${STARTUP_SCRIPT}")"; then
  fail "rejected-token run exited 0 in default mode — must fail loudly"
fi
printf '%s' "${RUN5_OUTPUT}"
case "${RUN5_OUTPUT}" in
*"RWX_ACCESS_TOKEN rejected"*) ;; *) fail "rejected-token run missing the rwx-auth FAIL row" ;; esac

echo "=== RUN 6: STARTUP_BEST_EFFORT=1 records the same failure without failing the run ==="
# The gtm-sdk#702 contract this repo's settings.toml contracts for: the
# FAIL row must still appear (recorded, summarized, visible) while the
# run exits 0 — only a target-class Python 3.11 failure is fatal there.
if RUN6_OUTPUT="$(su - sandbox-user -c "cd /tmp && PATH=/tmp/stubfail:\$PATH STARTUP_BEST_EFFORT=1 RWX_ACCESS_TOKEN=REJECTED-STUB-TOKEN bash ${STARTUP_SCRIPT}")"; then :; else
  fail "best-effort run exited non-zero despite STARTUP_BEST_EFFORT=1"
fi
printf '%s' "${RUN6_OUTPUT}"
case "${RUN6_OUTPUT}" in
*FAIL*) ;; *) fail "best-effort run missing FAIL row(s) — the failure must still be recorded" ;;
esac
case "${RUN6_OUTPUT}" in
*"RWX_ACCESS_TOKEN rejected"*) ;; *) fail "best-effort run missing the rwx-auth FAIL row" ;; esac

echo "=== RUN 7: pytools provisioning (STARTUP_PY_DEV_TOOLS=1, the settings.toml posture) ==="
# Issue #44's target path: this repo's settings.toml exports both flags,
# so this run mirrors it — fresh pytools state (RUN 1/2 ran flag-off, so
# no uv on PATH and no ~/.conductor-pytools yet), a REAL pinned uv
# download with checksum verification, and a REAL pytest/reflex install
# from PyPI into the venv.
RUN7_OUTPUT="$(su - sandbox-user -c "cd /tmp && STARTUP_BEST_EFFORT=1 STARTUP_PY_DEV_TOOLS=1 bash ${STARTUP_SCRIPT}")" ||
  fail "pytools run exited non-zero"
printf '%s\n' "${RUN7_OUTPUT}"
case "${RUN7_OUTPUT}" in
*FAIL*) fail "pytools run recorded FAIL row(s)" ;;
esac
for row in "uv | PASS" "pytools-venv | PASS" "pytest | PASS" "reflex | PASS"; do
  case "${RUN7_OUTPUT}" in *"${row}"*) ;; *) fail "pytools run missing the ${row} row" ;; esac
done

echo "=== VERIFY: uv/pytest/reflex resolve as sandbox-user with the pinned versions ==="
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  pin_uv=\"\$(sed -n 's/^UV_PIN=\"\([^\"]*\)\".*/\1/p' ${STARTUP_SCRIPT})\"
  pin_pytest=\"\$(sed -n 's/^PYTEST_PIN=\"\([^\"]*\)\".*/\1/p' ${STARTUP_SCRIPT})\"
  pin_reflex=\"\$(sed -n 's/^REFLEX_PIN=\"\([^\"]*\)\".*/\1/p' ${STARTUP_SCRIPT})\"

  [ \"\$(command -v uv)\" = /usr/local/bin/uv ] ||
    fail \"uv resolved to \$(command -v uv), expected /usr/local/bin/uv\"
  uv_version_out=\"\$(uv --version 2>&1)\" || true
  printf '%s' \"\${uv_version_out}\" | grep -q \"\${pin_uv}\" ||
    fail \"uv does not report the pinned \${pin_uv}: \${uv_version_out}\"

  [ \"\$(command -v pytest)\" = /usr/local/bin/pytest ] ||
    fail \"pytest resolved to \$(command -v pytest)\"
  pytest_version_out=\"\$(pytest --version 2>&1)\" || true
  printf '%s' \"\${pytest_version_out}\" | grep -q \"\${pin_pytest}\" ||
    fail \"pytest does not report the pinned \${pin_pytest}: \${pytest_version_out}\"

  [ \"\$(command -v reflex)\" = /usr/local/bin/reflex ] ||
    fail \"reflex resolved to \$(command -v reflex)\"
  reflex_version_out=\"\$(reflex --version 2>&1)\" || true
  printf '%s' \"\${reflex_version_out}\" | grep -q \"\${pin_reflex}\" ||
    fail \"reflex does not report the pinned \${pin_reflex}: \${reflex_version_out}\"

  # Issue #44 acceptance: the provisioned Python environment runs
  # python -m pytest and imports reflex (the managed-environment
  # equivalent — the venv IS the intended environment).
  ~/.conductor-pytools/bin/python --version 2>&1 | grep -q '^Python 3\.11\.' ||
    fail \"pytools venv python is not 3.11: \$(~/.conductor-pytools/bin/python --version 2>&1)\"
  venv_pytest_out=\"\$(~/.conductor-pytools/bin/python -m pytest --version 2>&1)\" || true
  printf '%s' \"\${venv_pytest_out}\" | grep -q \"\${pin_pytest}\" ||
    fail \"venv python -m pytest failed or wrong version: \${venv_pytest_out}\"
  ~/.conductor-pytools/bin/python -c 'import reflex' ||
    fail \"import reflex failed in the pytools venv\"
" || fail "pytools verification as sandbox-user failed"

echo "=== RUN 8: pytools idempotent re-run ==="
RUN8_OUTPUT="$(su - sandbox-user -c "cd /tmp && STARTUP_BEST_EFFORT=1 STARTUP_PY_DEV_TOOLS=1 bash ${STARTUP_SCRIPT}")" ||
  fail "pytools re-run exited non-zero"
printf '%s\n' "${RUN8_OUTPUT}"
case "${RUN8_OUTPUT}" in
*FAIL*) fail "pytools re-run recorded FAIL row(s) — not idempotent" ;;
*"~/.local/bin"*) fail "pytools re-run used the ~/.local/bin fallback — unexpected on the target class" ;;
esac
# Positive reuse assertions: a re-download or re-install would pass the
# FAIL/fallback checks above unnoticed.
for row in "uv | PASS | reused" "pytools-venv | PASS | reused" "pytest | PASS | reused" "reflex | PASS | reused"; do
  case "${RUN8_OUTPUT}" in *"${row}"*) ;; *) fail "pytools re-run missing the ${row} row — re-provisioned instead of reusing" ;; esac
done

echo "=== RUN 9: broken uv fails the pytools run by default ==="
# A stub uv whose --version fails (shadowing /usr/local/bin/uv on PATH)
# drives the pytools stage into its present-but-not-functional FAIL row;
# with no STARTUP_BEST_EFFORT the run must exit non-zero — a requested
# tool that cannot be provisioned must fail setup loudly (issue #44).
rm -rf /tmp/stubuv
mkdir -p /tmp/stubuv
printf '#!/bin/sh\nexit 1\n' > /tmp/stubuv/uv
chmod 755 /tmp/stubuv/uv
if RUN9_OUTPUT="$(su - sandbox-user -c "cd /tmp && PATH=/tmp/stubuv:\$PATH STARTUP_PY_DEV_TOOLS=1 bash ${STARTUP_SCRIPT}")"; then
  fail "broken-uv run exited 0 in default mode — must fail loudly"
fi
printf '%s' "${RUN9_OUTPUT}"
case "${RUN9_OUTPUT}" in
*"uv | FAIL"*) ;; *) fail "broken-uv run missing the uv FAIL row" ;;
esac
case "${RUN9_OUTPUT}" in
*"pytools | FAIL"*) ;; *) fail "broken-uv run missing the aggregate pytools FAIL row" ;;
esac

echo "=== RUN 10: STARTUP_BEST_EFFORT=1 does NOT shield a pytools failure ==="
# The issue #44 contract, and the deliberate asymmetry vs RUN 6: roborev/
# trunk/rwx tool-stage failures are non-fatal under best-effort (the
# gtm-sdk#702 fallback-installer idiom), but a requested pytools failure
# is fatal under BOTH postures — the FAIL rows still record, the run
# still exits non-zero.
if RUN10_OUTPUT="$(su - sandbox-user -c "cd /tmp && PATH=/tmp/stubuv:\$PATH STARTUP_BEST_EFFORT=1 STARTUP_PY_DEV_TOOLS=1 bash ${STARTUP_SCRIPT}")"; then
  fail "best-effort broken-uv run exited 0 — pytools failures must stay fatal (issue #44)"
fi
printf '%s' "${RUN10_OUTPUT}"
case "${RUN10_OUTPUT}" in
*"uv | FAIL"*) ;; *) fail "best-effort broken-uv run missing the uv FAIL row" ;;
esac
case "${RUN10_OUTPUT}" in
*"pytools | FAIL"*) ;; *) fail "best-effort broken-uv run missing the aggregate pytools FAIL row" ;;
esac

echo "=== RUN 11: stale pytest pin upgraded in place ==="
# The pin guard's other branch: RUN 8 proved a satisfied pin is reused;
# this proves a STALE one is upgraded. Downgrade pytest in the healthy
# venv (a real, older PyPI release) and re-run: one uv pip install must
# restore both pins — pytest records an installed (upgraded) row while
# reflex, still at its pin, records a reused row (mixed state, single
# install command).
su - sandbox-user -c "uv pip install --python ~/.conductor-pytools/bin/python pytest==9.1.0" >/dev/null ||
  fail "could not pre-seed the stale pytest pin (uv pip install pytest==9.1.0 failed)"
RUN11_OUTPUT="$(su - sandbox-user -c "cd /tmp && STARTUP_BEST_EFFORT=1 STARTUP_PY_DEV_TOOLS=1 bash ${STARTUP_SCRIPT}")" ||
  fail "stale-pin run exited non-zero"
printf '%s\n' "${RUN11_OUTPUT}"
case "${RUN11_OUTPUT}" in
*FAIL*) fail "stale-pin run recorded FAIL row(s)" ;;
esac
case "${RUN11_OUTPUT}" in
*"pytest | PASS | 9.1.1 installed"*) ;; *) fail "stale-pin run missing the pytest upgraded-in-place row" ;;
esac
case "${RUN11_OUTPUT}" in
*"reflex | PASS | reused"*) ;; *) fail "stale-pin run missing the reflex reused row — a satisfied pin must stay untouched" ;;
esac
case "${RUN11_OUTPUT}" in
*"pytools-venv | PASS | reused"*) ;; *) fail "stale-pin run missing the venv reused row" ;;
esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  pin_pytest=\"\$(sed -n 's/^PYTEST_PIN=\"\([^\"]*\)\".*/\1/p' ${STARTUP_SCRIPT})\"
  pytest_version_out=\"\$(pytest --version 2>&1)\" || true
  printf '%s' \"\${pytest_version_out}\" | grep -q \"\${pin_pytest}\" ||
    fail \"pytest not back at the pin after upgrade-in-place: \${pytest_version_out}\"
" || fail "stale-pin upgrade verification failed"

echo "=== RUN 12: broken venv (no bin/python) healed ==="
# The heal branch: an interrupted uv venv leaves a directory without a
# functional bin/python. Replace the venv with exactly that shape and
# re-run: the stage must remove and recreate it (a created pytools-venv
# row, never a reused one) and reinstall both packages at their pins.
su - sandbox-user -c "rm -rf ~/.conductor-pytools && mkdir -p ~/.conductor-pytools" ||
  fail "could not pre-seed the broken venv shape"
RUN12_OUTPUT="$(su - sandbox-user -c "cd /tmp && STARTUP_BEST_EFFORT=1 STARTUP_PY_DEV_TOOLS=1 bash ${STARTUP_SCRIPT}")" ||
  fail "broken-venv run exited non-zero"
printf '%s\n' "${RUN12_OUTPUT}"
case "${RUN12_OUTPUT}" in
*FAIL*) fail "broken-venv run recorded FAIL row(s)" ;;
esac
# Positive: a created (not reused) venv row — the reused row's text also
# contains 'Python 3.11', so the discriminator is the leading 'reused'.
case "${RUN12_OUTPUT}" in
*"pytools-venv | PASS | reused"*) fail "broken-venv run reused a venv with no bin/python — heal branch did not fire" ;;
esac
case "${RUN12_OUTPUT}" in
*"pytools-venv | PASS | Python 3.11"*) ;; *) fail "broken-venv run missing the recreated pytools-venv row" ;;
esac
for row in "pytest | PASS | 9.1.1 installed" "reflex | PASS | 0.9.12 installed"; do
  case "${RUN12_OUTPUT}" in *"${row}"*) ;; *) fail "broken-venv run missing the ${row} row" ;; esac
done
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  ~/.conductor-pytools/bin/python -m pytest --version >/dev/null ||
    fail \"healed venv cannot run python -m pytest\"
  ~/.conductor-pytools/bin/python -c 'import reflex' ||
    fail \"healed venv cannot import reflex\"
" || fail "broken-venv heal verification failed"

echo "=== ALL CHECKS PASSED ==="
