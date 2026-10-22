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
# Usage, from the repo root, with the docker host's NATIVE platform
# (linux/arm64 on Apple Silicon, linux/amd64 on x86_64; the CI workflow runs
# natively on x86_64):
#
#   docker run --platform linux/<native-arch> --rm -v "$PWD":/src:ro -w /src \
#     amazonlinux:2023 bash scripts/conductor-startup-script-cloud-test.sh
#
# Never under qemu emulation (e.g. linux/amd64 on Apple Silicon): the pinned
# Go binaries (roborev, rwx) then crash or hang at random — ~7-10% of starts
# panic, a few segfault with no output, some never exit (issue #92) — so the
# suite refuses to start there instead of failing misleadingly mid-run.
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
#     script's own behavior is under test) must write .roborev.toml
#     directly (never via `roborev init` — init installs a post-commit
#     auto-review hook, the background-review posture this script must not
#     leave behind), leave the machine-global hooks dir untouched, and
#     never call a hook-installing roborev subcommand: the stub REJECTS
#     init/install-hook/uninstall-hook, so a regression records a FAIL row
#     and the empty-global-dir asserts are the second tripwire.
#   - RUN 3B: the repo-local hook posture — a pre-seeded roborev
#     post-commit hook (what an older setup of this script, or a bare
#     `roborev init`, leaves behind) must be removed via
#     `roborev uninstall-hook` (stubbed to rm the hook files), with the
#     removal PASS row recorded; a fresh repo must never gain a hook.
#   - RUN 3C: the highest-stakes branch — core.hooksPath set AND a roborev
#     hook actually present in the machine-global dir. The script must only
#     WARN (hand-removal instructions) and never touch the dir: a stray
#     `roborev uninstall-hook` there would strip post-commit hooks for
#     every repository on the machine. The stub's uninstall-hook leaves a
#     marker file so ANY call is detectable, and the seeded-hook-present
#     assert catches a real removal.
#   - RUN 3D: the ROBOREV_AGENT gate — a malformed value (quotes/spaces
#     would corrupt the TOML) must record the WARN row without replaying
#     the raw value and still write the default agent, while a valid
#     custom slug must land in .roborev.toml and in the PASS row.
#   - RUN 3E: the collateral-damage guard — a foreign post-commit next to
#     a leftover roborev post-rewrite, with the stub's uninstall-hook
#     removing BOTH (the worst-case uninstaller). The script must record
#     the collateral WARN naming the vanished foreign hook, never the
#     plain removal PASS.
#   - RUN 3F: the remaining uninstall WARN branches — a partial
#     uninstall (post-commit removed, post-rewrite survives -> the
#     leftover-content WARN), a hard failure (exit 1 -> the
#     uninstall-failed WARN), and the worst case RUN 3E's threat model
#     implies (removes the foreign sibling AND fails -> the
#     failed+collateral WARN naming the vanished path).
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
#   - RUN 13/14 (issue #85, pi install): the SKIP contract when npm is
#     absent (RUN 13 — fresh RUN 1's posture, no Node on a stock
#     amazonlinux:2023 sandbox, the pi stage must record its SKIP row,
#     not FAIL); and the install + reuse contract via stubbed npm (RUN
#     14 — a stub npm that creates a fake `pi` binary plus the verify
#     sanity check, exercising the SHA512-decode + tarball + pin path
#     end to end without a real npm registry hit; the idempotent re-run
#     then asserts the REUSE row). RUN 16 runs the live (unpatched)
#     script against the same fixture so the SRI check fails closed, and
#     asserts pi stays uninstalled with a WARN row and a zero exit under the
#     default (strict) posture — pi failures never fail setup;
#     the same run sets ROBOREV_MODEL= (empty) and asserts no model line.
#     RUN 17 denies sudo so the install falls back to --prefix ~/.local,
#     then re-runs to assert the reuse row from there. RUN 18 keeps that
#     installed pi but fails the smoke check with FIREWORKS_API_KEY unset:
#     with a malformed ROBOREV_MODEL (no model line) the smoke WARN stays
#     generic; RUN 18B's default Fireworks model gets the key-specific WARN.
#     RUN 19 offers npm with a Node below 22.19 and asserts a SKIP row and
#     a zero exit under the default (strict) posture. RUN 20 drives each
#     remaining fail-closed branch (download failure, undecodable pin, npm
#     failure, pi missing from PATH after install) and asserts the WARN
#     row, a zero strict-posture exit, and the branch's own setup-log message.
#     RUN 21 asserts an explicit non-pi ROBOREV_AGENT skips the install even
#     with npm present, and that a committed .roborev.toml whose agent line
#     lacks a trailing newline still drives the smoke check.
# Exits non-zero on the first broken assertion.
set -euo pipefail

# qemu-user runs a binary as `qemu-<arch> <binary> ...`, so the emulator is
# this shell's argv[0] (issue #92: see the usage note above). It must be read
# by a child process: qemu fakes a process's view of its own cmdline (bash's
# builtin read sees just "bash"), but not another process's.
emulator="$(tr '\0' '\n' </proc/$$/cmdline | sed -n 1p)"
if [[ "${emulator}" == *qemu-* ]]; then
  echo "TEST FAIL: running under ${emulator##*/} emulation, where the pinned Go binaries crash or hang at random (issue #92) — re-run with the docker host's native --platform" >&2
  exit 1
fi

STARTUP_SCRIPT="/src/scripts/conductor-startup-script-cloud.sh"

fail() { echo "TEST FAIL: $*" >&2; exit 1; }

dnf install -y sudo shadow-utils util-linux tar >/dev/null
useradd -m sandbox-user
echo "sandbox-user ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/sandbox-user
chmod 440 /etc/sudoers.d/sandbox-user

# The pi stage keys on `command -v npm`: every run below expects the SKIP
# branch except where RUN 14+ stub npm in. On a host with npm, the live
# script would do a real download and global install of pi, so fail before
# the first run rather than at RUN 13.
! su - sandbox-user -c "command -v npm" >/dev/null 2>&1 ||
  fail "this suite needs a host without npm on sandbox-user's PATH"

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
*" | FAIL |"*) fail "fresh run recorded FAIL row(s)" ;;
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
*" | FAIL |"*) fail "second run recorded FAIL row(s) — not idempotent" ;;
*"~/.local/bin"*) fail "second run used the ~/.local/bin fallback — unexpected on the target class" ;;
esac
# Positive assertion: the second run must show REUSE rows — a re-download
# instead of reuse would pass the FAIL/fallback checks above unnoticed
# (roborev review finding).
case "${RUN2_OUTPUT}" in *"reused"*) ;; *) fail "second run missing reuse rows — re-downloaded instead of reusing" ;; esac

