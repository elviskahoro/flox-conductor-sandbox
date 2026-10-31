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
#   - RUN 23 (issue #101): the ROBOREV_AGENT override guard — claude-code
#     and codex (issue #85's known-cloudsandbox-broken list) now record a
#     louder WARN row that names the override and points at issue #101,
#     instead of the quiet SKIP row they used to share with valid agent
#     slugs. RUN 23B asserts the same row for codex; RUN 23C's opencode
#     override is the regression check that any future relaxation does not
#     promote a working agent to WARN. RUN 23D pairs an installed pi with
#     the override and asserts the tailored WARN that mentions "pi is
#     already installed" rather than the misleading "pi is not installed"
#     wording a re-run would otherwise produce.
#   - RUN 24 (issue #101): the $HOME/<repo> auto-discovery path. With cwd
#     outside any worktree and HOME pointing at a directory holding exactly
#     one git worktree (the Conductor cloud clone convention), the roborev
#     stage must write .roborev.toml INSIDE the discovered repo, not in
#     cwd. Without find_repo_root, the same setup silently SKIPs and a
#     fresh cloud workspace comes up with no .roborev.toml — the regression
#     RUN 24 codifies against. RUN 24B asserts two worktrees at the top
#     level is taken as ambiguous: find_repo_root returns 1 and the
#     no-worktree fallback must fire instead of silently picking a wrong
#     repo's .roborev.toml. RUN 24C1 asserts CONDUCTOR_WORKSPACE_PATH is
#     used when set with no $HOME worktree; RUN 24C2 asserts the env var
#     wins precedence when a $HOME worktree would also resolve.
#   - RUN 25 (issue #101): the no-worktree fallback. With no CONDUCTOR_
#     WORKSPACE_PATH and no worktrees under $HOME, the roborev stage must
#     record a single loud WARN naming the gap and still run daemon +
#     smoke check. The .roborev.toml-write and hook-posture stages must
#     NOT have run. The smoke-check helper's "no .roborev.toml" branch
#     (defaults fireworks_model=1 when agent is pi) lets the smoke WARN
#     row point at FIREWORKS_API_KEY rather than a generic "agent failed"
#     — RUN 25B asserts that hint by combining an unset key, an installed
#     pi, and a failing check-agents stub.
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
  pin_entire=\"\$(sed -n 's/^ENTIRE_PIN=\"\([^\"]*\)\".*/\1/p' ${STARTUP_SCRIPT})\"

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

  # Issue #91: the entire CLI lands via the same /usr/local/bin path as
  # roborev/rwx; both binaries (entire + git-remote-entire) must resolve
  # and the entire binary's version output must report the pinned x.y.z.
  [ \"\$(command -v entire)\" = /usr/local/bin/entire ] ||
    fail \"entire resolved to \$(command -v entire), expected /usr/local/bin/entire\"
  entire_version_out=\"\$(entire version 2>&1)\" || true
  printf '%s' \"\${entire_version_out}\" | grep -q \"Entire CLI \${pin_entire}\" ||
    fail \"entire does not report the pinned \${pin_entire}: \${entire_version_out}\"
  [ \"\$(command -v git-remote-entire)\" = /usr/local/bin/git-remote-entire ] ||
    fail \"git-remote-entire resolved to \$(command -v git-remote-entire), expected /usr/local/bin/git-remote-entire\"
  git-remote-entire --help >/dev/null 2>&1 ||
    fail \"git-remote-entire is not runnable\"

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
  grep -q 'model = \"fireworks/accounts/fireworks/models/glm-5p3-flash\"' /tmp/guard-repo/.roborev.toml ||
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
  grep -q 'model = \"fireworks/accounts/fireworks/models/glm-5p3-flash\"' /tmp/pi-install-repo/.roborev.toml ||
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

echo "=== RUN 22: entire install via stubbed curl; replay the SUM script's per-platform pin path ==="
# Issue #91 install path with the same fixture-driven pattern RUN 14 uses for
# pi: deterministic byte fixture → sha256 → patch the script's
# ENTIRE_SHA256_<PLATFORM> constant in a sandbox copy → stubbed curl
# intercepts only the entire tarball URL. The curl → sha256_verify → tar
# extract → install_bin chain runs against the fixture unchanged; only the
# per-platform constant is rewritten, so the installer's runtime checks
# stay exactly what they are in production. RUN 22 covers fresh install +
# idempotent reuse + the fail-closed branch where the fixture's integrity
# does not match a rewriting constant; RUN 22E covers the mixed state
# (entire on PATH without its companion) and the stale-binary shadow WARN.
#
# Sequence: (1) write stub binaries with a placeholder for the pin,
# (2) take the pinned pin off the LIVE script, (3) substitute the
# placeholder with that pin (so `entire version` after install reports
# it), (4) tar the result, (5) sha256 the tar, (6) patch the script's
# ENTIRE_SHA256_<CURRENT-PLATFORM> constant to match, (7) stub curl
# serves the prepped tar for the entire URL. This sequence keeps the
# integrity constant in lock-step with the served tar. RUN 22B then
# degrades the stub curl to serve the bare fixture body (no tar), whose
# sha256 matches no actual tarball — that exercises the runtime
# integrity close in both BEST_EFFORT=1 (FAIL row, exit 0) and default
# posture (FAIL row, exit 1) branches.
rm -rf /tmp/entire-install-repo /tmp/entire-install-stubs /tmp/entire-startup.sh /tmp/entire-fixture
mkdir -p /tmp/entire-install-stubs /tmp/entire-fixture
ENTIRE_FIXTURE_BODY="$(printf 'entire-tarball-fixture-bytes-issue-91-RUN22')"
printf '#!/bin/sh\necho "Entire CLI @ENTIRE_PIN@-stub"\nexit 0\n' > /tmp/entire-fixture/entire
printf '#!/bin/sh\nexit 0\n' > /tmp/entire-fixture/git-remote-entire
LIVE_ENTIRE_PIN_VALUE="$(sed -n 's/^ENTIRE_PIN="\([^"]*\)".*/\1/p' "${STARTUP_SCRIPT}")"
sed -i.bak "s|@ENTIRE_PIN@|${LIVE_ENTIRE_PIN_VALUE}|g" /tmp/entire-fixture/entire
chmod 755 /tmp/entire-fixture/entire /tmp/entire-fixture/git-remote-entire
tar -czf /tmp/entire-install-stubs/entire_fake.tar.gz -C /tmp/entire-fixture entire git-remote-entire
ENTIRE_FIXTURE_SHA256_HEX="$(sha256sum /tmp/entire-install-stubs/entire_fake.tar.gz | awk '{print $1}')"
echo "entire fixture tar sha256: ${ENTIRE_FIXTURE_SHA256_HEX}"
# Sandbox copy of the startup script with the CURRENT platform's sha256
# rewritten to match the test fixture's actual tar file. The live
# ENTIRE_SHA256_* constants stay in
# scripts/conductor-startup-script-cloud.sh; the rewrite happens ONLY on
# this /tmp copy. The pin, the runtime case branch, the install_bin call,
# and the git-remote-entire co-install all stay as the production script
# has them. Platform-generic on purpose: CI runs linux_amd64, but the
# header-documented local repro runs linux_arm64 — with a hardcoded AMD64
# sha/URL the arm64 runs would fetch the real tarball from the CDN (the
# stub never matches the arm64 URL), so the mismatch runs would exercise
# the live network with the real pin instead of the fixture.
ENTIRE_TEST_PLATFORM="linux_$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
case "${ENTIRE_TEST_PLATFORM}" in
linux_amd64 | linux_arm64) ;;
*) fail "no entire fixture platform for $(uname -s)-$(uname -m)" ;;
esac
ENTIRE_SHA_VAR="ENTIRE_SHA256_${ENTIRE_TEST_PLATFORM^^}"
sed "s|^${ENTIRE_SHA_VAR}=.*|${ENTIRE_SHA_VAR}=\"${ENTIRE_FIXTURE_SHA256_HEX}\"|" \
  "${STARTUP_SCRIPT}" > /tmp/entire-startup.sh
grep -qxF "${ENTIRE_SHA_VAR}=\"${ENTIRE_FIXTURE_SHA256_HEX}\"" /tmp/entire-startup.sh ||
  fail "${ENTIRE_SHA_VAR} patch did not apply to /tmp/entire-startup.sh"
chmod 755 /tmp/entire-startup.sh
ENTIRE_PIN_VALUE="${LIVE_ENTIRE_PIN_VALUE}"
ENTIRE_STUB_URL="https://install.entire.com/v${ENTIRE_PIN_VALUE}/entire_${ENTIRE_TEST_PLATFORM}.tar.gz"
# Stub curl with the same parser shape as RUN 14's pi stub: handles both
# the combined `-fsSLo <path>` form curl accepts in one or two args AND
# the split `-o <path>` form. The entire tarball URL yields the prepped
# tarball (so the integrity verify matches what we just rewrote, then
# `tar -xzf` succeeds); other paths fall through to the host curl so
# roborev/trunk/rwx/pi in the same script are unaffected.
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
  printf '  %s)\n' "${ENTIRE_STUB_URL}"
  printf '    if [ -n "$output" ]; then\n'
  printf '      cp /tmp/entire-install-stubs/entire_fake.tar.gz "$output"\n'
  printf '    else\n'
  printf '      cat /tmp/entire-install-stubs/entire_fake.tar.gz\n'
  printf '    fi\n'
  printf '    exit 0;;\n'
  printf '  *) exec /usr/bin/curl "$@";;\n'
  printf 'esac\n'
} > /tmp/entire-install-stubs/curl
chmod 755 /tmp/entire-install-stubs/curl
rm -f /usr/local/bin/entire /usr/local/bin/git-remote-entire
su - sandbox-user -c "git init -q /tmp/entire-install-repo"
RUN22_OUTPUT="$(su - sandbox-user -c "cd /tmp/entire-install-repo && PATH=/tmp/entire-install-stubs:/usr/local/bin:\$PATH bash /tmp/entire-startup.sh")" ||
  fail "entire-install run exited non-zero"
printf '%s' "${RUN22_OUTPUT}"
case "${RUN22_OUTPUT}" in *" | FAIL |"*) fail "entire-install run recorded FAIL row(s)" ;; esac
case "${RUN22_OUTPUT}" in *"entire | PASS"*) ;; *) fail "entire-install run missing the entire PASS row" ;;
esac
case "${RUN22_OUTPUT}" in *"entire: /usr/local/bin/entire, git-remote-entire: /usr/local/bin/git-remote-entire"*) ;; *) fail "entire-install run PASS row did not name both /usr/local/bin paths" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ -x /usr/local/bin/entire ] ||
    fail \"entire-install run did not place the entire binary under /usr/local/bin\"
  [ -x /usr/local/bin/git-remote-entire ] ||
    fail \"entire-install run did not place git-remote-entire under /usr/local/bin\"
  entire_version_out=\"\$(entire version 2>&1)\" || true
  printf '%s' \"\${entire_version_out}\" | grep -q \"Entire CLI ${ENTIRE_PIN_VALUE}\" ||
    fail \"installed entire version does not report the pin \${ENTIRE_PIN_VALUE}: \${entire_version_out}\"
