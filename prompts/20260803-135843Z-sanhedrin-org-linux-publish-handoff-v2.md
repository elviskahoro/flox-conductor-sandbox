Handoff prompt for a fresh `x86_64-linux` Conductor cloud sandbox to close the
platform gap left by the `sanhedrin` org-catalog switch on `main` — publish
the Linux build so Stage 6 covers both platforms again. This supersedes
`prompts/20260803-133923Z-sanhedrin-org-linux-publish-handoff.md`: that
attempt got as far as confirming the platform (`x86_64-linux`, flox 1.14.0)
before stopping on two blockers — no FloxHub auth in the sandbox, and an
unrelated dirty git tree. Both are addressed below; the actual publish work
itself was never attempted and is unchanged from the original prompt.

---

You're working in `flox-conductor-sandbox`, a test harness for
[gtm-sdk#445](https://github.com/elviskahoro/gtm-sdk/issues/445) ("publish
bd/roborev to FloxHub as prebuilt binaries — flake source builds break on
Vercel sandbox"). Read `README.md` and `findings/README.md` first, then read
[issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16)
in full — it is the single source of truth for this whole investigation,
carries the verdict, the evidence index, the traps not to re-derive, and
what's still open. It supersedes issues #4, #5, and #11. Base your work on
`main` (this repo's target branch).

## Background

Phase D′ (FloxHub auth-token plumbing, issue #16 §6) is confirmed necessary:
a bare `flox publish` is private by construction, so any real
unauthenticated/CI consumption of a FloxHub-hosted package needs
authentication. The Stage 6 prototype (`envs/floxhub-consume`, originally
landed in PR #13) proves the mechanics work end to end — an authenticated
`flox activate` against a manifest whose `[install]` references a real
`pkg-path`, the actual gtm-sdk consumption pattern.

Separately, issue #16 §7 raised an open owner-decision item: should FloxHub
auth for CI/unattended consumption use a personal handle + personal token
(Option A, what Stage 6 originally used) or a paid Flox-for-Teams org +
Auth0 machine token with a `Reader` role (Option B)? That question is
**still open** — nothing below resolves it. See
`findings/20260803-131800Z-floxhub-token-strategy-decision-brief.md` for the
comparison.

**What actually happened next, and why you're here**: the repo owner paid for
a Flox-for-Teams plan and created a real org, `sanhedrin`. As a first
concrete step — validating that org catalogs are a drop-in replacement for
personal ones on the *consumption* side, using the existing personal
token — the following was done directly on `main` (commit `c0d4131`, a
deliberate one-off exception to the normal branch → PR → roborev flow, at
the repo owner's explicit request):

1. `flox publish -d envs/repackage -o sanhedrin conductor-workspace-floxhub-01`
   was run from a macOS (`aarch64-darwin`) machine, publishing the existing
   `conductor-workspace-floxhub-01` build (source: `envs/repackage`, the H3
   "Trivial flox build smoke test" build target — see its `manifest.toml`
   for the exact build definition) to the `sanhedrin` org catalog. This
   succeeded; `flox show sanhedrin/conductor-workspace-floxhub-01` confirms
   it now exists in the org catalog, but **only for `aarch64-darwin`**.
2. `envs/floxhub-consume/.flox/env/manifest.toml`'s `[install]` entry was
   repointed from `elvis/conductor-workspace-floxhub-01` to
   `sanhedrin/conductor-workspace-floxhub-01`, and `[options].systems` was
   temporarily narrowed to `["aarch64-darwin"]` (was
   `["aarch64-darwin", "x86_64-linux"]`) to match what's actually published,
   with `manifest.lock` regenerated to match.
3. `flox activate --dir envs/floxhub-consume -- conductor-workspace-floxhub-01`
   was verified working end to end against the `sanhedrin` catalog before
   any of this was committed.

This state is **unchanged as of `main`@`7276931`** (confirmed just before
writing this prompt) — a separate, larger PR (#22, Phase D MVP / issue #16
§9) landed on `main` in the interim adding `envs/floxhub-provision` and
publishing `elvis/bd` / `elvis/roborev` (personal catalog, not `sanhedrin`),
but it did **not** touch `envs/repackage`'s `conductor-workspace-floxhub-01`
build target or `envs/floxhub-consume`. That PR's own Linux-publish gap
(`elvis/bd` / `elvis/roborev` not yet published for `x86_64-linux`) is a
**separate, larger concern** — do not conflate it with this task or attempt
to close it here; this task is `sanhedrin`-catalog / Stage 6 parity only.

**The gap you're closing**: `envs/floxhub-consume` on `main` right now only
covers `aarch64-darwin`. The `x86_64-linux` build of
`conductor-workspace-floxhub-01` needs to be published to the `sanhedrin` org
too, so the manifest can go back to covering both systems.

## What's changed since the original attempt (unblocking the two stops)

1. **FloxHub auth is now available, but opt-in per workspace.** As of PR #23
   (merged to `main`), `.conductor/settings.toml`'s `scripts.setup` will run
   `flox auth login --token-file=- --insecure-storage` automatically **only
   if both `FLOX_AUTOLOGIN=1` and `FLOXHUB_TOKEN` are set** in this
   workspace's environment. The repo owner has `FLOXHUB_TOKEN` (a personal
   token) set at their Conductor **user-level** settings
   (`environment_variables.cloud`, applies to every cloud sandbox for every
   repo), deliberately *not* gated to auto-login by itself — this is so that
   a default fresh sandbox stays unauthenticated, since Stage 4 (H4, issue
   #16) requires a genuinely never-authenticated sandbox to mean anything.
   **This specific workspace needs `FLOX_AUTOLOGIN=1` set too** (e.g. in this
   workspace's own Conductor settings, not the user-level ones) for setup to
   actually log in. If you land in a sandbox and `flox auth status` still
   shows not logged in, check whether `FLOX_AUTOLOGIN=1` was actually set for
   *this* workspace before treating it as a hard blocker — that's the most
   likely cause, not a missing credential.
2. **This is still a personal token**, not a `sanhedrin` machine token — the
   §7 decision is still open (see Background above). A personal token that's
   a member of the `sanhedrin` org with Writer access is sufficient for
   `flox publish -o sanhedrin` to work; it does not require an org machine
   token.
3. **The dirty-tree blocker was workspace-specific**, not a repo-wide
   problem — it was leftover findings output in that particular sandbox.
   Your fresh sandbox should start clean; re-verify with `git status
   --short` per step 4 below rather than assuming it's fixed.

## Your task

1. **Confirm your environment.** You must be running on a genuinely
   `x86_64-linux` sandbox — check `uname -m` and `flox --version` (this repo
   has been tested against flox 1.14.0; note if yours differs). If you are
   not on `x86_64-linux`, stop and say so; do not attempt to fake or skip
   this step, and do not try to cross-publish for a platform you're not
   actually running on — `flox publish` builds and publishes for the
   platform it runs on.

2. **Confirm org membership and auth.** Run `flox auth status`. You need to
   be logged in as a member of the `sanhedrin` org with at least Writer
   access to publish (Reader cannot publish — see
   `findings/20260803-131800Z-floxhub-token-strategy-decision-brief.md` for
   the documented role restrictions). If not authenticated, first check
   whether `FLOX_AUTOLOGIN=1` is actually set for this workspace (see
   "What's changed" above) before concluding this is a hard blocker. If it's
   set and login still didn't happen, check `~/.conductor-setup.log` for the
   `flox auth login` attempt and its result. If genuinely no credential is
   available after that check, this task **cannot proceed without a real
   credential** — do not attempt to work around this by publishing to your
   own personal catalog instead and silently relabeling it; stop, say so
   explicitly, and hand back a note describing exactly what you found in the
   setup log rather than improvising.

3. **Inspect the build source before publishing.** Read
   `envs/repackage/.flox/env/manifest.toml` in full — as of `main`@`7276931`
   it defines three build targets: `conductor-workspace-floxhub-01` (the
   trivial no-network smoke test you're republishing), `bd`, and `roborev`
   (the real beads/roborev repackages, both out of scope for this task — do
   not touch or publish either). Confirm the
   `conductor-workspace-floxhub-01` build target is unchanged from what's
   already published for `aarch64-darwin` — you want platform parity, not a
   different package.

4. **Verify `flox publish`'s preconditions are met** (per `man flox-publish`):
   the environment must be tracked in a clean git repository, with a remote
   defined, and the current revision already pushed to it. Run
   `git status --short` and require it to be **completely empty** before
   publishing — any uncommitted or untracked file, even one unrelated to
   `envs/repackage`, makes the repository dirty and can cause `flox publish`
   to fail its precondition check or publish from an unreviewed source
   state. If it's not empty, **stop and say so** rather than committing,
   stashing, or otherwise resolving whatever you find — those changes may
   not be yours to touch. Request a clean sandbox/worktree instead of
   proceeding.

5. **Publish for `x86_64-linux`:**
   ```
   flox publish -d envs/repackage -o sanhedrin conductor-workspace-floxhub-01
   ```

6. **Verify it landed on both platforms:**
   ```
   flox show sanhedrin/conductor-workspace-floxhub-01
   ```
   This should now list **both** `aarch64-darwin` and `x86_64-linux` under
   "Systems." If it only shows `x86_64-linux` (i.e. the prior
   `aarch64-darwin` publish is somehow missing), stop and investigate before
   proceeding — do not assume the Mac publish's earlier success and just
   patch the manifest; confirm what the catalog actually contains right now.

7. **Restore full-platform coverage in the consuming manifest.** Edit
   `envs/floxhub-consume/.flox/env/manifest.toml`: change
   `[options].systems` back to `["aarch64-darwin", "x86_64-linux"]`. Delete
   `envs/floxhub-consume/.flox/env/manifest.lock` (it's stale/inconsistent
   with the new systems list) and regenerate it by running:
   ```
   flox activate --dir envs/floxhub-consume -- conductor-workspace-floxhub-01
   ```
   On this Linux sandbox you can exercise the `x86_64-linux` resolution path
   directly — confirm the activation succeeds and prints
   `hello from a flox-built package (gtm-sdk#445 preflight)` (the exact
   output the build target emits, per `envs/repackage/.flox/env/manifest.toml`'s
   `[build.conductor-workspace-floxhub-01]` command). You cannot directly
   exercise the `aarch64-darwin` path from Linux, but locking should still
   succeed for both systems since both are now published.

8. **Do not touch, and do not attempt to answer, the machine-token
   question**, and do not touch `envs/floxhub-provision`, `envs/repackage`'s
   `bd`/`roborev` build targets, or the separate `elvis/bd`/`elvis/roborev`
   Linux-publish gap from PR #22 — all out of scope, tracked separately (see
   Background above and issue #16 §7/§9).

9. **Do not modify, re-run, or draw conclusions from Stage 4 (H4) or the
   `flox search` unauthenticated-evidence work.** Those are separate,
   already-tracked threads (issue #16 §4).

## Git workflow

The `aarch64-darwin` half of this change was pushed **directly to `main`**,
bypassing the normal PR flow, as a **deliberate one-off exception** made at
the repo owner's explicit, in-the-moment request. That is not the default,
and you should not treat it as license to do the same. The `FLOX_AUTOLOGIN`
gating change (PR #23) went through the normal PR flow and was merged by the
repo owner directly, without a successful `roborev` run — `roborev` was
confirmed **not installed** in that sandbox (no `roborev` git subcommand, no
binary anywhere on `$PATH` or filesystem). If `roborev` is available in your
sandbox, use it normally per the steps below; if it's genuinely unavailable
(not just failing), say so explicitly and check with the repo owner before
pushing rather than assuming you should skip it.

1. Create a branch with the `agent/` prefix (e.g.
   `agent/sanhedrin-linux-publish`) off `main` — **not** `claude/...` or any
   other prefix; this repo's convention is `agent/` for AI-agent branches.
2. Commit `envs/floxhub-consume/.flox/env/manifest.toml` and
   `envs/floxhub-consume/.flox/env/manifest.lock` together, with a commit
   message that states plainly what was published and verified (which
   platform, which package, what command was run) — don't editorialize
   about the token-strategy decision in the commit message, that's a
   separate open thread.
3. Run `git roborev review --wait` against your commit **before** pushing.
   If it's unavailable or fails to run, say so explicitly and stop — do not
   push anyway, and do not skip the gate with `--no-verify` or similar,
   unless the repo owner explicitly tells you to proceed given a confirmed
   `roborev` unavailability (as happened with PR #23).
4. If roborev surfaces a finding, fix it and create a **new** commit (do not
   amend past a hook/review failure in a way that loses the review trail).
5. Push your branch and open a PR against `main` — do **not** push directly
   to `main` from this sandbox run. Use the same PR body conventions as
   recent PRs in this repo (`#19`, `#20`, `#21`, `#23`): a Summary section
   and a Test plan checklist.
6. Do not merge the PR yourself; leave it for the repo owner to review and
   merge, unless the repo owner explicitly asks you to merge it in this
   session (as happened with PR #23).

## Explicitly out of scope

- Any Flox-for-Teams billing, seat management, or org-membership changes.
- Publishing or touching the `bd`/`roborev` build targets in
  `envs/repackage`, or the `elvis/bd`/`elvis/roborev` Linux-publish gap from
  PR #22 (issue #16 §9) — a separate, larger-scoped concern.
- The machine-token / `--token-file` question (issue #16 §7).
- The `flox search` unauthenticated-evidence task (issue #16 §4).
- Editing `findings/20260803-131800Z-floxhub-token-strategy-decision-brief.md`
  or issue #16 to declare any token-strategy decision made — none has been.
- Changing the `FLOX_AUTOLOGIN`/`FLOXHUB_TOKEN` gating mechanism itself
  (`.conductor/settings.toml`, PR #23) — if it's not working as described
  above, report exactly what you observed rather than redesigning it.

## Deliverable

A PR against `main` that:
- Publishes `conductor-workspace-floxhub-01` to the `sanhedrin` org for
  `x86_64-linux`.
- Restores `envs/floxhub-consume/.flox/env/manifest.toml`'s `systems` to
  cover both `aarch64-darwin` and `x86_64-linux`, with a regenerated,
  internally-consistent `manifest.lock`.
- Passes `git roborev review --wait` before push, or explicitly documents why
  it couldn't run.
- Has a clear commit message and PR description describing exactly what was
  published, verified, and how (including the literal `flox activate`
  output you observed), so the next reader doesn't have to re-derive it.