echo "=== RUN 3: core.hooksPath guard writes config directly, never touches the global hooks dir ==="
# Codifies the no-auto-review posture under a machine-global hooks dir.
# git is installed HERE (after RUN 1/2, whose environment stays git-less by
# design) because the guard's branch is only reachable from inside a work
# tree. core.hooksPath is injected via git's env-config mechanism — the same
# mechanism the live verification used — pointing at an empty dir that must
# still be empty afterward, while the repo MUST gain .roborev.toml (written
# directly — `roborev init` is never run, it would install a post-commit
# auto-review hook into the global dir) and the run must still exit 0.
# roborev itself is stubbed (version/status exit 0) so the assertions
# depend ONLY on the script's own behavior. The stub also REJECTS
# init/install-hook/uninstall-hook — the hook-installing subcommands must
# never be called on any path: a regression that calls one fails the run
# (the *FAIL* row assert), and the empty-global-dir asserts below are the
# second, mechanical tripwire.
dnf install -y git >/dev/null
GLOBAL_HOOKS=/tmp/global-hooks
rm -rf "${GLOBAL_HOOKS}" /tmp/guard-repo /tmp/roborev-stub
mkdir -p "${GLOBAL_HOOKS}" /tmp/roborev-stub
# "$1" must stay literal — this printf emits a stub script whose own case
# statement reads "$1", so single quotes are required, not an oversight.
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; init|install-hook|uninstall-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/roborev-stub/roborev
chmod 755 /tmp/roborev-stub/roborev
su - sandbox-user -c "git init -q /tmp/guard-repo"
RUN3_OUTPUT="$(su - sandbox-user -c "cd /tmp/guard-repo && PATH=/tmp/roborev-stub:\$PATH GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=${GLOBAL_HOOKS} bash ${STARTUP_SCRIPT}")" ||
  fail "run under core.hooksPath exited non-zero"
printf '%s' "${RUN3_OUTPUT}"
case "${RUN3_OUTPUT}" in
*" | FAIL |"*) fail "core.hooksPath run recorded FAIL row(s)" ;;
esac
case "${RUN3_OUTPUT}" in *"roborev-config"*) ;; *) fail "core.hooksPath run missing the roborev-config row" ;; esac
case "${RUN3_OUTPUT}" in *"roborev-daemon"*) ;; *) fail "core.hooksPath run missing the roborev-daemon row" ;; esac
case "${RUN3_OUTPUT}" in *"machine-global hooks dir"*) ;; *) fail "core.hooksPath run missing the machine-global-hooks-dir hook row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ -f /tmp/guard-repo/.roborev.toml ] ||
    fail \"core.hooksPath run did not write .roborev.toml directly\"
  grep -q 'agent = \"pi\"' /tmp/guard-repo/.roborev.toml ||
    fail \".roborev.toml is missing the agent line\"
  grep -q 'model = \"fireworks/accounts/fireworks/models/glm-5p3\"' /tmp/guard-repo/.roborev.toml ||
    fail \".roborev.toml is missing the model line\"
  [ ! -e ${GLOBAL_HOOKS}/post-commit ] ||
    fail \"core.hooksPath run wrote a hook into the machine-global dir\"
  [ ! -e ${GLOBAL_HOOKS}/post-rewrite ] ||
    fail \"core.hooksPath run wrote a post-rewrite hook into the machine-global dir\"
  [ ! -e /tmp/guard-repo/.git/hooks/post-commit ] ||
    fail \"core.hooksPath run wrote a hook into the repo-local hooks dir despite the global override\"
" || fail "core.hooksPath guard verification failed"

echo "=== RUN 3B: leftover roborev hook removed; nothing reinstalled ==="
# The migration and fresh paths of the no-background-review posture, in one
# repo-local (no core.hooksPath) run: a fake roborev post-commit hook
# pre-seeded where an older setup of this script (or a bare `roborev init`)
# left it must be removed via `roborev uninstall-hook` — the stub performs
# the removal so the script's own post-removal verification can pass — and
# the removal PASS row must be recorded. The stub still REJECTS
# init/install-hook: nothing may (re)install a hook on any path.
rm -rf /tmp/hook-repo /tmp/roborev-stub2
mkdir -p /tmp/roborev-stub2
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; uninstall-hook) rm -f "$(git rev-parse --git-path hooks/post-commit)" "$(git rev-parse --git-path hooks/post-rewrite)"; exit 0;; init|install-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/roborev-stub2/roborev
chmod 755 /tmp/roborev-stub2/roborev
su - sandbox-user -c "git init -q /tmp/hook-repo"
su - sandbox-user -c "printf '#!/bin/sh\nexec roborev post-commit\n' > /tmp/hook-repo/.git/hooks/post-commit && chmod 755 /tmp/hook-repo/.git/hooks/post-commit"
RUN3B_OUTPUT="$(su - sandbox-user -c "cd /tmp/hook-repo && PATH=/tmp/roborev-stub2:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "leftover-hook run exited non-zero"
printf '%s' "${RUN3B_OUTPUT}"
case "${RUN3B_OUTPUT}" in
*" | FAIL |"*) fail "leftover-hook run recorded FAIL row(s)" ;;
esac
case "${RUN3B_OUTPUT}" in *"removed a leftover roborev auto-review hook"*) ;; *) fail "leftover-hook run missing the hook-removal PASS row" ;; esac
case "${RUN3B_OUTPUT}" in *"roborev-agent"*) ;; *) fail "leftover-hook run missing the roborev-agent smoke row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ ! -e /tmp/hook-repo/.git/hooks/post-commit ] ||
    fail \"leftover roborev post-commit hook still present after setup\"
  [ -f /tmp/hook-repo/.roborev.toml ] ||
    fail \"leftover-hook run did not write .roborev.toml\"
" || fail "leftover-hook verification failed"

echo "=== RUN 3C: roborev hook in the machine-global dir -> WARN, never touched ==="
# The highest-stakes branch of the hook posture: core.hooksPath set AND a
# roborev hook actually present in the machine-global dir. The script must
# only WARN (with hand-removal instructions) — never remove, overwrite, or
# write anything there: a stray `roborev uninstall-hook` on this path would
# strip post-commit hooks for every repository on the machine. The stub's
# uninstall-hook leaves a marker file so ANY call is detectable even when
# it fails, and the seeded-hook-present assert catches a real removal.
rm -rf /tmp/global-hooks2 /tmp/guard-repo2 /tmp/roborev-stub3 /tmp/uninstall-called
mkdir -p /tmp/roborev-stub3
# The global dir must be owned by sandbox-user: the seeded hook below is
# written through su, and a root-owned mkdir (like RUN 3's, which never
# writes there) would make that pre-seed fail with permission denied.
su - sandbox-user -c "mkdir -p /tmp/global-hooks2"
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; uninstall-hook) echo called > /tmp/uninstall-called; exit 1;; init|install-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/roborev-stub3/roborev
chmod 755 /tmp/roborev-stub3/roborev
su - sandbox-user -c "git init -q /tmp/guard-repo2"
su - sandbox-user -c "printf '#!/bin/sh\nexec roborev post-commit\n' > /tmp/global-hooks2/post-commit && chmod 755 /tmp/global-hooks2/post-commit"
RUN3C_OUTPUT="$(su - sandbox-user -c "cd /tmp/guard-repo2 && PATH=/tmp/roborev-stub3:\$PATH GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/tmp/global-hooks2 bash ${STARTUP_SCRIPT}")" ||
  fail "run with a roborev hook in the global dir exited non-zero"
printf '%s' "${RUN3C_OUTPUT}"
case "${RUN3C_OUTPUT}" in
*" | FAIL |"*) fail "global-roborev-hook run recorded FAIL row(s)" ;;
esac
case "${RUN3C_OUTPUT}" in *"holding a roborev hook"*) ;; *) fail "global-roborev-hook run missing the WARN row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ -f /tmp/global-hooks2/post-commit ] ||
    fail \"the seeded roborev hook in the machine-global dir was removed or overwritten\"
  [ ! -e /tmp/uninstall-called ] ||
    fail \"roborev uninstall-hook was called against the machine-global hooks dir\"
  [ -f /tmp/guard-repo2/.roborev.toml ] ||
    fail \"global-roborev-hook run did not write .roborev.toml\"
" || fail "global-roborev-hook verification failed"