" || fail "entire-install verification failed"

echo "=== RUN 22D: entire reused on idempotent re-run ==="
# Cold-install via RUN 22 left /usr/local/bin/entire and
# /usr/local/bin/git-remote-entire for sandbox-user; a re-run must take the
# reuse row for both, not re-download. This runs BEFORE the RUN 22B/22C
# mismatch runs below: those remove the binaries to force the fresh-install
# path, after which no reuse row is possible.
RUN22D_OUTPUT="$(su - sandbox-user -c "cd /tmp/entire-install-repo && PATH=/tmp/entire-install-stubs:/usr/local/bin:\$PATH bash /tmp/entire-startup.sh")" ||
  fail "entire-reuse run exited non-zero"
printf '%s' "${RUN22D_OUTPUT}"
case "${RUN22D_OUTPUT}" in *"entire | PASS | reused /usr/local/bin/entire"*) ;; *) fail "entire-reuse run missing the reused entire PASS row" ;; esac

echo "=== RUN 22B: entire integrity mismatch leaves entire uninstalled ==="
# Same fail-closed posture as the roborev/trunk/rwx tool stages: under
# STARTUP_BEST_EFFORT=1 (this repo's settings.toml contract) a FAIL row is
# recorded but the run exits 0; under the default posture the same FAIL row
# exits non-zero. RUN 22B keeps RUN 22's patched /tmp/entire-startup.sh
# (whose sha256 is the fixture-tar hash) but rewrites the stub curl to
# serve the bare fixture body string instead — that string's sha256 matches
# no actual tarball, so the runtime integrity check fails closed. Either
# branch with an installed /usr/local/bin/entire would be a regression.
# The rm runs at this outer (root) level, like RUN 16's pi cleanup:
# install_bin placed the binaries via sudo, so sandbox-user cannot remove
# them — a silently-failing rm inside the su would leave entire on PATH
# and turn the mismatch run into a reuse-row run.
rm -f /usr/local/bin/entire /usr/local/bin/git-remote-entire
rm -rf /tmp/entire-mismatch-repo
su - sandbox-user -c "git init -q /tmp/entire-mismatch-repo"
# The degraded stub lives in its own DIRECTORY so it can sit first on PATH:
# shells only search directories, so a stub file placed on PATH directly is
# never invoked and every URL silently falls through to the real curl —
# which would make this a live-network test, not a fixture-driven one.
DEGRADED_STUB_DIR="$(mktemp -d /tmp/entire-degraded-stubs.XXXXXX)"
sed "s|cp /tmp/entire-install-stubs/entire_fake.tar.gz \"\\\$output\"|printf '%s' \"${ENTIRE_FIXTURE_BODY}\" > \"\$output\"|" /tmp/entire-install-stubs/curl > "${DEGRADED_STUB_DIR}/curl"
sed -i.bak "s|cat /tmp/entire-install-stubs/entire_fake.tar.gz|printf '%s' \"${ENTIRE_FIXTURE_BODY}\"|" "${DEGRADED_STUB_DIR}/curl"
chmod 755 "${DEGRADED_STUB_DIR}/curl"
# STARTUP_BEST_EFFORT=1 goes INSIDE the -c string (RUN 6's convention):
# `su -` resets the environment, so a prefix assignment on the su command
# line never reaches the startup script.
RUN22B_OUTPUT="$(su - sandbox-user -c "cd /tmp/entire-mismatch-repo && STARTUP_BEST_EFFORT=1 PATH=${DEGRADED_STUB_DIR}:/usr/local/bin:\$PATH bash /tmp/entire-startup.sh")" ||
  fail "entire-mismatch best-effort run exited non-zero (a tool-stage failure is recorded, not fatal under BEST_EFFORT=1)"
