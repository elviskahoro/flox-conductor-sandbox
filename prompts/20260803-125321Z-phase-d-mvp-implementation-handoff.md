Here's a comprehensive handoff prompt for building the Phase D MVP — the
implementation work issue #16 §9 scoped out but explicitly hadn't turned into
a prompt yet ("ask for one when ready to start"). This is real implementation
work, bigger and more open-ended than the two evidence/research prompts
already in this directory — expect it to span several commits, possibly
several PRs, not one.

---

You're working in `flox-conductor-sandbox`, a test harness for gtm-sdk#445
("publish bd/roborev to FloxHub as prebuilt binaries"). Read `README.md` and
`findings/README.md` first, then read
[issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16) in
full — it is the single source of truth for this whole investigation and
supersedes #4, #5, and #11. Pay particular attention to **§9 "Phase D MVP —
build it here, in this repo"**, which this prompt implements, and **§8 "Out of
scope"**, which still reserves the actual `gtm-sdk` repo port for later. Base
your work on `main`.

**Background**: Phase A (this repo's original job) already answered the
fork-in-the-road question — FloxHub catalogs are private by default, so
Phase D′ (auth-token plumbing) is required for real consumption — and Stage 6
(`envs/floxhub-consume`, PR #13) already proves the *mechanism* end to end with
a trivial smoke-test package. What's never been built is an MVP that actually
looks like what `gtm-sdk/scripts/conductor-workspace-setup.sh` would need:
real tools (`bd`, `roborev`), a combined manifest, a real setup script, and a
provisioning path that's safe to leave in place without contaminating this
repo's other test stages. That gap is what issue #16 §9 scopes, and what
you're building now — **entirely inside this repo**, not in `gtm-sdk`.

**Your task**, in the order issue #16 §9 lays out:

1. **Publish real `bd` and `roborev` packages for consumption.**
   `envs/repackage`'s `[build.bd]` already produces a working `bd` binary (H3,
   verified multiple times — see `findings/README.md`). `roborev` has never
   been attempted (issue #16 flagged this as a "deliberate scope reduction,"
   now brought into scope). It's the same mechanism (Go flake pin → repackage
   an upstream release binary), so start by mirroring `[build.bd]`'s shape for
   `roborev` in `envs/repackage/.flox/env/manifest.toml`, then publish both.
   You have two naming choices — reusing the existing throwaway
   `elvis/conductor-workspace-floxhub-01` catalog entry (renaming/repurposing
   it), or publishing under proper `bd`/`roborev` package names. **Decide
   explicitly, document which and why in your PR description, and don't
   silently pick one if it's ambiguous** — issue #16 §7 already has an open
   item about deleting/reusing that throwaway package (gtm-sdk#445 A6), so
   whatever you decide here has a direct effect on that item; update it in the
   issue if your choice resolves or changes it.
2. **Build a combined consumption manifest.** Extend `envs/floxhub-consume` (or
   create a new env — your call, but say why) so its `[install]` lists both
   the catalog-only tools already proven in `envs/prebuilt` (`uv`, `dolt`,
   `infisical`, `gh`, `git`) *and* `pkg-path` installs for `bd`/`roborev` from
   step 1. This manifest should look like a realistic subset of what
   `gtm-sdk/scripts/conductor-workspace-setup.sh` actually needs, not the
   trivial single-package smoke test Stage 6 used to prove the mechanism.
3. **Build the setup-script MVP.** Write a script (new, or an extension of
   `scripts/floxhub-login.sh` — your call) that: obtains a FloxHub token
   (prefer `infisical run`/`infisical secrets get` if Infisical is available in
   the target environment, per this workspace's secrets-management
   convention; fall back to the `FLOXHUB_TOKEN` env var for the personal-token
   path already prototyped in `scripts/floxhub-login.sh`) → `flox auth login
   --token-file=...` → `flox activate` against the manifest from step 2. This
   script **is** the recipe eventually meant for
   `gtm-sdk/scripts/conductor-workspace-setup.sh` — you're proving it here
   first (§8), not porting it there now.
   - **Token handling is not optional, match `scripts/floxhub-login.sh`'s
     existing discipline exactly**: write the token to a `mktemp` file created
     under `umask 077` (or `chmod 600` immediately after creation), `trap` its
     removal on exit (including on error paths — a token file must never
     survive the script), and never `echo`/log the token value itself. Any
     validation output this script or step 6 produces (findings docs, full
     logs, terminal output you paste into a PR) must have the token redacted —
     treat it with the same care a leaked credential would deserve, because it
     is one.
   - **Resolve paths from the script's own location, not the caller's cwd**,
     the same way `scripts/sandbox-test.sh` does
     (`SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`, then derive `REPO_ROOT`
     from that). Invoke `flox activate` with an explicit `--dir
     "${REPO_ROOT}/envs/<whatever step 2 built>"` — never rely on the
     manifest being resolved relative to wherever the script happened to be
     invoked from, since a script run from an unexpected directory must not
     silently activate the wrong (or no) environment.
4. **Wire it into an opt-in-only provisioning path.** This is the one
   non-negotiable rule, inherited directly from `scripts/floxhub-login.sh`'s
   existing header comment: **never** wire this into
   `.conductor/settings.toml`'s default path or `scripts/sandbox-test.sh`'s
   default run. Doing so would permanently authenticate every fresh Conductor
   sandbox this repo ever provisions, which kills Stage 4 (H4) and the
   still-outstanding `flox search` unauthenticated-evidence task
   (`prompts/20260803-124431Z-flox-search-unauthenticated-evidence-handoff.md`)
   forever. Gate it behind an explicit env var (matching the
   `TEST_AUTH_PLUMBING=1` pattern Stage 6 already uses) or a separate,
   manually-invoked script — pick one and document why in your PR.
5. **Token strategy: use Option A (personal token) for the MVP.** The
   org-vs-personal decision (issue #16 §7) is still open and has its own
   dedicated research prompt (embedded in
   [this issue comment](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16#issuecomment-5166315573)
   and in `prompts/20260803-124531Z-floxhub-token-strategy-decision-research.md`)
   — don't block on it or attempt to resolve it yourself. Build steps 2-4 so
   the manifest and script don't care *which kind* of token authenticated the
   session (a token is a token to `flox auth login`), so swapping in an org
   machine token later is a config change, not a rewrite.
6. **Definition of done — validate it for real.** On a Conductor sandbox
   (doesn't need to be the pristine never-authenticated one — this work
   *requires* authenticating), run your opt-in script end to end and confirm
   both `bd` and `roborev` resolve under `.flox/run/.../bin`, the same
   verification style Stage 6 used (`FLOX_BIN` / run-dir check, binary
   `--version` output captured). Record this the same rigorous way every other
   stage in this repo does: PASS/FAIL/SKIP, findings committed
   (`findings/report-*.md` + `full-log-*.txt` if you route it through
   `scripts/sandbox-test.sh` as a new opt-in stage, or a one-off findings doc
   like `findings/floxhub-x86_64-linux-publish-20260801.md` if you don't) — no
   hand-waving, no "should work."

**Process notes** (this repo's established conventions — follow them):
- `git roborev review --wait` against HEAD before every push, on every branch,
  per this workspace's session-completion rules. Don't push past a non-clean
  review without flagging what it found first.
- One logical commit per concern (matching PR #19/#20's pattern) — don't
  squash "publish bd/roborev" + "build manifest" + "build script" +
  "validate" into one giant commit; it makes review and any future
  bisecting harder.
- If this turns out bigger than expected (e.g. `roborev`'s repackage shape
  doesn't transfer 1:1 from `bd` the way issue #16 assumed), that's a finding,
  not a blocker — report it plainly (same discipline this repo already
  applies to every other stage) and either scope down or split into a
  follow-up rather than forcing a fragile result.
- Open a PR against `main` when done (or incrementally, if you split this into
  multiple PRs — reasonable given the scope). Once merged, edit
  [issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16)
  directly (prefer editing the body over commenting, per this repo's
  convention) to record what the MVP actually looks like, check off/update
  §9's scope items, and resolve or update the A6 throwaway-package item based
  on your step-1 naming decision.

**Out of scope** (see issue #16 §8):
- Do **not** touch the `gtm-sdk` repo at all. Landing this recipe in
  `gtm-sdk/scripts/conductor-workspace-setup.sh` is explicitly a separate,
  later, human-approved step — this MVP's whole point is to prove it here
  first. (This also isn't your repo to edit from here — see this workspace's
  own repo-separation convention.)
- Do **not** attempt to resolve the org-vs-personal token-strategy decision —
  use Option A and move on (step 5 above).
- Do **not** attempt the `flox search` unauthenticated-evidence task — separate
  dedicated prompt, needs a sandbox that stays unauthenticated, which this
  task's sandbox by definition won't be.
- Do **not** unilaterally delete the throwaway
  `elvis/conductor-workspace-floxhub-01` package (gtm-sdk#445 A6) — even if
  you rename/repurpose it in step 1, that's a rename/repurpose, not a
  deletion; deleting a published FloxHub package is a destructive external
  action this repo has already flagged as needing an explicit human decision.

**Notes for whoever redeploys with this prompt**:
- This is meaningfully bigger than the other two prompts in this directory —
  consider whether it's better split across multiple agent sessions (e.g. one
  for step 1, one for steps 2-4, one for validation) rather than handed to a
  single agent in one shot, especially if you want checkpoints to review
  along the way.
- If the package-naming decision (step 1) or the opt-in-gating mechanism
  (step 4) feels ambiguous once you're in the code, stop and ask rather than
  guessing — both have downstream effects on other open items in issue #16.