echo "=== RUN 3D: ROBOREV_AGENT gate — malformed falls back, valid slug lands ==="
# The agent gate has two branches no other run touches: a malformed
# ROBOREV_AGENT (quotes/spaces would corrupt the TOML) must record the
# WARN row WITHOUT replaying the raw value and still write the default
# agent, while a valid custom slug must land in .roborev.toml and in the
# PASS row (a regression that drops the gate or writes the raw value
# passes only if nothing asserts these).
rm -rf /tmp/agent-repo /tmp/agent-repo2 /tmp/agent-repo3 /tmp/agent-repo4 /tmp/agent-repo5 /tmp/roborev-stub4
mkdir -p /tmp/roborev-stub4
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; init|install-hook|uninstall-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/roborev-stub4/roborev
chmod 755 /tmp/roborev-stub4/roborev
su - sandbox-user -c "git init -q /tmp/agent-repo"
RUN3D_OUTPUT="$(su - sandbox-user -c "cd /tmp/agent-repo && PATH=/tmp/roborev-stub4:\$PATH ROBOREV_AGENT='bad \"value' bash ${STARTUP_SCRIPT}")" ||
  fail "malformed-agent run exited non-zero"
printf '%s' "${RUN3D_OUTPUT}"
case "${RUN3D_OUTPUT}" in
*" | FAIL |"*) fail "malformed-agent run recorded FAIL row(s)" ;;
esac
case "${RUN3D_OUTPUT}" in *"ROBOREV_AGENT is malformed"*) ;; *) fail "malformed-agent run missing the gate WARN row" ;; esac
# The no-replay property: the raw malformed value must NOT appear in the
# summary rows (control characters in a replayed value could spoof them).
case "${RUN3D_OUTPUT}" in
*'bad "value'*) fail "malformed ROBOREV_AGENT raw value replayed into the summary" ;;
esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  grep -q 'agent = \"pi\"' /tmp/agent-repo/.roborev.toml ||
    fail \"malformed ROBOREV_AGENT did not fall back to the default agent (pi) in .roborev.toml\"
" || fail "malformed-agent verification failed"
su - sandbox-user -c "git init -q /tmp/agent-repo2"
RUN3D2_OUTPUT="$(su - sandbox-user -c "cd /tmp/agent-repo2 && PATH=/tmp/roborev-stub4:\$PATH ROBOREV_AGENT=pi bash ${STARTUP_SCRIPT}")" ||
  fail "custom-agent run exited non-zero"
printf '%s' "${RUN3D2_OUTPUT}"
case "${RUN3D2_OUTPUT}" in
*" | FAIL |"*) fail "custom-agent run recorded FAIL row(s)" ;;
esac
case "${RUN3D2_OUTPUT}" in *".roborev.toml written (agent: pi, model:"*) ;; *) fail "custom-agent run missing the agent-pi PASS row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  grep -q 'agent = \"pi\"' /tmp/agent-repo2/.roborev.toml ||
    fail \"valid custom ROBOREV_AGENT=pi did not land in .roborev.toml\"
" || fail "custom-agent verification failed"
# A non-pi agent with ROBOREV_MODEL unset must NOT inherit pi's Fireworks
# model: the slug is pi's verified pair, not one another agent resolves.
su - sandbox-user -c "git init -q /tmp/agent-repo3"
RUN3D3_OUTPUT="$(su - sandbox-user -c "cd /tmp/agent-repo3 && PATH=/tmp/roborev-stub4:\$PATH ROBOREV_AGENT=opencode bash ${STARTUP_SCRIPT}")" ||
  fail "non-pi-agent run exited non-zero"
printf '%s' "${RUN3D3_OUTPUT}"
case "${RUN3D3_OUTPUT}" in *".roborev.toml written (agent: opencode) "*) ;; *) fail "non-pi-agent run missing the model-less agent PASS row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  grep -q 'agent = \"opencode\"' /tmp/agent-repo3/.roborev.toml ||
    fail \"ROBOREV_AGENT=opencode did not land in .roborev.toml\"
  ! grep -q '^model' /tmp/agent-repo3/.roborev.toml ||
    fail \"non-pi agent inherited pi's default model line\"
" || fail "non-pi-agent verification failed"
# An explicit, valid ROBOREV_MODEL lands verbatim for any agent.
su - sandbox-user -c "git init -q /tmp/agent-repo4"
RUN3D4_OUTPUT="$(su - sandbox-user -c "cd /tmp/agent-repo4 && PATH=/tmp/roborev-stub4:\$PATH ROBOREV_AGENT=opencode ROBOREV_MODEL=openai/gpt-test.1 bash ${STARTUP_SCRIPT}")" ||
  fail "explicit-model run exited non-zero"
printf '%s' "${RUN3D4_OUTPUT}"
case "${RUN3D4_OUTPUT}" in *".roborev.toml written (agent: opencode, model: openai/gpt-test.1) "*) ;; *) fail "explicit-model run missing the agent+model PASS row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  grep -qx 'model = \"openai/gpt-test.1\"' /tmp/agent-repo4/.roborev.toml ||
    fail \"explicit ROBOREV_MODEL did not land verbatim in .roborev.toml\"
" || fail "explicit-model verification failed"
# A .roborev.toml an earlier setup wrote with claude-code is left in place
# (never clobbered) but must be flagged rather than passed.
su - sandbox-user -c "git init -q /tmp/agent-repo5"
# shellcheck disable=SC2016
su - sandbox-user -c "printf '# Written by conductor-startup-script-cloud.sh — reviews here are\n# on demand and blocking (roborev review --wait); no post-commit\n# auto-review hook is installed (see that script for the reasoning).\nagent = \"claude-code\"\n' > /tmp/agent-repo5/.roborev.toml"
RUN3D5_OUTPUT="$(su - sandbox-user -c "cd /tmp/agent-repo5 && PATH=/tmp/roborev-stub4:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "legacy-toml run exited non-zero"
printf '%s' "${RUN3D5_OUTPUT}"
case "${RUN3D5_OUTPUT}" in
*"roborev-config | WARN | .roborev.toml was written by an earlier setup with agent claude-code"*) ;;
*) fail "legacy-toml run missing the claude-code migration WARN row" ;;
esac
su - sandbox-user -c "grep -qx 'agent = \"claude-code\"' /tmp/agent-repo5/.roborev.toml" ||
  fail "legacy-toml run rewrote the existing .roborev.toml"
# The smoke check must test the agent the file configures, not the default.
case "${RUN3D5_OUTPUT}" in
*"roborev-agent | PASS | claude-code answered"*) ;;
*) fail "legacy-toml run did not smoke-check the file's claude-code agent" ;;
esac