printf '%s' "${RUN22B_OUTPUT}"
case "${RUN22B_OUTPUT}" in *"entire | FAIL | provisioning failed"*) ;; *) fail "entire-mismatch best-effort run missing the FAIL row" ;; esac
[[ ! -e /usr/local/bin/entire ]] ||
  fail "entire-mismatch best-effort run placed the entire binary in /usr/local/bin despite the integrity mismatch"
[[ ! -e /usr/local/bin/git-remote-entire ]] ||
  fail "entire-mismatch best-effort run placed git-remote-entire in /usr/local/bin despite the integrity mismatch"
# Default posture (no STARTUP_BEST_EFFORT) — the same FAIL row must fail
# the run loudly. Same patched script, same degraded stub curl.
if RUN22C_OUTPUT="$(su - sandbox-user -c "cd /tmp/entire-mismatch-repo && PATH=${DEGRADED_STUB_DIR}:/usr/local/bin:\$PATH bash /tmp/entire-startup.sh")"; then
  fail "entire-mismatch strict-posture run exited 0 — a tool-stage failure must fail setup loudly by default"
fi
case "${RUN22C_OUTPUT}" in *"entire | FAIL | provisioning failed"*) ;; *) fail "entire-mismatch strict-posture run missing the FAIL row" ;; esac
[[ ! -e /usr/local/bin/entire ]] ||
  fail "entire-mismatch strict-posture run placed the entire binary in /usr/local/bin despite the integrity mismatch"
rm -rf "${DEGRADED_STUB_DIR}"

echo "=== RUN 22E: entire without its companion falls through to the pinned install ==="
# The reuse gate requires BOTH binaries, so the mixed state — entire on
# PATH, git-remote-entire missing — must take the fresh-install path and
# place the companion, never a reuse row. The shadow sub-case then keeps a
# stale entire in ~/.local/bin (which the startup script prepends to PATH)
# and expects a WARN naming it, not a PASS over the shadowed install.
rm -f /usr/local/bin/git-remote-entire
install -m 755 /tmp/entire-fixture/entire /usr/local/bin/entire
rm -rf /tmp/entire-mixed-repo
su - sandbox-user -c "git init -q /tmp/entire-mixed-repo"
RUN22E_OUTPUT="$(su - sandbox-user -c "cd /tmp/entire-mixed-repo && PATH=/tmp/entire-install-stubs:/usr/local/bin:\$PATH bash /tmp/entire-startup.sh")" ||
  fail "entire-mixed-state run exited non-zero"
printf '%s' "${RUN22E_OUTPUT}"
case "${RUN22E_OUTPUT}" in *"entire | PASS | reused"*) fail "entire-mixed-state run took the reuse row despite the missing companion" ;; esac
case "${RUN22E_OUTPUT}" in *"entire | PASS | v${ENTIRE_PIN_VALUE} (entire: /usr/local/bin/entire, git-remote-entire: /usr/local/bin/git-remote-entire)"*) ;; *) fail "entire-mixed-state run missing the pinned install PASS row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ -x /usr/local/bin/entire ] &&
    [ -x /usr/local/bin/git-remote-entire ] ||
    fail \"entire-mixed-state run did not leave both binaries under /usr/local/bin\"
" || fail "entire-mixed-state verification failed"
# Shadow sub-case: a stale entire earlier on PATH keeps resolving after the
# pinned install; the stage must WARN and name the shadowing binary.
rm -f /usr/local/bin/git-remote-entire
su - sandbox-user -c "mkdir -p ~/.local/bin && install -m 755 /tmp/entire-fixture/entire ~/.local/bin/entire"
RUN22E2_OUTPUT="$(su - sandbox-user -c "cd /tmp/entire-mixed-repo && PATH=/tmp/entire-install-stubs:/usr/local/bin:\$PATH bash /tmp/entire-startup.sh")" ||
  fail "entire-shadowed run exited non-zero"
printf '%s' "${RUN22E2_OUTPUT}"
case "${RUN22E2_OUTPUT}" in *"entire | WARN | v${ENTIRE_PIN_VALUE} installed"*"but PATH resolves entire to /home/sandbox-user/.local/bin/entire"*) ;; *) fail "entire-shadowed run missing the WARN row naming the shadowing binary" ;; esac
case "${RUN22E2_OUTPUT}" in *" | FAIL |"*) fail "entire-shadowed run recorded FAIL row(s)" ;; esac
rm -f /home/sandbox-user/.local/bin/entire

echo "=== RUN 23: ROBOREV_AGENT=claude-code triggers the louder override WARN ==="
# Issue #101's override guard (pi_install's earlier "explicit, well-formed
# non-pi agent" branch): a claude-code or codex value used to record a
# quiet SKIP row identical to the row for a valid agent slug. The new
# guard promotes claude-code and codex to a WARN row that names the
# override and points at issue #101 + the script's pi default. Other
# slugs (opencode, gemini, ...) keep the quiet SKIP — some future
# version may actually work, and a loud WARN there would be a regression
# that scares operators away from a working agent. RUN 23 covers all
# three: claude-code loud WARN, codex loud WARN, opencode quiet SKIP.
rm -rf /tmp/pi-claude-repo /tmp/pi-codex-repo /tmp/pi-opencode-repo
rm -f /usr/local/bin/pi
su - sandbox-user -c "rm -f ~/.local/bin/pi; git init -q /tmp/pi-claude-repo"
RUN23_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-claude-repo && ROBOREV_AGENT=claude-code PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "claude-code override run exited non-zero"
printf '%s' "${RUN23_OUTPUT}"
case "${RUN23_OUTPUT}" in *" | FAIL |"*) fail "claude-code override run recorded FAIL row(s)" ;; esac
case "${RUN23_OUTPUT}" in
*"pi | WARN | ROBOREV_AGENT=claude-code points at a known-cloudsandbox-broken review agent (issue #101)"*) ;;
*) fail "claude-code override run missing the louder override WARN row" ;;
esac
# Quiet-SKIP regression: the old SKIP row must NOT leak through,
# exactly because it was easy to lose in a long summary.
case "${RUN23_OUTPUT}" in
*"pi | SKIP | ROBOREV_AGENT=claude-code selects another review agent"*) fail "claude-code override run still has the old quiet SKIP row" ;;
esac
[[ ! -e /usr/local/bin/pi ]] ||
  fail "claude-code override run installed pi in /usr/local/bin despite the override"
