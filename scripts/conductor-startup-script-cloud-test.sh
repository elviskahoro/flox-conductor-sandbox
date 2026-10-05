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
#   - RUN 13/14 (issue #40 Workstream A): STARTUP_FLOX_ENV=1 on the real
#     target class — RUN 13 does the REAL stable-channel rpm install as
#     the non-root sudo user (plus /dev/fd, the hand-started nix-daemon,
#     and the ~/.bashrc self-heal guard, all asserted post-run) and proves
#     the no-token misconfiguration FAILs loudly with the activation SKIP
#     row; RUN 14 re-runs under STARTUP_BEST_EFFORT=1 from a git repo
#     WITH a committed .flox env and asserts the bootstrap reuse row, the
#     same token FAIL, the token-gated activation SKIP (never an
#     unauthenticated activation attempt), and that best-effort does NOT
#     shield a requested stage (the RUN 10 mirror).
#   - RUN 15 (issue #40): the token and activation PASS paths with flox
#     STUBBED (the RUN 3/4 discipline: the script's own wiring under
#     test, not the tool) — FLOXHUB_TOKEN arrives via the host repo's
#     .env.local (the row must name the file), the stub's auth acceptance
#     yields the token PASS, the stub's activate materializes the run bin
#     dir the stage must find and report, and the stub token value must
#     never appear in the output (never-echoed, asserted mechanically).
#   - RUN 16/17 (issue #40 Workstream B): STARTUP_TRUNK_MERGE_AUTH=1 —
#     RUN 16 proves a malformed TRUNK_USER_YAML (no trunk_user key) FAILs
#     loudly with nothing installed; RUN 17 provisions through the
#     .env.local channel and asserts the file contract (0600 in a 0700
#     dir, byte-exact content) and the no-clobber re-run row.
#   - RUN 18 (issue #40): the dual-home drift guard — the wired stage and
#     scripts/trunk-merge-auth.sh (the by-hand form of the same recipe)
#     must install byte-identical files for the same input.
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
# The issue #40 gates, same discipline: flag-off runs must record both
# gate SKIP rows — the paste surface stays exactly what it was before
# those stages existed.
case "${RUN1_OUTPUT}" in *"flox-bootstrap | SKIP"*) ;; *) fail "fresh run missing the flox-bootstrap gate SKIP row" ;; esac
case "${RUN1_OUTPUT}" in *"trunk-merge-auth | SKIP"*) ;; *) fail "fresh run missing the trunk-merge-auth gate SKIP row" ;; esac

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
  grep -q 'agent = \"claude-code\"' /tmp/guard-repo/.roborev.toml ||
    fail \".roborev.toml is missing the agent line\"
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
rm -rf /tmp/agent-repo /tmp/agent-repo2 /tmp/roborev-stub4
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
  grep -q 'agent = \"claude-code\"' /tmp/agent-repo/.roborev.toml ||
    fail \"malformed ROBOREV_AGENT did not fall back to the default agent in .roborev.toml\"
" || fail "malformed-agent verification failed"
su - sandbox-user -c "git init -q /tmp/agent-repo2"
RUN3D2_OUTPUT="$(su - sandbox-user -c "cd /tmp/agent-repo2 && PATH=/tmp/roborev-stub4:\$PATH ROBOREV_AGENT=pi bash ${STARTUP_SCRIPT}")" ||
  fail "custom-agent run exited non-zero"
printf '%s' "${RUN3D2_OUTPUT}"
case "${RUN3D2_OUTPUT}" in
*" | FAIL |"*) fail "custom-agent run recorded FAIL row(s)" ;;
esac
case "${RUN3D2_OUTPUT}" in *".roborev.toml written (agent: pi)"*) ;; *) fail "custom-agent run missing the agent-pi PASS row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  grep -q 'agent = \"pi\"' /tmp/agent-repo2/.roborev.toml ||
    fail \"valid custom ROBOREV_AGENT=pi did not land in .roborev.toml\"
" || fail "custom-agent verification failed"

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

echo "=== RUN 13: flox bootstrap (STARTUP_FLOX_ENV=1, real rpm install, no token) ==="
# issue #40 Workstream A on the real target class: a flag-on run with NO
# FLOXHUB_TOKEN and no Infisical identity must (a) really install flox via
# the stable-channel rpm with sudo as the non-root sandbox user, create
# /dev/fd, hand-start the nix-daemon, and write the ~/.bashrc self-heal
# guard — and (b) FAIL loudly (exit non-zero, the requested-surface
# contract) at the token stage, with the activation stage taking its SKIP
# row (non-git cwd here), never attempting an unauthenticated activation.
if RUN13_OUTPUT="$(su - sandbox-user -c "cd /tmp && STARTUP_FLOX_ENV=1 bash ${STARTUP_SCRIPT}")"; then
  fail "no-token flox run exited 0 in default mode — a requested stage that cannot be provisioned must fail loudly"