echo "=== RUN 3E: mixed hooks — a careless uninstall must not PASS over a deleted foreign hook ==="
# The collateral-damage guard: a foreign post-commit (a formatter, say)
# next to a leftover roborev post-rewrite. The stub's uninstall-hook
# removes BOTH files — the worst-case uninstaller — so the script must
# record the collateral WARN naming the vanished foreign hook, never the
# plain removal PASS.
rm -rf /tmp/mixed-repo /tmp/roborev-stub5
mkdir -p /tmp/roborev-stub5
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; uninstall-hook) rm -f "$(git rev-parse --git-path hooks/post-commit)" "$(git rev-parse --git-path hooks/post-rewrite)"; exit 0;; init|install-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/roborev-stub5/roborev
chmod 755 /tmp/roborev-stub5/roborev
su - sandbox-user -c "git init -q /tmp/mixed-repo"
su - sandbox-user -c "printf '#!/bin/sh\nexec my-formatter --fix\n' > /tmp/mixed-repo/.git/hooks/post-commit && chmod 755 /tmp/mixed-repo/.git/hooks/post-commit && printf '#!/bin/sh\n# roborev post-rewrite hook v2 - remaps reviews after rebase/amend\nexec roborev remap\n' > /tmp/mixed-repo/.git/hooks/post-rewrite && chmod 755 /tmp/mixed-repo/.git/hooks/post-rewrite"
RUN3E_OUTPUT="$(su - sandbox-user -c "cd /tmp/mixed-repo && PATH=/tmp/roborev-stub5:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "mixed-hook run exited non-zero"
printf '%s' "${RUN3E_OUTPUT}"
case "${RUN3E_OUTPUT}" in
*" | FAIL |"*) fail "mixed-hook run recorded FAIL row(s)" ;;
esac
case "${RUN3E_OUTPUT}" in *"collateral"*) ;; *) fail "mixed-hook run missing the collateral-damage WARN row" ;; esac
# The WARN must NAME the vanished foreign hook, not just say "collateral"
# — a regression that drops the path from the row would otherwise pass.
# The vanished path in the row is repo-root-relative ("collateral:
# .git/hooks/post-commit") — `git rev-parse --git-path` yields a relative
# path when GIT_DIR is relative — so anchor the assert on the
# collateral-marker + relative path, not an absolute tmp path.
case "${RUN3E_OUTPUT}" in *"collateral: .git/hooks/post-commit"*) ;; *) fail "collateral WARN does not name the vanished foreign hook path" ;; esac
case "${RUN3E_OUTPUT}" in
*"removed a leftover roborev auto-review hook"*) fail "mixed-hook run recorded the plain removal PASS despite a deleted foreign hook" ;;
esac

echo "=== RUN 3F: uninstall WARN branches — partial removal and hard failure ==="
# The two WARN branches of the repo-local uninstall path that no other
# run exercises: a stub uninstall-hook that removes only post-commit
# (post-rewrite survives -> the 'left roborev hook content' WARN naming
# it), and one that fails outright (exit 1 -> the 'uninstall-hook
# failed' WARN). Both are one-line stub variants, and both are exactly
# the branches a future refactor of the post-uninstall checks would
# most likely break silently.
rm -rf /tmp/partial-repo /tmp/fail-repo /tmp/roborev-stub6 /tmp/roborev-stub7
mkdir -p /tmp/roborev-stub6 /tmp/roborev-stub7
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; uninstall-hook) rm -f "$(git rev-parse --git-path hooks/post-commit)"; exit 0;; init|install-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/roborev-stub6/roborev
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; uninstall-hook) exit 1;; init|install-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/roborev-stub7/roborev
chmod 755 /tmp/roborev-stub6/roborev /tmp/roborev-stub7/roborev
su - sandbox-user -c "git init -q /tmp/partial-repo"
su - sandbox-user -c "printf '#!/bin/sh\n# roborev post-commit hook v4 - auto-reviews every commit\nexec roborev post-commit\n' > /tmp/partial-repo/.git/hooks/post-commit && chmod 755 /tmp/partial-repo/.git/hooks/post-commit && printf '#!/bin/sh\n# roborev post-rewrite hook v2 - remaps reviews after rebase/amend\nexec roborev remap\n' > /tmp/partial-repo/.git/hooks/post-rewrite && chmod 755 /tmp/partial-repo/.git/hooks/post-rewrite"
RUN3F_OUTPUT="$(su - sandbox-user -c "cd /tmp/partial-repo && PATH=/tmp/roborev-stub6:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "partial-uninstall run exited non-zero"
printf '%s' "${RUN3F_OUTPUT}"
case "${RUN3F_OUTPUT}" in
*" | FAIL |"*) fail "partial-uninstall run recorded FAIL row(s)" ;;
esac
case "${RUN3F_OUTPUT}" in *"left roborev hook content"*) ;; *) fail "partial-uninstall run missing the leftover-content WARN row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ ! -e /tmp/partial-repo/.git/hooks/post-commit ] ||
    fail \"partial-uninstall stub did not remove post-commit (stub shape drifted)\"
  [ -f /tmp/partial-repo/.git/hooks/post-rewrite ] ||
    fail \"post-rewrite vanished under a post-commit-only uninstall\"
" || fail "partial-uninstall verification failed"
su - sandbox-user -c "git init -q /tmp/fail-repo"
su - sandbox-user -c "printf '#!/bin/sh\n# roborev post-commit hook v4 - auto-reviews every commit\nexec roborev post-commit\n' > /tmp/fail-repo/.git/hooks/post-commit && chmod 755 /tmp/fail-repo/.git/hooks/post-commit"
RUN3F2_OUTPUT="$(su - sandbox-user -c "cd /tmp/fail-repo && PATH=/tmp/roborev-stub7:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "failed-uninstall run exited non-zero"
printf '%s' "${RUN3F2_OUTPUT}"
case "${RUN3F2_OUTPUT}" in
*" | FAIL |"*) fail "failed-uninstall run recorded FAIL row(s)" ;;
esac
case "${RUN3F2_OUTPUT}" in *"uninstall-hook' failed"*) ;; *) fail "failed-uninstall run missing the uninstall-failed WARN row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ -f /tmp/fail-repo/.git/hooks/post-commit ] ||
    fail \"the failed-uninstall stub must leave the hook in place (stub shape drifted)\"
" || fail "failed-uninstall verification failed"

# The worst case RUN 3E's threat model implies but never exercises: an
# uninstaller that deletes the foreign sibling hook AND exits non-zero.
# The script must record the failed+collateral WARN naming the vanished
# foreign path — never the plain uninstall-failed row alone.
rm -rf /tmp/worst-repo /tmp/roborev-stub8
mkdir -p /tmp/roborev-stub8
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; uninstall-hook) rm -f "$(git rev-parse --git-path hooks/post-commit)" "$(git rev-parse --git-path hooks/post-rewrite)"; exit 1;; init|install-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/roborev-stub8/roborev
chmod 755 /tmp/roborev-stub8/roborev
su - sandbox-user -c "git init -q /tmp/worst-repo"
su - sandbox-user -c "printf '#!/bin/sh\nexec my-formatter --fix\n' > /tmp/worst-repo/.git/hooks/post-commit && chmod 755 /tmp/worst-repo/.git/hooks/post-commit && printf '#!/bin/sh\n# roborev post-rewrite hook v2 - remaps reviews after rebase/amend\nexec roborev remap\n' > /tmp/worst-repo/.git/hooks/post-rewrite && chmod 755 /tmp/worst-repo/.git/hooks/post-rewrite"
RUN3F3_OUTPUT="$(su - sandbox-user -c "cd /tmp/worst-repo && PATH=/tmp/roborev-stub8:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "worst-case-uninstaller run exited non-zero"
printf '%s' "${RUN3F3_OUTPUT}"
case "${RUN3F3_OUTPUT}" in
*" | FAIL |"*) fail "worst-case-uninstaller run recorded FAIL row(s)" ;;
esac
case "${RUN3F3_OUTPUT}" in *"failed AND removed a non-roborev hook as collateral"*) ;; *) fail "worst-case-uninstaller run missing the failed+collateral WARN row" ;; esac
# Same relative-path shape as RUN 3E's assert above.
case "${RUN3F3_OUTPUT}" in *"collateral: .git/hooks/post-commit"*) ;; *) fail "failed+collateral WARN does not name the vanished foreign hook path" ;; esac

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
*" | FAIL |"*) fail "stubbed-rwx run recorded FAIL row(s)" ;;
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
*" | FAIL |"*) ;; *) fail "best-effort run missing FAIL row(s) — the failure must still be recorded" ;;
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
*" | FAIL |"*) fail "pytools run recorded FAIL row(s)" ;;
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
*" | FAIL |"*) fail "pytools re-run recorded FAIL row(s) — not idempotent" ;;
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
*" | FAIL |"*) fail "stale-pin run recorded FAIL row(s)" ;;
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
*" | FAIL |"*) fail "broken-venv run recorded FAIL row(s)" ;;
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