! su - sandbox-user -c "test -e ~/.local/bin/pi" ||
  fail "claude-code override run installed pi in ~/.local/bin despite the override"
# codex: same shape, must reach the same WARN row.
su - sandbox-user -c "git init -q /tmp/pi-codex-repo"
RUN23B_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-codex-repo && ROBOREV_AGENT=codex PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "codex override run exited non-zero"
printf '%s' "${RUN23B_OUTPUT}"
case "${RUN23B_OUTPUT}" in
*"pi | WARN | ROBOREV_AGENT=codex points at a known-cloudsandbox-broken review agent (issue #101)"*) ;;
*) fail "codex override run missing the louder override WARN row" ;;
esac
# opencode: regression — must keep the quiet SKIP forever.
su - sandbox-user -c "git init -q /tmp/pi-opencode-repo"
RUN23C_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-opencode-repo && ROBOREV_AGENT=opencode PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "opencode override run exited non-zero"
case "${RUN23C_OUTPUT}" in
*"pi | SKIP | ROBOREV_AGENT=opencode selects another review agent"*) ;;
*) fail "opencode override run missing the quiet SKIP row" ;;
esac
case "${RUN23C_OUTPUT}" in
*"pi | WARN | ROBOREV_AGENT=opencode"*) fail "opencode override run was promoted to WARN — only claude-code/codex should be promoted" ;;
esac

# RUN 23E (issue #113): with a usable FIREWORKS_API_KEY the broken
# claude-code/codex override is ignored — pi installs, the WARN stays.
rm -rf /tmp/pi-override-ignored-repo
rm -f /usr/local/bin/pi
su - sandbox-user -c "rm -f ~/.local/bin/pi; git init -q /tmp/pi-override-ignored-repo"
RUN23E_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-override-ignored-repo && ROBOREV_AGENT=claude-code FIREWORKS_API_KEY=fw-test PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "23E override-ignored run exited non-zero"
printf '%s' "${RUN23E_OUTPUT}"
case "${RUN23E_OUTPUT}" in
*"pi | WARN | ROBOREV_AGENT=claude-code is a known-cloudsandbox-broken review agent (issues #101, #113) — ignoring it and using pi"*) ;;
*) fail "23E missing the override-ignored WARN row" ;;
esac
case "${RUN23E_OUTPUT}" in
*"pi | PASS |"*) ;;
*) fail "23E did not install pi despite a usable FIREWORKS_API_KEY" ;;
esac
grep -q '^agent = "pi"' /tmp/pi-override-ignored-repo/.roborev.toml ||
  fail "23E .roborev.toml did not get agent = pi"

# RUN 23D: the tailored-WARN branch — pi is already installed from a
# prior run, so the override's WARN must NOT say "pi is not installed"
# (issue #101 followup finding: the original message was misleading on
# re-run scenarios where pi is in place and reviews still work via the
# committed .roborev.toml agent line).
rm -rf /tmp/pi-already-installed-repo
su - sandbox-user -c "git init -q /tmp/pi-already-installed-repo"
# Pre-step: install pi via the default-agent path so it exists on PATH.
# This is the natural sequence: first setup with no override installs pi
# and writes .roborev.toml with agent = "pi"; later the operator sets
# ROBOREV_AGENT=claude-code to evaluate the override without disturbing
# the working config.
RUN23D_PRE_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-already-installed-repo && PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "23D pre-install run exited non-zero"
case "${RUN23D_PRE_OUTPUT}" in *"pi | PASS"*) ;; *) fail "23D pre-install run did not install pi" ;; esac
# The override re-run with pi in place. The tailored WARN row must fire
# (override is still a known-broken-in-sandboxes agent) but it must NOT
# claim pi is uninstalled — that is the regression a re-run produces
# against the original "pi is not installed" wording.
RUN23D_OUTPUT="$(su - sandbox-user -c "cd /tmp/pi-already-installed-repo && ROBOREV_AGENT=claude-code PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "23D tailored-WARN run exited non-zero"
printf '%s' "${RUN23D_OUTPUT}"
case "${RUN23D_OUTPUT}" in
*"pi | WARN | ROBOREV_AGENT=claude-code is a known-cloudsandbox-broken review agent (issue #101): pi is already installed"*) ;;
*) fail "23D tailored-WARN run missing the 'pi is already installed' branch of the override WARN — the misleading 'pi is not installed' wording on a re-run hides a working config" ;;
esac
# The misleading 'pi is not installed' wording must NOT appear when pi
# is on PATH. It is, however, semantically correct on the fresh-install
# branch — RUN 23 above is the canonical example and is the target
# shape this negative assertion protects against leaking through the
# tailored branch.
case "${RUN23D_OUTPUT}" in
*"pi is not installed, reviews will not run"*) fail "23D tailored-WARN run fell through to the 'pi is not installed' branch despite pi being installed on PATH" ;;
esac
# The neutral wording must NOT falsely claim reviews are live in this
# workspace — pi_install cannot observe whether a committed agent = "pi"
# .roborev.toml exists, and pretending otherwise directs the operator
# away from a fresh-repo failure mode that the override would actually
# trigger (it's the same misleading-row class the tailored branch was
# written to fix, just with a different agent line).
case "${RUN23D_OUTPUT}" in
*"keeps reviews live in this workspace"*) fail "23D tailored-WARN run still claims reviews are live in this workspace — the claim depends on a committed agent = \"pi\" .roborev.toml that pi_install cannot observe" ;;
esac