fi
printf '%s\n' "${RUN13_OUTPUT}"
case "${RUN13_OUTPUT}" in *"flox-bootstrap | PASS"*) ;; *) fail "flox run missing the flox-bootstrap PASS row" ;; esac
case "${RUN13_OUTPUT}" in *"stable-channel rpm (dnf)"*) ;; *) fail "flox-bootstrap PASS row does not record the rpm install" ;; esac
case "${RUN13_OUTPUT}" in *"floxhub-token | FAIL"*) ;; *) fail "flox run missing the floxhub-token FAIL row" ;; esac
case "${RUN13_OUTPUT}" in *"FLOXHUB_TOKEN not set"*) ;; *) fail "floxhub-token FAIL row does not carry the setup instructions" ;; esac
case "${RUN13_OUTPUT}" in *"flox-activate | SKIP"*) ;; *) fail "flox run missing the flox-activate SKIP row" ;; esac
case "${RUN13_OUTPUT}" in *"not a git worktree"*) ;; *) fail "flox-activate SKIP row does not name the non-git reason" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  command -v flox >/dev/null 2>&1 ||
    fail \"flox is not on PATH after the bootstrap\"
  flox --version >/dev/null 2>&1 ||
    fail \"flox --version failed after the bootstrap: \$(flox --version 2>&1)\"
  [ -e /dev/fd ] ||
    fail \"/dev/fd was not created\"
  [ -S /nix/var/nix/daemon-socket/socket ] ||
    fail \"nix-daemon socket is not up after the hand-start\"
  grep -q 'nix-daemon --daemon' ~/.bashrc ||
    fail \"the nix-daemon self-heal guard is not in ~/.bashrc\"
" || fail "flox bootstrap verification failed"

echo "=== RUN 14: flox reuse + token-gated SKIP under STARTUP_BEST_EFFORT=1 ==="
# Idempotence plus the misconfiguration contracts: the bootstrap must
# REUSE the RUN 13 install (a re-download would pass the FAIL checks
# unnoticed — the RUN 2 reuse discipline), the token stage must still
# FAIL, the activation stage must SKIP on the missing token even though
# the host repo HAS a committed .flox env (the gate that must never
# attempt an unauthenticated activation), and STARTUP_BEST_EFFORT=1 must
# NOT shield any of it — a requested stage stays fatal (the RUN 10
# mirror, for the flox workstream).
rm -rf /tmp/flox-repo
su - sandbox-user -c "git init -q /tmp/flox-repo && mkdir -p /tmp/flox-repo/.flox/env"
su - sandbox-user -c "printf '[env]\nname = \"flox-repo\"\n' > /tmp/flox-repo/.flox/env/manifest.toml"
if RUN14_OUTPUT="$(su - sandbox-user -c "cd /tmp/flox-repo && STARTUP_BEST_EFFORT=1 STARTUP_FLOX_ENV=1 bash ${STARTUP_SCRIPT}")"; then
  fail "best-effort no-token flox run exited 0 — requested-stage failures must stay fatal"
fi
printf '%s\n' "${RUN14_OUTPUT}"
case "${RUN14_OUTPUT}" in *"flox-bootstrap | PASS"*) ;; *) fail "flox re-run missing the flox-bootstrap PASS row" ;; esac
case "${RUN14_OUTPUT}" in *"reused"*) ;; *) fail "flox-bootstrap re-run did not reuse the RUN 13 install — not idempotent" ;; esac
case "${RUN14_OUTPUT}" in *"floxhub-token | FAIL"*) ;; *) fail "best-effort flox run missing the floxhub-token FAIL row" ;; esac
case "${RUN14_OUTPUT}" in *"no validated FloxHub token"*) ;; *) fail "flox-activate did not take the token-gated SKIP row despite a committed host env" ;; esac