echo "=== RUN 13: pi SKIP when npm is absent ==="
# Issue #85 SKIP contract. amazonlinux:2023's stock image has no Node/npm
# (dnf would install nodejs18, but the script deliberately does not bring
# Node 22 in — that's the surface expansion issue #85 rejected). So the
# stage must record its SKIP row, not FAIL. The roborev-agent smoke then
# fails (no pi binary), and its WARN must say pi is not installed rather
# than blame the unset FIREWORKS_API_KEY, which cannot fix a missing agent.
rm -rf /tmp/pi-skip-repo /tmp/pi-skip-robo-stub
mkdir -p /tmp/pi-skip-robo-stub
# A minimal roborev stub: version/status/daemon exit 0; check-agents exits
# 1, as the real one does when the agent binary is missing.
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; status) exit 0;; daemon) exit 0;; check-agents) exit 1;; uninstall-hook|init|install-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/pi-skip-robo-stub/roborev
chmod 755 /tmp/pi-skip-robo-stub/roborev
su - sandbox-user -c "git init -q /tmp/pi-skip-repo"
RUN13_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-skip-repo && PATH=/tmp/pi-skip-robo-stub:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "pi-skip run exited non-zero"
printf '%s' "${RUN13_OUTPUT}"
case "${RUN13_OUTPUT}" in
*" | FAIL |"*) fail "pi-skip run recorded FAIL row(s) (pi should SKIP when npm is absent)" ;;
esac
case "${RUN13_OUTPUT}" in *"pi | SKIP"*) ;; *) fail "pi-skip run missing the SKIP row" ;; esac
case "${RUN13_OUTPUT}" in
*"roborev-agent | WARN | pi is not installed"*) ;;
*) fail "pi-skip run missing the pi-not-installed smoke WARN row" ;;
esac
case "${RUN13_OUTPUT}" in
*"FIREWORKS_API_KEY is unset"*) fail "pi-skip run blamed FIREWORKS_API_KEY for a missing pi binary" ;;
esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ ! -e /usr/local/bin/pi ] && [ ! -e ~/.local/bin/pi ] ||
    fail \"pi-skip run unexpectedly installed pi\"
" || fail "pi-skip verification failed"

echo "=== RUN 14: pi install via stubbed npm; replay the SUM script's SRI path ==="
# Issue #85 install path under stub primitives — fake network + fake npm,
# real cryptographic verify. We compose a deterministic 64-byte tarball
# fixture, compute its sha512, encode the digest as SRI base64 (the exact
# shape npm's `dist.integrity` field uses), and patch the script's
# PI_INTEGRITY constant in a sandbox copy. The script's curl → sha512_verify
# → npm install chain runs against the fixture unchanged; only the pin is
# rewritten to match it. This pattern (sandbox copy + sed patch) is the
# same one RUN 11/12 use to test the pytools pin_guard branch without a
# network — the input bytes are scoped to the test, the live pin stays
# untouched.
rm -rf /tmp/pi-install-repo /tmp/pi-install-stubs /tmp/local-startup.sh
mkdir -p /tmp/pi-install-stubs
PI_FIXTURE_BODY="$(printf 'pi-tarball-fixture-bytes-issue-85-RUN14')"
# Compute the fixture's sha512 via the host binary that lives on both
# classes (sha512sum on AL2023; shasum -a 512 is only on macOS). The script
# itself tolerates either via its `sha512_verify` helper; the test runtime
# only needs ONE reliable tool, and sha512sum is the one the script prefers
# in production.
PI_FIXTURE_SHA512_HEX="$(printf '%s' "${PI_FIXTURE_BODY}" | sha512sum | awk '{print $1}')"
# Encode the fixture's sha512 as SRI base64 (`sha512-<base64>`), the exact
# shape npm's `dist.integrity` and the script's PI_INTEGRITY constant
# use. Same length, same prefix, same alphabet — only the payload changes.
# Python3 is universally available on amazonlinux:2023 (and on Mac via the
# system or brew) — used here instead of `xxd -r -p | base64` because xxd
# is not part of stock AL2023.
PI_FIXTURE_INTEGRITY="sha512-$(python3 -c 'import base64, sys; print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "${PI_FIXTURE_SHA512_HEX}")"
echo "pi fixture sha512: ${PI_FIXTURE_SHA512_HEX}"
echo "pi fixture sri:    ${PI_FIXTURE_INTEGRITY}"
# Sandbox copy of the startup script with the integrity pin rewritten to
# match the test fixture. The live PI_INTEGRITY (the production pin) stays
# in scripts/conductor-startup-script-cloud.sh; the rewrite happens only on
# this /tmp copy. This is the same pattern gtm-sdk#619 used for the pytools
# pin_rewrite test — sed-in-place against an isolated copy, never against
# the tracked source.
# Match by prefix, not the full production SRI, so a re-pin cannot turn
# the patch into a silent no-op; the grep proves it applied.
sed "s|^PI_INTEGRITY=.*|PI_INTEGRITY=\"${PI_FIXTURE_INTEGRITY}\"|" \
  "${STARTUP_SCRIPT}" > /tmp/local-startup.sh
grep -qxF "PI_INTEGRITY=\"${PI_FIXTURE_INTEGRITY}\"" /tmp/local-startup.sh ||
  fail "PI_INTEGRITY patch did not apply to /tmp/local-startup.sh"
