Here's a comprehensive handoff prompt for a fresh `x86_64-linux` Conductor
cloud sandbox to close the platform gap left by the `sanhedrin` org-catalog
switch on `main` — publish the Linux build so Stage 6 covers both platforms
again.

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
(Option A, what Stage 6 originally used — `elvis/conductor-workspace-floxhub-01`),
or a paid Flox-for-Teams org + Auth0 machine token with a `Reader` role
(Option B, per gtm-sdk#445 §6/A1)? A research-only brief comparing the two
was written and committed as
`findings/20260803-131800Z-floxhub-token-strategy-decision-brief.md` (see also
the handoff prompt that produced it,
`prompts/20260803-124531Z-floxhub-token-strategy-decision-research.md`) — it
is a comparison, not a decision, and it flagged several unknowns, most
importantly: **does `flox auth login --token-file=<path>` accept an org
machine token identically to a personal one?** That question is still open
and gated on getting an actual machine token from Flox's team — not your
job in this task.

**What actually happened next, and why you're here**: the repo owner paid for
a Flox-for-Teams plan and created a real org, `sanhedrin`, with the intent
of moving off the personal-account path regardless of how the machine-token
question resolves (an org-shared catalog is useful independent of the
token-scoping question). As a first concrete step — validating that org
catalogs are a drop-in replacement for personal ones on the *consumption*
side, using the existing personal token — the following was done directly
on `main` (commit `c0d4131`, pushed as a deliberate one-off exception to the
normal branch → PR → roborev flow, at the repo owner's explicit request):

1. `flox publish -d envs/repackage -o sanhedrin conductor-workspace-floxhub-01`
   was run from a macOS (`aarch64-darwin`) machine, publishing the existing
   `conductor-workspace-floxhub-01` build (source: `envs/repackage`, the H3
   "Trivial flox build smoke test" build target — see its
   `manifest.toml` for the exact build definition) to the `sanhedrin` org
   catalog. This succeeded; `flox show sanhedrin/conductor-workspace-floxhub-01`
   confirms it now exists in the org catalog, but **only for
   `aarch64-darwin`** — there is no Linux build of it in the `sanhedrin`
   catalog yet.
2. `envs/floxhub-consume/.flox/env/manifest.toml`'s `[install]` entry was
   repointed from `elvis/conductor-workspace-floxhub-01` to
   `sanhedrin/conductor-workspace-floxhub-01`.
3. Because only `aarch64-darwin` is published to the org so far, `[options]
   .systems` in that same manifest was **temporarily narrowed from
   `["aarch64-darwin", "x86_64-linux"]` to just `["aarch64-darwin"]`**, and
   `manifest.lock` was regenerated to match — a real `roborev` review caught
   that leaving `x86_64-linux` declared while only `aarch64-darwin` was
   published would break resolution on Linux, so the systems list was
   deliberately narrowed rather than left inconsistent with what's actually
   published.
4. `flox activate --dir envs/floxhub-consume -- conductor-workspace-floxhub-01`
   was verified working end to end against the `sanhedrin` catalog (with the
   existing personal FloxHub login/token — no machine token involved) before
   any of this was committed.

**The gap you're closing**: `envs/floxhub-consume` on `main` right now only
covers `aarch64-darwin`. The `x86_64-linux` build of
`conductor-workspace-floxhub-01` needs to be published to the `sanhedrin` org
too, so the manifest can go back to covering both systems — matching what
gtm-sdk actually needs (its five real dependencies, and eventually `bd`, must
resolve on `x86_64-linux` since that's the target Vercel/Conductor sandbox
class this whole repo exists to validate against, per README's "Current
status" section).

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
   the documented role restrictions). If not authenticated, this task
   **cannot proceed without a real credential** — do not attempt to work
   around this by publishing to your own personal catalog instead and
   silently relabeling it; if you lack org access, stop, say so explicitly,
   and hand back a note describing exactly what credential/access is
   missing rather than improvising.

3. **Inspect the build source before publishing.** Read
   `envs/repackage/.flox/env/manifest.toml` in full — it defines two build
   targets: `conductor-workspace-floxhub-01` (the trivial no-network smoke
   test you're republishing) and `bd` (the real beads repackage, out of
   scope for this task — do not touch or publish `bd`). Confirm the
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
   proceeding on a dirty one.

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
   question.** This task is catalog-parity only — making the *personal*-token
   consumption path work identically across both platforms via the
   `sanhedrin` org catalog. The separate question of whether an Auth0
   client-credentials machine token can be used with
   `flox auth login --token-file=<path>` the same way a personal token can
   is still pending a direct answer from Flox's team (per the repo owner's
   personal connection to Flox's founders) and is explicitly out of scope
   here. Do not speculate about it in your commit message, PR description,
   or any findings doc you touch.

9. **Do not modify, re-run, or draw conclusions from Stage 4 (H4) or the
   `flox search` unauthenticated-evidence work.** Those are separate,
   already-tracked threads (issue #16 §4;
   `prompts/20260803-124431Z-flox-search-unauthenticated-evidence-handoff.md`).
   This task only touches `envs/repackage` (read-only, to confirm the build
   source) and `envs/floxhub-consume` (the actual edits).

## Git workflow — read this carefully, it differs from what just happened on `main`

The `aarch64-darwin` half of this change was pushed **directly to `main`**,
bypassing the normal PR flow, as a **deliberate one-off exception** made at
the repo owner's explicit, in-the-moment request. That is not the default,
and you should not treat it as license to do the same.

For this task:

1. Create a branch with the `agent/` prefix (e.g.
   `agent/sanhedrin-linux-publish`) off `main` — **not** `claude/...` or any
   other prefix; this repo's convention is `agent/` for AI-agent branches
   (Linear-initiated `feature/...` branches are a separate exception that
   doesn't apply here).
2. Commit `envs/floxhub-consume/.flox/env/manifest.toml` and
   `envs/floxhub-consume/.flox/env/manifest.lock` together, with a commit
   message that states plainly what was published and verified (which
   platform, which package, what command was run) — don't editorialize
   about the token-strategy decision in the commit message, that's a
   separate open thread.
3. Run `git roborev review --wait` against your commit **before** pushing.
   If it's unavailable or fails to run, say so explicitly and stop — do not
   push anyway, and do not skip the gate with `--no-verify` or similar.
4. If roborev surfaces a finding, fix it and create a **new** commit (do not
   amend past a hook/review failure in a way that loses the review trail) —
   same pattern as the fix applied during the original `sanhedrin`-catalog
   change (a real finding was raised and fixed before that commit was
   pushed to `main`).
5. Push your branch and open a PR against `main` — do **not** push directly
   to `main` from this sandbox run. Use the same PR body conventions as
   recent PRs in this repo (`#19`, `#20`, `#21`): a Summary section and a
   Test plan checklist.
6. Do not merge the PR yourself; leave it for the repo owner to review and
   merge.

## Explicitly out of scope

- Any Flox-for-Teams billing, seat management, or org-membership changes —
  you're using access that's already been granted, not provisioning it.
- Publishing or touching the `bd` build target in `envs/repackage` — that's
  the real beads repackage and a separate, larger-scoped concern.
- The machine-token / `--token-file` question (see step 8 above).
- The `flox search` unauthenticated-evidence task (see step 9 above).
- Editing `findings/20260803-131800Z-floxhub-token-strategy-decision-brief.md`
  or issue #16 to declare any token-strategy decision made — none has been;
  this task doesn't change that.

## Deliverable

A PR against `main` that:
- Publishes `conductor-workspace-floxhub-01` to the `sanhedrin` org for
  `x86_64-linux`.
- Restores `envs/floxhub-consume/.flox/env/manifest.toml`'s `systems` to
  cover both `aarch64-darwin` and `x86_64-linux`, with a regenerated,
  internally-consistent `manifest.lock`.
- Passes `git roborev review --wait` before push.
- Has a clear commit message and PR description describing exactly what was
  published, verified, and how (including the literal `flox activate`
  output you observed), so the next reader doesn't have to re-derive it.