echo "=== RUN 15: flox token via .env.local + host-repo activation (stubbed flox) ==="
# The PASS paths of the token and activation stages, plus the .env.local
# credential channel. flox is stubbed (--version / auth / activate) so the
# assertions depend ONLY on the script's own wiring: the .env.local at the
# host repo root must provide FLOXHUB_TOKEN (the row names the file), the
# stub's auth acceptance yields the token PASS row, and the stub's
# activate materializes the run bin dir the stage must find, report, and
# put on PATH. The stub token value must never appear anywhere in the
# output — the never-echoed discipline asserted mechanically.
rm -rf /tmp/flox-stub /tmp/flox-repo2
mkdir -p /tmp/flox-stub
# shellcheck disable=SC2016
printf '#!/bin/sh\ncase "$1" in\n--version) echo "flox 1.2.3-stub"; exit 0;;\nauth) exit 0;;\nactivate)\nshift\ndir=""\nwhile [ $# -gt 0 ]; do\n[ "$1" = "--dir" ] && dir="$2"\nshift\ndone\nmkdir -p "$dir/.flox/run/x86_64-linux.flox-stub-run/bin"\nexit 0;;\nesac\nexit 0\n' > /tmp/flox-stub/flox
chmod 755 /tmp/flox-stub/flox
su - sandbox-user -c "git init -q /tmp/flox-repo2 && mkdir -p /tmp/flox-repo2/.flox/env"
su - sandbox-user -c "printf '[env]\nname = \"flox-repo2\"\n' > /tmp/flox-repo2/.flox/env/manifest.toml"
su - sandbox-user -c "printf 'FLOXHUB_TOKEN=STUB-ENV-LOCAL-TOKEN\n' > /tmp/flox-repo2/.env.local"
RUN15_OUTPUT="$(su - sandbox-user -c "cd /tmp/flox-repo2 && PATH=/tmp/flox-stub:\$PATH STARTUP_BEST_EFFORT=1 STARTUP_FLOX_ENV=1 bash ${STARTUP_SCRIPT}")" ||
  fail "stubbed flox run exited non-zero"
printf '%s\n' "${RUN15_OUTPUT}"
case "${RUN15_OUTPUT}" in
*" | FAIL |"*) fail "stubbed flox run recorded FAIL row(s)" ;;
esac
case "${RUN15_OUTPUT}" in *"floxhub-token | PASS"*) ;; *) fail "stubbed flox run missing the token PASS row" ;; esac
case "${RUN15_OUTPUT}" in *"flox-repo2/.env.local"*) ;; *) fail "token PASS row does not name the .env.local source" ;; esac
case "${RUN15_OUTPUT}" in *"flox-activate | PASS"*) ;; *) fail "stubbed flox run missing the activation PASS row" ;; esac
case "${RUN15_OUTPUT}" in *"flox-stub-run/bin"*) ;; *) fail "activation PASS row does not report the materialized run bin dir" ;; esac
case "${RUN15_OUTPUT}" in
*STUB-ENV-LOCAL-TOKEN*) fail "the .env.local token value leaked into the output" ;;
esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ -d /tmp/flox-repo2/.flox/run/x86_64-linux.flox-stub-run/bin ] ||
    fail \"the run bin dir was not materialized under the host repo\"
" || fail "activation verification failed"

echo "=== RUN 16: malformed TRUNK_USER_YAML fails loudly, nothing installed ==="
# The shape-check branch: a TRUNK_USER_YAML without a trunk_user key must
# FAIL the run (requested-surface contract, default posture here) and
# leave NO login file behind — a wrong-stored secret surfaces at setup,
# not as a mysteriously logged-out trunk merge later.
su - sandbox-user -c "rm -rf ~/.cache/trunk"
if RUN16_OUTPUT="$(su - sandbox-user -c "cd /tmp && STARTUP_TRUNK_MERGE_AUTH=1 TRUNK_USER_YAML=not-a-trunk-login bash ${STARTUP_SCRIPT}")"; then
  fail "malformed-yaml run exited 0 — must fail loudly"
fi
printf '%s' "${RUN16_OUTPUT}"
case "${RUN16_OUTPUT}" in *"trunk-merge-auth | FAIL"*) ;; *) fail "malformed-yaml run missing the trunk-merge-auth FAIL row" ;; esac
case "${RUN16_OUTPUT}" in *"no trunk_user key"*) ;; *) fail "trunk-merge-auth FAIL row does not name the shape problem" ;; esac
su - sandbox-user -c "[ ! -e ~/.cache/trunk/user.yaml ]" ||
  fail "a login file was installed despite the failed shape check"