chmod 755 /tmp/local-startup.sh
# The stub curl intercepts the script's own tarball URL, so a re-pin keeps
# RUN 14 offline instead of falling through to a real registry download.
PI_PIN_VALUE="$(sed -n 's/^PI_PIN="\([^"]*\)".*/\1/p' /tmp/local-startup.sh)"
PI_STUB_URL="$(sed -n 's/^PI_TARBALL_URL="\([^"]*\)".*/\1/p' /tmp/local-startup.sh)"
# shellcheck disable=SC2016  # the literal ${PI_PIN} in the URL is the match target
PI_STUB_URL="${PI_STUB_URL//'${PI_PIN}'/${PI_PIN_VALUE}}"
[[ -n "${PI_PIN_VALUE}" && "${PI_STUB_URL}" == https://*".tgz" ]] ||
  fail "could not derive the pi tarball URL from /tmp/local-startup.sh (got: ${PI_STUB_URL:-<empty>})"
# stub curl: for the pi tarball URL only, emit the fixture body to the
# `-fsSLo <path>` file the script passed (curl's combined -f -s -S -L
# -o <path> form is called as a single arg `-fsSLo`, with the path as
# the following argument). The parser handles both combined forms
# (`-fsSLo <path>` etc., which curl accepts in one or two args) and
# the split `-o <path>` form. Other paths (trunk, roborev, etc.) fall
# through to whatever the host's real curl reaches.
# shellcheck disable=SC2016
{
  printf '#!/bin/sh\n'
  printf 'url=""\noutput=""\nprev=""\n'
  printf 'for a in "$@"; do\n'
  printf '  case "$prev" in\n'
  printf '    -o|-fsSLo|-fsLo|-fLo|-fo) output="$a" ;;\n'
  printf '  esac\n'
  printf '  case "$a" in\n'
  printf '    http://*|https://*) url="$a" ;;\n'
  printf '    -o|-fsSLo|-fsLo|-fLo|-fo) prev="$a"; continue ;;\n'
  printf '  esac\n'
  printf '  prev=""\n'
  printf 'done\n'
  printf 'case "$url" in\n'
  printf '  %s)\n' "${PI_STUB_URL}"
  printf '    if [ -n "$output" ]; then\n'
  printf '      printf "%%s" '"'"'%s'"'"' > "$output"\n' "${PI_FIXTURE_BODY}"
  printf '    else\n'
  printf '      printf "%%s" '"'"'%s'"'"'\n' "${PI_FIXTURE_BODY}"
  printf '    fi\n'
  printf '    exit 0;;\n'
  printf '  *) exec /usr/bin/curl "$@";;\n'
  printf 'esac\n'
} > /tmp/pi-install-stubs/curl
chmod 755 /tmp/pi-install-stubs/curl
# stub npm: install -g --prefix <dir> <tarball> creates <dir>/bin/pi as a
# tiny shell script reporting pi 1.3.0. The script calls `npm install -g
# --prefix /usr/local <tarball>` on this class (passwordless sudo), so the
# stub installs under /usr/local/bin.
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in install) shift; while [ $# -gt 0 ]; do case "$1" in -g|--global) ;; --prefix) shift; prefix="$1";; *) tarball="$1";; esac; shift; done; mkdir -p "${prefix}/bin"; printf "#!/bin/sh\necho '\''pi 1.3.0'\''\n" > "${prefix}/bin/pi"; chmod 755 "${prefix}/bin/pi"; exit 0;; esac\nexit 22\n' > /tmp/pi-install-stubs/npm
chmod 755 /tmp/pi-install-stubs/npm
# stub sudo: elevate through the real /usr/bin/sudo but re-export the
# caller's PATH, so `sudo npm install -g ...` still resolves the stubbed
# npm. Real sudo's secure_path Defaults on amazonlinux:2023 strips /tmp
# from PATH and would otherwise hide it; a plain exec pass-through would
# keep the stub visible but run it as sandbox-user, which cannot write the
# root-owned /usr/local/bin. The stub is shimmed BEFORE the real
# `/usr/bin/sudo` so `command -v sudo` in the script's prefix-detection
# branch picks it up first.
# shellcheck disable=SC2016
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -n) shift; continue;; *) break;; esac; done\nexec /usr/bin/sudo -n env "PATH=$PATH" "$@"\n' > /tmp/pi-install-stubs/sudo
chmod 755 /tmp/pi-install-stubs/sudo
# stub node: the stage SKIPs below Pi's engines floor, so report one that
# meets it (RUN 19 swaps in an older one).
printf '#!/bin/sh\necho v22.19.0\n' > /tmp/pi-install-stubs/node
chmod 755 /tmp/pi-install-stubs/node
# stub roborev for the post-install smoke check (same shape as RUN 13).
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; status) exit 0;; daemon) exit 0;; check-agents) exit 0;; uninstall-hook|init|install-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/pi-install-stubs/roborev
chmod 755 /tmp/pi-install-stubs/roborev
su - sandbox-user -c "git init -q /tmp/pi-install-repo"
RUN14_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-install-repo && PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "pi-install run exited non-zero"
printf '%s' "${RUN14_OUTPUT}"
case "${RUN14_OUTPUT}" in
*" | FAIL |"*) fail "pi-install run recorded FAIL row(s)" ;;
esac
case "${RUN14_OUTPUT}" in *"pi | PASS"*) ;; *) fail "pi-install run missing the pi PASS row" ;; esac
# The path-aware prefix install (--prefix /usr/local) is what the script
# uses on this class (passwordless sudo), so the stub pi binary is under
# /usr/local/bin — verify it was placed there.
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ -x /usr/local/bin/pi ] ||
    fail \"pi-install run did not place the pi binary under /usr/local/bin (the pinned AL2023 prefix)\"
  [ -f /tmp/pi-install-repo/.roborev.toml ] ||
    fail \"pi-install run did not write .roborev.toml\"
  grep -q 'agent = \"pi\"' /tmp/pi-install-repo/.roborev.toml ||
    fail \".roborev.toml is missing the agent line\"
  grep -q 'model = \"fireworks/accounts/fireworks/models/glm-5p3\"' /tmp/pi-install-repo/.roborev.toml ||
    fail \".roborev.toml is missing the default model line\"
" || fail "pi-install verification failed"

echo "=== RUN 15: pi reused on idempotent re-run ==="
# The reuse row: the second run finds pi on PATH (placed by RUN 14's
# stub), so the install path SKIPS and the stage records `reused
# /usr/local/bin/pi`. RUN 14/15 together cover the fresh-install +
# no-redownload idempotence contract — same class as RUN 2 for roborev.
# Re-runs the SAME patched /tmp/local-startup.sh from RUN 14 so the
# stub sha512 pin stays in effect; if any future change replaces the
# patched-script path with the live script here, RUN 14 should adopt
# the same convention.
RUN15_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-install-repo && PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "pi-reuse run exited non-zero"
printf '%s' "${RUN15_OUTPUT}"
case "${RUN15_OUTPUT}" in
*" | FAIL |"*) fail "pi-reuse run recorded FAIL row(s)" ;;
esac
case "${RUN15_OUTPUT}" in *"pi | PASS | reused"*) ;; *) fail "pi-reuse run missing the reused pi PASS row" ;;
esac

echo "=== RUN 16: pi integrity mismatch leaves pi uninstalled, setup passes ==="
# The live script keeps the production PI_INTEGRITY, so the stub curl's
# fixture body cannot match it: sha512_verify fails closed and pi is not
# installed. That is never fatal, so this runs under the default (strict)
# posture: the run exits 0 and the WARN row is the signal.
# ROBOREV_MODEL is set but empty: the header promises that writes no model
# line (only an unset variable takes the Fireworks default).
rm -f /usr/local/bin/pi
rm -rf /tmp/pi-mismatch-repo
su - sandbox-user -c "git init -q /tmp/pi-mismatch-repo"
RUN16_LOG_BEFORE="$(wc -l < /home/sandbox-user/.conductor-setup.log)"
RUN16_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-mismatch-repo && ROBOREV_MODEL= PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "pi-mismatch run exited non-zero (a pi install failure must not fail setup)"
printf '%s' "${RUN16_OUTPUT}"
case "${RUN16_OUTPUT}" in *" | FAIL |"*) fail "pi-mismatch run recorded FAIL row(s)" ;; esac
case "${RUN16_OUTPUT}" in *"pi | WARN | install failed — pi was not installed"*) ;; *) fail "pi-mismatch run missing the pi install-failed WARN row" ;; esac
tail -n "+$((RUN16_LOG_BEFORE + 1))" /home/sandbox-user/.conductor-setup.log | grep -qF "error: pi tarball integrity mismatch" ||
  fail "pi-mismatch run setup log missing the integrity-mismatch error"
[[ ! -e /usr/local/bin/pi ]] ||
  fail "pi-mismatch run installed pi despite the integrity mismatch"