echo "=== RUN 24: \$HOME/<repo>/.git auto-discovery runs the full roborev stage ==="
# Issue #101's first-class fix: Conductor cloud sandboxes run setup
# from $HOME, NOT from inside the cloned repo, so without auto-
# discovery the roborev stage silently SKIPs and a fresh workspace
# comes up with no .roborev.toml + no agent smoke check + no hook
# posture. The script's new find_repo_root discovers a single worktree
# directly under $HOME (the path Conductor clones into) and cd's into
# it. We rebuild the calling pattern here: cwd outside any worktree,
# HOME pointing at a directory holding exactly one .git, full pinned
# pi-install path so .roborev.toml gets the same effective writes
# RUN 14 already exercises.
rm -rf /tmp/find-repo-home
su - sandbox-user -c "
  set -e
  mkdir -p /tmp/find-repo-home
  cd /tmp/find-repo-home
  git init -q repo
  cd repo
  git config user.email t@t
  git config user.name t
  echo init > README && git add README && git commit -q -m init
"
# Two worktrees in $HOME is ambiguous; build a SECOND empty worktree
# elsewhere to verify find_repo_root returns 1 in that case. RUN 24B
# covers it — building the ambiguity shape alongside the structural
# shape so the safety isn't "by code review" only.
rm -rf /tmp/find-repo-home-ambiguous
su - sandbox-user -c "
  set -e
  mkdir -p /tmp/find-repo-home-ambiguous
  cd /tmp/find-repo-home-ambiguous
  git init -q repo-a
  cd repo-a
  git config user.email t@t; git config user.name t
  echo init > README && git add README && git commit -q -m init
  cd /tmp/find-repo-home-ambiguous
  git init -q repo-b
  cd repo-b
  echo init > README
"
RUN24_OUTPUT="$(su - sandbox-user -c "cd /tmp && HOME=/tmp/find-repo-home PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "find-repo run exited non-zero"
printf '%s' "${RUN24_OUTPUT}"
case "${RUN24_OUTPUT}" in *" | FAIL |"*) fail "find-repo run recorded FAIL row(s)" ;; esac
# The .roborev.toml-write row inside the DISCOVERED repo proves we
# cd'd into it — RUN 14's same row text confirms the script wrote
# everything the with-worktree-from-cwd path would have.
case "${RUN24_OUTPUT}" in
*".roborev.toml written (agent: pi, model: fireworks/accounts/fireworks/models/glm-5p3-flash)"*) ;;
*) fail "find-repo run missing the .roborev.toml-written row in the discovered repo" ;;
esac
# The hook posture row must show too (PASS on a brand-new repo) —
# its presence means the cd'd-into-discovered-repo state propagated
# past the toml write, the way the with-cwd-as-worktree path does.
case "${RUN24_OUTPUT}" in *"roborev-hook | PASS"*) ;; *) fail "find-repo run missing the roborev-hook row — discovery did not cd into the worktree" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ -f /tmp/find-repo-home/repo/.roborev.toml ] ||
    fail \"auto-discovery did not write .roborev.toml inside the discovered repo (cwd was /tmp — .roborev.toml.tmp cleanup would have masked it, but a missing file proves find_repo_root did not fire)\"
  grep -q 'agent = \"pi\"' /tmp/find-repo-home/repo/.roborev.toml ||
    fail \"auto-discovery wrote .roborev.toml without the agent line\"
  grep -q 'model = \"fireworks/accounts/fireworks/models/glm-5p3-flash\"' /tmp/find-repo-home/repo/.roborev.toml ||
    fail \"auto-discovery wrote .roborev.toml without the Fireworks model line\"
" || fail "find-repo verification failed"
# Two worktrees at the top: ambiguity, find_repo_root must return 1
# and the script's no-worktree fallback (RUN 25 below) must fire.
RUN24B_OUTPUT="$(su - sandbox-user -c "cd /tmp && HOME=/tmp/find-repo-home-ambiguous PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "ambiguous-home run exited non-zero"
case "${RUN24B_OUTPUT}" in *" | FAIL |"*) fail "ambiguous-home run recorded FAIL row(s)" ;; esac
case "${RUN24B_OUTPUT}" in
*"roborev-config | WARN | cwd is not a git worktree and no repo found via CONDUCTOR_WORKSPACE_PATH or \$HOME"*) ;;
*) fail "ambiguous-home run missing the no-worktree WARN row — find_repo_root failed open instead of refusing" ;;
esac
case "${RUN24B_OUTPUT}" in *".roborev.toml written"*) fail "ambiguous-home run wrote .roborev.toml — find_repo_root picked a wrong repo" ;; esac

# RUN 24C: CONDUCTOR_WORKSPACE_PATH takes precedence over the $HOME scan.
# find_repo_root's primary resolution path (the commit message's first
# bullet) gives Conductor's install-script env var precedence over the
# $HOME/* scan so operators can point at an explicit path. Both the
# straightforward case and the precedence case need coverage: a regression
# in this branch — a typo in the env-var name, broken precedence, or
# git-C resolving to a subdirectory — would pass CI silently while
# breaking the Conductor-cloud machines this commit was written to fix.
# Case 24C1: CONDUCTOR_WORKSPACE_PATH set, no $HOME worktree.
rm -rf /tmp/cwp-workspace /tmp/cwp-empty-home
su - sandbox-user -c "
  set -e
  mkdir -p /tmp/cwp-workspace
  cd /tmp/cwp-workspace
  git init -q repo
  cd repo
  git config user.email t@t; git config user.name t
  echo init > README && git add README && git commit -q -m init
  mkdir -p /tmp/cwp-empty-home
"
RUN24C1_OUTPUT="$(su - sandbox-user -c "cd /tmp && HOME=/tmp/cwp-empty-home CONDUCTOR_WORKSPACE_PATH=/tmp/cwp-workspace/repo PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "cwp-straight run exited non-zero"
case "${RUN24C1_OUTPUT}" in
*".roborev.toml written (agent: pi, model: fireworks/accounts/fireworks/models/glm-5p3-flash)"*) ;;
*) fail "cwp-straight run missing the .roborev.toml-written row — CONDUCTOR_WORKSPACE_PATH was not used" ;;
esac
[ -f /tmp/cwp-workspace/repo/.roborev.toml ] ||
  fail "cwp-straight run did not write .roborev.toml into the CONDUCTOR_WORKSPACE_PATH repo"
# Case 24C2: CONDUCTOR_WORKSPACE_PATH and a different $HOME worktree;
# the env var must win. Without precedence the script would pick either
# arbitrarily, so a regression in the resolution order would land the
# wrong repo's .roborev.toml silently.
rm -rf /tmp/cwp-precedence
su - sandbox-user -c "
  set -e
  mkdir -p /tmp/cwp-precedence/ws
  cd /tmp/cwp-precedence/ws
  git config --global --unset user.email 2>/dev/null || true
  git config --global --unset user.name 2>/dev/null || true
  git init -q
  git config user.email t@t; git config user.name t
  echo init > README && git add README && git commit -q -m init
  mkdir -p /tmp/cwp-precedence/home-elsewhere/repo
  cd /tmp/cwp-precedence/home-elsewhere/repo
  git config --global --unset user.email 2>/dev/null || true
  git config --global --unset user.name 2>/dev/null || true
  git init -q
  echo init > README