echo "=== RUN 17: trunk merge login via .env.local, then no-clobber re-run ==="
# The provisioning PASS path through the .env.local channel, the file
# contract (0600 file inside a 0700 dir, content preserved byte-for-byte
# plus the trailing newline), and the no-clobber property: a re-run must
# record "already present" and leave the installed login untouched. The
# fake yaml is single-line on purpose — nothing parses it (trunk never
# runs here); the stage's own grep shape-check is the consumer, and a
# one-line value keeps the fixture free of quoting hazards.
rm -rf /tmp/trunk-repo
su - sandbox-user -c "git init -q /tmp/trunk-repo"
su - sandbox-user -c "printf '%s\n' \"TRUNK_USER_YAML='version: 1 trunk_user {access_token stub-access-token-value}'\" > /tmp/trunk-repo/.env.local"
RUN17_OUTPUT="$(su - sandbox-user -c "cd /tmp/trunk-repo && STARTUP_BEST_EFFORT=1 STARTUP_TRUNK_MERGE_AUTH=1 bash ${STARTUP_SCRIPT}")" ||
  fail "trunk-auth run exited non-zero"
printf '%s\n' "${RUN17_OUTPUT}"
case "${RUN17_OUTPUT}" in
*" | FAIL |"*) fail "trunk-auth run recorded FAIL row(s)" ;;
esac
case "${RUN17_OUTPUT}" in *"trunk-merge-auth | PASS"*) ;; *) fail "trunk-auth run missing the trunk-merge-auth PASS row" ;; esac
case "${RUN17_OUTPUT}" in *"trunk-repo/.env.local"*) ;; *) fail "trunk-merge-auth PASS row does not name the .env.local source" ;; esac
# The never-echoed discipline, same as RUN 15's token assert.
case "${RUN17_OUTPUT}" in
*stub-access-token-value*) fail "the login yaml's access token value leaked into the output" ;;
esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  [ \"\$(stat -c %a ~/.cache/trunk/user.yaml)\" = 600 ] ||
    fail \"login file is not 0600: \$(stat -c %a ~/.cache/trunk/user.yaml)\"
  [ \"\$(stat -c %a ~/.cache/trunk)\" = 700 ] ||
    fail \"login dir is not 0700: \$(stat -c %a ~/.cache/trunk)\"
  printf '%s\n' 'version: 1 trunk_user {access_token stub-access-token-value}' | cmp -s - ~/.cache/trunk/user.yaml ||
    fail \"login file content does not match the sourced value byte-for-byte\"
" || fail "trunk-auth file verification failed"
RUN17B_OUTPUT="$(su - sandbox-user -c "cd /tmp/trunk-repo && STARTUP_BEST_EFFORT=1 STARTUP_TRUNK_MERGE_AUTH=1 bash ${STARTUP_SCRIPT}")" ||
  fail "trunk-auth re-run exited non-zero"
printf '%s\n' "${RUN17B_OUTPUT}"
case "${RUN17B_OUTPUT}" in
*" | FAIL |"*) fail "trunk-auth re-run recorded FAIL row(s)" ;;
esac
case "${RUN17B_OUTPUT}" in *"already present"*) ;; *) fail "trunk-auth re-run missing the already-present no-clobber row" ;; esac
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  printf '%s\n' 'version: 1 trunk_user {access_token stub-access-token-value}' | cmp -s - ~/.cache/trunk/user.yaml ||
    fail \"the installed login was modified by the re-run — no-clobber violated\"
" || fail "trunk-auth no-clobber verification failed"

echo "=== RUN 18: the wired stage and scripts/trunk-merge-auth.sh agree byte-for-byte ==="
# The dual-home drift guard (the same relationship the trunk preflight and
# the startup script's trunk stage have via validate-pins.sh, but for
# logic): the standalone helper is the by-hand form of the recipe the
# STARTUP_TRUNK_MERGE_AUTH stage carries. Same input through both forms
# must install byte-identical files — divergence fails here instead of
# drifting silently.
su - sandbox-user -c "cp ~/.cache/trunk/user.yaml /tmp/user.yaml.stage && rm -f ~/.cache/trunk/user.yaml"
su - sandbox-user -c "cd /tmp && TRUNK_USER_YAML='version: 1 trunk_user {access_token stub-access-token-value}' bash /src/scripts/trunk-merge-auth.sh" ||
  fail "scripts/trunk-merge-auth.sh exited non-zero"
su - sandbox-user -c "
  set -e
  fail() { echo \"TEST FAIL: \$*\" >&2; exit 1; }
  cmp -s /tmp/user.yaml.stage ~/.cache/trunk/user.yaml ||
    fail \"the helper and the startup stage installed different bytes for the same TRUNK_USER_YAML — dual-home drift\"
" || fail "helper/stage drift verification failed"
rm -f /tmp/user.yaml.stage

echo "=== ALL CHECKS PASSED ==="