grep -q '^agent = "pi"$' /tmp/pi-mismatch-repo/.roborev.toml ||
  fail "pi-mismatch run .roborev.toml is missing the agent line"
! grep -q '^model' /tmp/pi-mismatch-repo/.roborev.toml ||
  fail "empty ROBOREV_MODEL still wrote a model line"

echo "=== RUN 17: pi falls back to ~/.local without passwordless sudo ==="
# Same stubs as RUN 14 except sudo, which refuses (`sudo -n true` exits 1):
# sandbox-user cannot write /usr/local/bin, so pi_install must take the
# --prefix ~/.local branch, flag the placement, and still resolve pi via
# the ~/.local/bin the script keeps on PATH. RUN 16 left /usr/local/bin/pi
# absent, so this is a cold install.
rm -rf /tmp/pi-local-stubs /tmp/pi-local-repo
cp -r /tmp/pi-install-stubs /tmp/pi-local-stubs
printf '#!/bin/sh\nexit 1\n' > /tmp/pi-local-stubs/sudo
chmod 755 /tmp/pi-local-stubs/sudo
su - sandbox-user -c "rm -rf ~/.local/bin/pi ~/.local/lib/node_modules; git init -q /tmp/pi-local-repo"
RUN17_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-local-repo && PATH=/tmp/pi-local-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "pi-local run exited non-zero"
printf '%s' "${RUN17_OUTPUT}"
case "${RUN17_OUTPUT}" in
*" | FAIL |"*) fail "pi-local run recorded FAIL row(s)" ;;
esac
case "${RUN17_OUTPUT}" in
*"pi | PASS | v${PI_PIN_VALUE} (/home/sandbox-user/.local/bin/pi)"*) ;;
*) fail "pi-local run missing the ~/.local/bin pi PASS row" ;;
esac
case "${RUN17_OUTPUT}" in
*"tools landed in ~/.local/bin"*" pi"*) ;;
*) fail "pi-local run did not flag the ~/.local/bin placement" ;;
esac
[[ ! -e /usr/local/bin/pi ]] ||
  fail "pi-local run placed pi in /usr/local/bin without sudo"
RUN17B_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-local-repo && PATH=/tmp/pi-local-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "pi-local reuse run exited non-zero"
printf '%s' "${RUN17B_OUTPUT}"
case "${RUN17B_OUTPUT}" in
*"pi | PASS | reused /home/sandbox-user/.local/bin/pi"*) ;;
*) fail "pi-local reuse run missing the reused ~/.local/bin pi row" ;;
esac

echo "=== RUN 18: installed pi + failing smoke + malformed model WARN rows ==="
# RUN 17 left pi in ~/.local/bin, so the stage reuses it and the smoke
# failure cannot be blamed on a missing binary. ROBOREV_MODEL fails the TOML
# gate, so the model line is omitted with its own WARN and the raw value is
# never replayed; with no Fireworks model configured, the smoke WARN must
# stay generic rather than blame the unset FIREWORKS_API_KEY.
rm -rf /tmp/pi-smoke-stubs /tmp/pi-smoke-repo
cp -r /tmp/pi-local-stubs /tmp/pi-smoke-stubs
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; status) exit 0;; daemon) exit 0;; check-agents) exit 1;; uninstall-hook|init|install-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/pi-smoke-stubs/roborev
chmod 755 /tmp/pi-smoke-stubs/roborev
su - sandbox-user -c "git init -q /tmp/pi-smoke-repo"
RUN18_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-smoke-repo && unset FIREWORKS_API_KEY && ROBOREV_MODEL='bad model' PATH=/tmp/pi-smoke-stubs:/usr/local/bin:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "pi-smoke run exited non-zero"
printf '%s' "${RUN18_OUTPUT}"
case "${RUN18_OUTPUT}" in
*" | FAIL |"*) fail "pi-smoke run recorded FAIL row(s)" ;;
esac
case "${RUN18_OUTPUT}" in *"pi | PASS | reused /home/sandbox-user/.local/bin/pi"*) ;; *) fail "pi-smoke run did not reuse the installed pi" ;; esac
case "${RUN18_OUTPUT}" in *"ROBOREV_MODEL is malformed"*) ;; *) fail "pi-smoke run missing the malformed-model WARN row" ;; esac
case "${RUN18_OUTPUT}" in *"bad model"*) fail "malformed ROBOREV_MODEL raw value replayed into the summary" ;; esac
case "${RUN18_OUTPUT}" in
*"roborev-agent | WARN | pi failed its smoke check"*) ;;
*) fail "pi-smoke run missing the generic smoke WARN row" ;;
esac
case "${RUN18_OUTPUT}" in
*"FIREWORKS_API_KEY is unset"*) fail "pi-smoke run blamed FIREWORKS_API_KEY with no Fireworks model configured" ;;
esac
grep -q '^agent = "pi"$' /tmp/pi-smoke-repo/.roborev.toml ||
  fail "pi-smoke run .roborev.toml is missing the agent line"
! grep -q '^model' /tmp/pi-smoke-repo/.roborev.toml ||
  fail "malformed ROBOREV_MODEL still wrote a model line"

echo "=== RUN 18B: Fireworks model + unset key names FIREWORKS_API_KEY ==="
# Same failing smoke, default model (fireworks/...): now the key is the
# likely cause, and the WARN must say so.
rm -rf /tmp/pi-smoke-repo2
su - sandbox-user -c "git init -q /tmp/pi-smoke-repo2"
RUN18B_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-smoke-repo2 && unset FIREWORKS_API_KEY ROBOREV_MODEL && PATH=/tmp/pi-smoke-stubs:/usr/local/bin:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "pi-smoke-fireworks run exited non-zero"
printf '%s' "${RUN18B_OUTPUT}"
grep -q '^model = "fireworks/' /tmp/pi-smoke-repo2/.roborev.toml ||
  fail "pi-smoke-fireworks run did not write the default Fireworks model"
case "${RUN18B_OUTPUT}" in
*"roborev-agent | WARN | pi smoke failed and FIREWORKS_API_KEY is unset"*) ;;
*) fail "pi-smoke-fireworks run missing the FIREWORKS_API_KEY smoke WARN row" ;;
esac
# The unreplaced .env.cloud placeholder must get the same key-specific row.
RUN18C_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-smoke-repo2 && unset ROBOREV_MODEL && FIREWORKS_API_KEY='<fireworks-api-key>' PATH=/tmp/pi-smoke-stubs:/usr/local/bin:\$PATH bash ${STARTUP_SCRIPT}")" ||
  fail "pi-smoke-placeholder run exited non-zero"
printf '%s' "${RUN18C_OUTPUT}"
case "${RUN18C_OUTPUT}" in
*"roborev-agent | WARN | pi smoke failed and FIREWORKS_API_KEY is still the .env.cloud placeholder"*) ;;
*) fail "pi-smoke-placeholder run missing the placeholder-key smoke WARN row" ;;
esac