"
RUN24C2_OUTPUT="$(su - sandbox-user -c "cd /tmp && HOME=/tmp/cwp-precedence/home-elsewhere CONDUCTOR_WORKSPACE_PATH=/tmp/cwp-precedence/ws PATH=/tmp/pi-install-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "cwp-precedence run exited non-zero"
printf '%s' "${RUN24C2_OUTPUT}"
case "${RUN24C2_OUTPUT}" in *" | FAIL |"*) fail "cwp-precedence run recorded FAIL row(s)" ;; esac
case "${RUN24C2_OUTPUT}" in
*".roborev.toml written (agent: pi, model: fireworks/accounts/fireworks/models/glm-5p3-flash)"*) ;;
*) fail "cwp-precedence run missing the .roborev.toml-written row — CONDUCTOR_WORKSPACE_PATH was not used" ;;
esac
[ -f /tmp/cwp-precedence/ws/.roborev.toml ] ||
  fail "cwp-precedence run did not write .roborev.toml into CONDUCTOR_WORKSPACE_PATH — the setup scanned for \$HOME repos and either failed open or picked the wrong one"
[ ! -f /tmp/cwp-precedence/home-elsewhere/repo/.roborev.toml ] ||
  fail "cwp-precedence run wrote .roborev.toml into the \$HOME repo — env var lost the precedence test"

echo "=== RUN 25: no-worktree fallback records the loud WARN + still runs daemon + smoke ==="
# Issue #101's no-worktree fallback: find_repo_root returns 1 when
# neither CONDUCTOR_WORKSPACE_PATH nor a single worktree resolves.
# The roborev stage records a single loud WARN naming the gap and
# falls through to daemon + smoke check only — those parts never
# needed a repo root. RUN 25 uses a stubs-only env so the smoke check
# passes; the loud WARN + smoke-PASS row pair is the basic fallback
# contract. RUN 25B drives the branch the smoke-check helper got for
# the no-worktree case: when the agent is pi AND there is no
# .roborev.toml, fireworks_model defaults to 1 and the WARN row points
# at FIREWORKS_API_KEY rather than a generic "agent failed" — the
# hint the with-worktree path gives, applied to a setup that couldn't
# write a .roborev.toml in the first place.
rm -rf /tmp/nowork-home
su - sandbox-user -c "mkdir -p /tmp/nowork-home"
# Stub a smoke-passing roborev in its own dir so the run-by-run shape
# stays isolated from RUN 14's stubs (RUN 25B repoints check-agents to
# exit 1 from a fresh stubs dir, not by mutating shared stubs).
rm -rf /tmp/nowork-stubs
mkdir -p /tmp/nowork-stubs
cp -r /tmp/pi-install-stubs/. /tmp/nowork-stubs/
printf '#!/bin/sh\necho v22.19.0\n' > /tmp/nowork-stubs/node
chmod 755 /tmp/nowork-stubs/node /tmp/nowork-stubs/roborev /tmp/nowork-stubs/npm /tmp/nowork-stubs/sudo /tmp/nowork-stubs/curl
RUN25_OUTPUT="$(su - sandbox-user -c "cd /tmp && HOME=/tmp/nowork-home PATH=/tmp/nowork-stubs:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "no-worktree run exited non-zero"
printf '%s' "${RUN25_OUTPUT}"
case "${RUN25_OUTPUT}" in *" | FAIL |"*) fail "no-worktree run recorded FAIL row(s)" ;; esac
# The loud WARN that names issue #101 and the gap.
case "${RUN25_OUTPUT}" in
*"roborev-config | WARN | cwd is not a git worktree and no repo found via CONDUCTOR_WORKSPACE_PATH or \$HOME"*) ;;
*) fail "no-worktree run missing the loud no-worktree WARN row" ;;
esac
# Daemon + smoke both ran in the fallback path (the parts that don't
# need a worktree).
case "${RUN25_OUTPUT}" in *"roborev-daemon | PASS"*) ;; *) fail "no-worktree run missing the roborev-daemon PASS row" ;; esac
case "${RUN25_OUTPUT}" in *"roborev-agent | PASS"*) ;; *) fail "no-worktree run missing the roborev-agent PASS row" ;; esac
# And the things that DO need a worktree must NOT have run.
case "${RUN25_OUTPUT}" in *".roborev.toml written"*) fail "no-worktree run wrote .roborev.toml despite no worktree" ;; esac
case "${RUN25_OUTPUT}" in *"roborev-hook |"*) fail "no-worktree run recorded a roborev-hook row despite no worktree" ;; esac
# The PASS row must reflect the no-toml reality (roborev reads the
# config from disk — without a written .roborev.toml reviews don't run
# end-to-end) and must NOT carry the old "reviews are live" overclaim
# the with-worktree path makes. RUN 25's no-worktree falling shape locks
# the new wording against a regression that flips has_toml back to
# silent — same overclaim class commit 244b3bf removed from pi_install.
case "${RUN25_OUTPUT}" in
*"pi answered a smoke prompt; no .roborev.toml was written this run, so reviews won't run end-to-end here"*) ;;
*) fail "no-worktree PASS row missing the no-.roborev.toml-tail wording" ;;
esac
case "${RUN25_OUTPUT}" in
*"roborev-agent | PASS | pi answered a smoke prompt — reviews are live"*) fail "no-worktree PASS row carried the with-worktree 'reviews are live' overclaim" ;;
esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ -z \"\$(find /tmp/nowork-home -name .roborev.toml 2>/dev/null)\" ] ||
    fail \"no-worktree run created a .roborev.toml somewhere under \$HOME\"
" || fail "no-worktree verification failed"
# RUN 25B: smoke FAIL + unset FIREWORKS_API_KEY = no-worktree fallback
# must give the FIREWORKS-key WARN, not the generic one. Without issue
# #101's `elif [[ "\${agent}" == "pi" ]]` fallback the helper reports
# the generic "agent failed" message and an operator could lose hours
# chasing a phantom smoke failure instead of pointing at the missing
# env var.
rm -rf /tmp/nowork-stubs-fail
mkdir -p /tmp/nowork-stubs-fail
cp -r /tmp/nowork-stubs/. /tmp/nowork-stubs-fail/
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; status) exit 0;; daemon) exit 0;; check-agents) exit 1;; uninstall-hook|init|install-hook) echo "stub: $1 must never be called" >&2; exit 1;; esac\nexit 0\n' > /tmp/nowork-stubs-fail/roborev
chmod 755 /tmp/nowork-stubs-fail/roborev
RUN25B_OUTPUT="$(su - sandbox-user -c "cd /tmp && unset FIREWORKS_API_KEY ROBOREV_MODEL && HOME=/tmp/nowork-home PATH=/tmp/nowork-stubs-fail:/usr/local/bin:\$PATH bash /tmp/local-startup.sh")" ||
  fail "no-worktree-fireworks-key run exited non-zero"