echo "=== RUN 19: Node below Pi's engines floor SKIPs, never fails setup ==="
# npm present but Node 18 (a dnf nodejs18, say): pi is only the default
# agent, so the strict-posture run must still exit 0 with a SKIP row and
# no download or install.
rm -rf /tmp/pi-oldnode-stubs /tmp/pi-oldnode-repo
cp -r /tmp/pi-install-stubs /tmp/pi-oldnode-stubs
printf '#!/bin/sh\necho v18.20.4\n' > /tmp/pi-oldnode-stubs/node
chmod 755 /tmp/pi-oldnode-stubs/node
su - sandbox-user -c "rm -f ~/.local/bin/pi; git init -q /tmp/pi-oldnode-repo"
RUN19_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-oldnode-repo && PATH=/tmp/pi-oldnode-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "old-node run exited non-zero (pi must SKIP, not fail setup)"
printf '%s' "${RUN19_OUTPUT}"
case "${RUN19_OUTPUT}" in
*" | FAIL |"*) fail "old-node run recorded FAIL row(s)" ;;
esac
case "${RUN19_OUTPUT}" in
*"pi | SKIP | Node 18.20.4 is below Pi's engines requirement"*) ;;
*) fail "old-node run missing the Node-version pi SKIP row" ;;
esac
[[ ! -e /usr/local/bin/pi ]] ||
  fail "old-node run installed pi in /usr/local/bin despite the Node-version SKIP"
! su - sandbox-user -c "test -e ~/.local/bin/pi" ||
  fail "old-node run installed pi in ~/.local/bin despite the Node-version SKIP"

echo "=== RUN 20: pi fail-closed branches leave pi uninstalled, setup passes ==="
# Each case starts from RUN 14's stubs and patched script (Node 22.19, an
# elevating sudo, a smoke-passing roborev) and breaks exactly one link.
# Strict posture: the run must still exit 0, with the WARN row and the
# setup-log message as the signals; the log is read from the line count
# before the run.
pi_fail_case() { # <name> <script> <stubs> <expected setup-log text>
  local name="$1" script="$2" stubs="$3" expected="$4" before out
  su - sandbox-user -c "rm -f ~/.local/bin/pi; rm -rf /tmp/pi-fail-repo; git init -q /tmp/pi-fail-repo"
  rm -f /usr/local/bin/pi
  before="$(wc -l < /home/sandbox-user/.conductor-setup.log)"
  out="$(su - sandbox-user -c "cd /tmp/pi-fail-repo && PATH=${stubs}:/usr/local/bin:\$PATH bash ${script}")" ||
    fail "${name}: run exited non-zero (a pi install failure must not fail setup)"
  printf '%s' "${out}"
  case "${out}" in *" | FAIL |"*) fail "${name}: recorded FAIL row(s)" ;; esac
  case "${out}" in *"pi | WARN | install failed — pi was not installed"*) ;; *) fail "${name}: missing the pi install-failed WARN row" ;; esac
  [[ ! -e /usr/local/bin/pi ]] || fail "${name}: pi is in /usr/local/bin despite the failure"
  ! su - sandbox-user -c "test -e ~/.local/bin/pi" || fail "${name}: pi is in ~/.local/bin despite the failure"
  tail -n "+$((before + 1))" /home/sandbox-user/.conductor-setup.log | grep -qF "${expected}" ||
    fail "${name}: setup log missing: ${expected}"
}
rm -rf /tmp/pi-fail-stubs-dl /tmp/pi-fail-stubs-npm /tmp/pi-fail-stubs-nobin /tmp/pi-fail-badpin.sh
cp -r /tmp/pi-install-stubs /tmp/pi-fail-stubs-dl
# shellcheck disable=SC2016
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *pi-coding-agent*) exit 22;; esac; done\nexec /usr/bin/curl "$@"\n' > /tmp/pi-fail-stubs-dl/curl
pi_fail_case "download failure" /tmp/local-startup.sh /tmp/pi-fail-stubs-dl "error: failed to download"
# Shape-valid SRI that decodes to 3 bytes (validate-pins rejects it in CI;
# this checks the runtime guard behind it).
sed 's|^PI_INTEGRITY=.*|PI_INTEGRITY="sha512-QUJD"|' /tmp/local-startup.sh > /tmp/pi-fail-badpin.sh
pi_fail_case "undecodable pin" /tmp/pi-fail-badpin.sh /tmp/pi-install-stubs "error: could not decode Pi integrity pin"
cp -r /tmp/pi-install-stubs /tmp/pi-fail-stubs-npm
printf '#!/bin/sh\necho "npm ERR! code EBADENGINE (stub)"\nexit 1\n' > /tmp/pi-fail-stubs-npm/npm
pi_fail_case "npm failure" /tmp/local-startup.sh /tmp/pi-fail-stubs-npm "npm output above in /home/sandbox-user/.conductor-setup.log"
# npm's own output must land in the setup log the message points at.
grep -qF "npm ERR! code EBADENGINE (stub)" /home/sandbox-user/.conductor-setup.log ||
  fail "npm failure: npm's output did not reach the setup log"
cp -r /tmp/pi-install-stubs /tmp/pi-fail-stubs-nobin
printf '#!/bin/sh\nexit 0\n' > /tmp/pi-fail-stubs-nobin/npm
pi_fail_case "pi not on PATH" /tmp/local-startup.sh /tmp/pi-fail-stubs-nobin "but its bin/ is not on PATH"

echo "=== RUN 21: explicit non-pi agent skips pi; newline-less agent line is read ==="
# npm + a new-enough Node are present (RUN 14's stubs), but ROBOREV_AGENT
# opts out of pi, so nothing may be downloaded or installed.
rm -rf /tmp/pi-optout-repo /tmp/pi-nonl-repo
rm -f /usr/local/bin/pi
su - sandbox-user -c "rm -f ~/.local/bin/pi; git init -q /tmp/pi-optout-repo"
RUN21_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-optout-repo && ROBOREV_AGENT=opencode PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "pi-optout run exited non-zero"
printf '%s' "${RUN21_OUTPUT}"
case "${RUN21_OUTPUT}" in *"pi | SKIP | ROBOREV_AGENT=opencode selects another review agent"*) ;; *) fail "pi-optout run missing the opt-out SKIP row" ;; esac
[[ ! -e /usr/local/bin/pi ]] || fail "pi-optout run installed pi despite ROBOREV_AGENT=opencode"
! su - sandbox-user -c "test -e ~/.local/bin/pi" || fail "pi-optout run installed pi in ~/.local/bin despite ROBOREV_AGENT=opencode"
# A committed .roborev.toml whose agent line has no trailing newline: the
# smoke check must still test that agent, not the pi default.
su - sandbox-user -c "git init -q /tmp/pi-nonl-repo && printf 'agent = \"opencode\"' > /tmp/pi-nonl-repo/.roborev.toml"
RUN21B_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-nonl-repo && PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "newline-less-toml run exited non-zero"
printf '%s' "${RUN21B_OUTPUT}"
case "${RUN21B_OUTPUT}" in *"roborev-agent | PASS | opencode answered"*) ;; *) fail "newline-less-toml run did not smoke-check the file's opencode agent" ;; esac
case "${RUN21B_OUTPUT}" in *"ROBOREV_MODEL is set but"*) fail "unset ROBOREV_MODEL triggered the ignored-model WARN" ;; esac
# ROBOREV_MODEL set against that existing (model-less) file cannot apply:
# it must be flagged, never silently ignored or written.
RUN21C_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-nonl-repo && ROBOREV_MODEL=openai/gpt-test.2 PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "ignored-model run exited non-zero"
printf '%s' "${RUN21C_OUTPUT}"
case "${RUN21C_OUTPUT}" in *"roborev-config | WARN | ROBOREV_MODEL is set but .roborev.toml already exists"*) ;; *) fail "ignored-model run missing the ROBOREV_MODEL WARN row" ;; esac
! su - sandbox-user -c "grep -q '^model' /tmp/pi-nonl-repo/.roborev.toml" ||
  fail "ignored-model run rewrote the existing .roborev.toml"

echo "=== ALL CHECKS PASSED ==="