printf '%s' "${RUN25B_OUTPUT}"
case "${RUN25B_OUTPUT}" in
*"roborev-agent | WARN | pi smoke failed and FIREWORKS_API_KEY is unset"*) ;;
*) fail "no-worktree-fireworks-key run missing the FIREWORKS_API_KEY smoke WARN row — helper's no-.roborev.toml fireworks_model fallback did not fire" ;;
esac
# Negative: the generic WARN must NOT leak through here.
case "${RUN25B_OUTPUT}" in
*"roborev-agent | WARN | pi failed its smoke check"*) fail "no-worktree-fireworks-key run fell through to the generic smoke WARN row" ;;
esac

# RUN 26 (issue #98): daemon isolation. The default roborev address
# 127.0.0.1:7373 is machine-global, so every sandbox must get its own unix
# socket via server_addr in its HOME's global config. Reuses the RUN 25B
# stubs (ensure_daemon runs on the no-worktree path) with a fresh HOME.
rm -rf /tmp/isolate-home
su - sandbox-user -c "mkdir -p /tmp/isolate-home"
for pass in 1 2; do
  su - sandbox-user -c "cd /tmp && unset ROBOREV_MODEL && HOME=/tmp/isolate-home PATH=/tmp/nowork-stubs-fail:/usr/local/bin:\$PATH bash /tmp/local-startup.sh" >/dev/null ||
    fail "daemon-isolation run ${pass} exited non-zero"
done
ISOLATE_CFG=/tmp/isolate-home/.roborev/config.toml
[[ -f "${ISOLATE_CFG}" ]] || fail "daemon isolation did not write ${ISOLATE_CFG}"
[[ "$(grep -c '^server_addr = "unix:///tmp/isolate-home/\.roborev/run/d\.sock"$' "${ISOLATE_CFG}")" == 1 ]] ||
  fail "expected exactly one unix-socket server_addr after two runs, got: $(cat "${ISOLATE_CFG}")"
# A pre-set server_addr must never be overridden.
printf 'server_addr = "127.0.0.1:9999"\n' > "${ISOLATE_CFG}"
su - sandbox-user -c "cd /tmp && unset ROBOREV_MODEL && HOME=/tmp/isolate-home PATH=/tmp/nowork-stubs-fail:/usr/local/bin:\$PATH bash /tmp/local-startup.sh" >/dev/null ||
  fail "daemon-isolation preset run exited non-zero"
[[ "$(cat "${ISOLATE_CFG}")" == 'server_addr = "127.0.0.1:9999"' ]] ||
  fail "daemon isolation overwrote a pre-set server_addr: $(cat "${ISOLATE_CFG}")"

# --- RUN 27-31 (issues #98/#118): socket-dir placement + daemon failures ---
SU_RUN() { # SU_RUN <home> <stubdir> -> runs the startup script, prints output
  su - sandbox-user -c "cd /tmp && unset ROBOREV_MODEL && HOME=$1 PATH=$2:/usr/local/bin:\$PATH bash /tmp/local-startup.sh" 2>&1
}
ISO_FN=/tmp/isolate-fn.sh
sed -n '/^roborev_isolate_daemon() {/,/^}/p' scripts/conductor-startup-script-cloud.sh > "${ISO_FN}"
[[ -s "${ISO_FN}" ]] || fail "could not extract roborev_isolate_daemon"
chmod 755 "${ISO_FN}"

# RUN 27: a stale unix:///tmp/ server_addr from an older setup (rejected by
# roborev when /tmp is 777, issue #118) is migrated; unrelated config lines
# survive; the socket dir is 0700 under HOME, never /tmp.
chmod 777 /tmp
rm -rf /tmp/stale-home; su - sandbox-user -c "mkdir -p /tmp/stale-home/.roborev"
printf 'foo = "bar"\nserver_addr = "unix:///tmp/roborev-1000-123.sock"\n[x]\ny = 1\n' > /tmp/stale-home/.roborev/config.toml
chown -R sandbox-user /tmp/stale-home
SU_RUN /tmp/stale-home /tmp/nowork-stubs-fail >/dev/null || fail "stale-migration run exited non-zero"
STALE_CFG=/tmp/stale-home/.roborev/config.toml
grep -q 'roborev-1000-123' "${STALE_CFG}" && fail "stale /tmp socket address not removed: $(cat "${STALE_CFG}")"
[[ "$(grep -c '^server_addr = "unix:///tmp/stale-home/\.roborev/run/d\.sock"$' "${STALE_CFG}")" == 1 ]] || fail "migrated server_addr wrong: $(cat "${STALE_CFG}")"
if ! { grep -q '^foo = "bar"$' "${STALE_CFG}" && grep -q '^y = 1$' "${STALE_CFG}"; }; then
  fail "migration dropped unrelated config lines: $(cat "${STALE_CFG}")"
fi
[[ "$(stat -c %a /tmp/stale-home/.roborev/run)" == 700 ]] || fail "socket dir is not 0700"
# A non-/tmp unix server_addr and a TCP one must both be left alone.
printf 'server_addr = "unix:///var/run/custom.sock"\n' > "${STALE_CFG}"
SU_RUN /tmp/stale-home /tmp/nowork-stubs-fail >/dev/null || fail "custom-unix run exited non-zero"
[[ "$(cat "${STALE_CFG}")" == 'server_addr = "unix:///var/run/custom.sock"' ]] || fail "custom unix server_addr was modified"

# RUN 28: two sandboxes (distinct HOMEs) never share a socket.
for h in iso-a iso-b; do rm -rf /tmp/${h}; su - sandbox-user -c "mkdir -p /tmp/${h}"; SU_RUN /tmp/${h} /tmp/nowork-stubs-fail >/dev/null || fail "${h} run failed"; done
A="$(grep '^server_addr' /tmp/iso-a/.roborev/config.toml)"; B="$(grep '^server_addr' /tmp/iso-b/.roborev/config.toml)"
[[ -n "${A}" && -n "${B}" && "${A}" != "${B}" ]] || fail "sandboxes share a socket: '${A}' vs '${B}'"

# RUN 29: over-long HOME (unix socket paths cap at ~104 bytes) falls back
# to a short 0700 dir, still not world-accessible.
LONGH="/tmp/$(printf 'l%.0s' $(seq 1 90))"
rm -rf "${LONGH}"; su - sandbox-user -c "mkdir -p ${LONGH}"
su - sandbox-user -c "HOME=${LONGH} bash -c '. ${ISO_FN}; roborev_isolate_daemon'" || fail "long-HOME isolate failed"
LSOCK="$(sed -n 's/^server_addr = "unix:\/\/\(.*\)"$/\1/p' "${LONGH}/.roborev/config.toml")"
[[ -n "${LSOCK}" && ${#LSOCK} -le 100 ]] || fail "long-HOME socket path missing or too long (${#LSOCK}): ${LSOCK}"
[[ "$(stat -c %a "$(dirname "${LSOCK}")")" == 700 ]] || fail "long-HOME fallback socket dir is not 0700"

# RUN 30: when the daemon can't start, the FAIL row carries the real
# `daemon run` error instead of just a generic start failure (issue #118).
rm -rf /tmp/nowork-stubs-dead; mkdir -p /tmp/nowork-stubs-dead; cp -r /tmp/nowork-stubs/. /tmp/nowork-stubs-dead/
# shellcheck disable=SC2016 # $1/$2 are for the stub's shell, not ours
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; status) exit 1;; daemon) if [ "$2" = run ]; then echo "Error: socket directory /tmp has unsafe permissions 777" >&2; fi; exit 1;; check-agents) exit 1;; esac\nexit 0\n' > /tmp/nowork-stubs-dead/roborev
chmod 755 /tmp/nowork-stubs-dead/roborev
rm -rf /tmp/dead-home; su - sandbox-user -c "mkdir -p /tmp/dead-home"
DEAD_OUT="$(SU_RUN /tmp/dead-home /tmp/nowork-stubs-dead || true)"
case "${DEAD_OUT}" in
*"roborev-daemon | FAIL | daemon not running and 'roborev daemon start' failed — daemon run says: Error: socket directory /tmp has unsafe permissions 777"*) ;;
*) printf '%s\n' "${DEAD_OUT}" | grep roborev-daemon; fail "daemon FAIL row lacks the 'daemon run' error" ;;
esac

# RUN 31: REAL roborev binary (installed by RUN 1) with /tmp at 777 — the
# actual #118 environment. Old behavior (unix:///tmp socket) must fail, the
# script's behavior must bring up a healthy daemon, and nothing may bind the
# machine-global TCP 7373. The `roborev-daemon | PASS` row alone proves
# little: real `roborev status` exits 0 even when it prints "Daemon: not
# running" (verified on v0.63.0 with the old unix:///tmp layout under a 777
# /tmp), so `Health: OK` and the private socket are the real assertions.
REAL=/usr/local/bin/roborev
if [[ -x "${REAL}" ]] && "${REAL}" version 2>&1 | grep -qv stub; then
  chmod 777 /tmp
  rm -rf /tmp/real-old /tmp/real-new; su - sandbox-user -c "mkdir -p /tmp/real-old/.roborev /tmp/real-new"
  printf 'server_addr = "unix:///tmp/roborev-1000-9.sock"\n' > /tmp/real-old/.roborev/config.toml; chown -R sandbox-user /tmp/real-old
  OLD_ERR="$(su - sandbox-user -c "HOME=/tmp/real-old timeout 8 ${REAL} daemon run 2>&1" || true)"
  case "${OLD_ERR}" in *"unsafe permissions 777"*) ;; *) fail "real roborev no longer rejects a /tmp socket with 777 /tmp (premise changed): ${OLD_ERR}" ;; esac
  REAL_OUT="$(su - sandbox-user -c "cd /tmp && unset ROBOREV_MODEL && HOME=/tmp/real-new PATH=/usr/local/bin:\$PATH bash /tmp/local-startup.sh" 2>&1 || true)"
  case "${REAL_OUT}" in *"roborev-daemon | PASS"*) ;; *) printf '%s\n' "${REAL_OUT}" | grep roborev; fail "real roborev daemon did not come up under 777 /tmp" ;; esac
  su - sandbox-user -c "HOME=/tmp/real-new ${REAL} status" 2>&1 | grep -q 'Health: OK' || fail "real daemon unhealthy"
  [[ -S /tmp/real-new/.roborev/run/d.sock ]] || fail "real daemon socket missing at the private path"
  if (exec 3<>/dev/tcp/127.0.0.1/7373) 2>/dev/null; then fail "something is listening on machine-global 127.0.0.1:7373"; fi
  su - sandbox-user -c "HOME=/tmp/real-new ${REAL} daemon stop" >/dev/null 2>&1 || true
  # NOT `roborev status` here: in v0.63.0 it auto-starts a daemon when none
  # is running, so it can't tell "stopped" from "revived". The private socket
  # vanishing is the observable signal that the daemon is gone.
  for _ in 1 2 3 4 5; do [[ -S /tmp/real-new/.roborev/run/d.sock ]] || break; sleep 1; done
  [[ ! -S /tmp/real-new/.roborev/run/d.sock ]] || fail "RUN 31 left a real roborev daemon running after 'daemon stop'"
else
  echo "RUN 31 SKIPPED: real roborev not at ${REAL}"
fi
chmod 1777 /tmp # RUN 27-31 widened it to 777; restore the stock mode

# RUN 32: real `roborev status` exits 0 while printing "Daemon: not running"
# (v0.63.0). That must not count as running: with start failing it is a FAIL
# row carrying the `daemon run` error, and with start working it is "revived".
rm -rf /tmp/nowork-stubs-lie; mkdir -p /tmp/nowork-stubs-lie; cp -r /tmp/nowork-stubs/. /tmp/nowork-stubs-lie/
# shellcheck disable=SC2016 # $1/$2 are for the stub's shell, not ours
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; status) echo "Daemon: not running"; exit 0;; daemon) if [ "$2" = run ]; then echo "Error: socket directory /tmp has unsafe permissions 777" >&2; fi; exit 1;; check-agents) exit 1;; esac\nexit 0\n' > /tmp/nowork-stubs-lie/roborev
chmod 755 /tmp/nowork-stubs-lie/roborev
rm -rf /tmp/lie-home; su - sandbox-user -c "mkdir -p /tmp/lie-home"
LIE_OUT="$(SU_RUN /tmp/lie-home /tmp/nowork-stubs-lie || true)"
case "${LIE_OUT}" in
*"roborev-daemon | FAIL | daemon not running and 'roborev daemon start' failed — daemon run says: Error: socket directory /tmp"*) ;;
*) printf '%s\n' "${LIE_OUT}" | grep roborev-daemon; fail "status exit 0 + 'not running' was treated as a running daemon" ;;
esac
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in version) echo "roborev v0.63.0-stub"; exit 0;; status) echo "Daemon: not running"; exit 0;; daemon) exit 0;; check-agents) exit 1;; esac\nexit 0\n' > /tmp/nowork-stubs-lie/roborev
LIE2_OUT="$(SU_RUN /tmp/lie-home /tmp/nowork-stubs-lie || true)"
case "${LIE2_OUT}" in
*"roborev-daemon | PASS | daemon revived"*) ;;
*) printf '%s\n' "${LIE2_OUT}" | grep roborev-daemon; fail "'not running' status with working start was not 'daemon revived'" ;;
esac

echo "=== ALL CHECKS PASSED ==="
