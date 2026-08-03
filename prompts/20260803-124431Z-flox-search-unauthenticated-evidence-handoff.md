Here's a comprehensive handoff prompt for a fresh, never-authenticated Conductor
cloud sandbox to capture real `flox search` evidence for Stage 4 (H4), now that
the probe itself has landed on `main`.

---

You're working in `flox-conductor-sandbox`, a test harness for gtm-sdk#445
("publish bd/roborev to FloxHub as prebuilt binaries"). Read `README.md` and
`findings/README.md` first, then read
[issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16) in
full — it is the single source of truth for this whole investigation and
supersedes #4, #5, and #11. Don't re-derive anything it already answers. Base
your work on `main` (this repo's target branch).

**Background**: Stage 4 (H4) of `scripts/sandbox-test.sh` tests whether an
*unauthenticated* sandbox can see/fetch a package from FloxHub. Issue #16
already resolved the core question — a bare `flox publish` is private by
construction, so an unauthenticated `flox show`/`flox install` is expected to
fail (SKIP, not FAIL) — but one loose thread was never actually tested: does
`flox search <pkg-path>` behave the same way unauthenticated, or differently?
Earlier findings docs asserted "`flox search` also can't find it," but issue
#16 §4 flagged that as **anecdote from a manual check during PR #9, never
actually run by the harness** — no `flox search` invocation existed in the
script at all until PR #19.

PR #19 fixed two things relevant to you:
1. Stage 4 now checks `flox auth status` *before* doing anything else. If the
   sandbox is already authenticated, it records SKIP immediately and never
   attempts show/install/search — so a contaminated run can't accidentally
   look like real evidence (issue #16 trap 4).
2. It added a real probe: `flox search "${FLOXHUB_TEST_PKG}"` (default
   `elvis/conductor-workspace-floxhub-01`), run only in the genuinely
   unauthenticated branch, right before `flox show`. Its output is embedded in
   the generated report under Stage 4.

No unauthenticated run has exercised that probe yet. That's your job.

**Your task**:

1. **Confirm the precondition first, before anything else**: run
   `flox auth status`. It must report **not logged in**. If it reports logged
   in, **stop immediately** — this sandbox is already disqualified for this
   purpose, report that back, and do not proceed with the steps below (running
   the test here would produce a meaningless, contaminated result — exactly
   the bug PR #19 just fixed the harness to detect and refuse).
2. **Do not run `scripts/floxhub-login.sh`, `flox auth login`, or
   `TEST_AUTH_PLUMBING=1`** at any point in this session, not even to "double
   check" something. The entire point of this run is that `flox auth status`
   stays logged-out throughout. If you find yourself reaching for an auth
   step, stop and re-read this paragraph.
3. Run the harness:
   ```bash
   FLOXHUB_TEST_PKG=elvis/conductor-workspace-floxhub-01 bash scripts/sandbox-test.sh
   ```
   This runs all default stages (0–5); Stage 4 is the one that matters, but
   don't skip the others — they're cheap and the existing findings convention
   records the whole run.
4. Read the generated `findings/report-<STAMP>.md`, Stage 4 section
   specifically. It will now contain, in order: the `flox auth status` output,
   the new `flox search ${FLOXHUB_TEST_PKG} (expect no results unauthenticated)`
   block, and then the `flox show` result. Record, verbatim:
   - What `flox search` actually printed (empty output? an explicit
     "no packages matched" error? a JSON/table result claiming zero matches?
     something else?) and its exit code (visible in `full-log-<STAMP>.txt`).
   - Whether `flox search`'s behavior **agrees or disagrees** with `flox
     show`'s behavior on the same package. That comparison — not just "does
     search fail too" — is the actual gap issue #16 identified: search and
     show could plausibly diverge (e.g. search silently returning nothing
     with exit 0, vs. show's explicit `ERROR: no packages matched this
     pkg-path`), and only a real run tells you which.
5. Do not editorialize past what the log shows. If the result is ambiguous
   (e.g. a network error that's neither clearly "not found" nor clearly
   something else), say so explicitly rather than picking the more convenient
   interpretation — same discipline issue #16 already applied to the original
   H4 SKIP result.
6. Commit the findings pair (`report-<STAMP>.md` and `full-log-<STAMP>.txt`) by
   explicit filename (never `git add -A`, per `findings/README.md`'s own
   process rules). Update `findings/README.md`'s "Runs so far" table with a new
   row, and replace the placeholder text in its "Current bottom line" H4
   section (the parenthetical added in PR #19 that currently reads "no
   unauthenticated run has captured it yet") with the real result.
7. Open a PR against `main`. Follow this repo's push policy: `git roborev
   review --wait` against HEAD before pushing, and don't push past a non-clean
   review without flagging it first (see PR #19 for the precedent — one prior
   low-severity finding about committed local paths/usernames was accepted as
   consistent with existing convention, not a new issue; use your judgment if
   something similar comes up, but don't wave off anything that looks new).
8. Once the PR is merged, edit
   [issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16)
   directly (prefer editing the body over adding a comment, per this repo's
   convention) to record the real `flox search` result in place of the "no
   evidence yet" note, and check off the corresponding open item.

**Out of scope for this task** (see issue #16 §7/§9 for the full picture):
- Do not attempt to resolve the FloxHub personal-vs-org token-strategy
  decision — that has its own dedicated research prompt
  (`prompts/20260803-124531Z-floxhub-token-strategy-decision-research.md`).
- Do not start Phase D MVP implementation work (issue #16 §9) even if this
  run's evidence seems to make some part of it moot — that's separate,
  larger-scoped work with its own plan.

**Notes for whoever redeploys with this prompt**:
- Confirm you're actually handing this to a sandbox that has never had FloxHub
  credentials touch it — a reused or long-lived sandbox may already be
  authenticated for unrelated reasons, which would silently disqualify the
  test before it starts (the harness will now catch this and SKIP rather than
  lie about it, but it's still a wasted run).
- If `flox search`'s behavior turns out to meaningfully diverge from `flox
  show`'s (e.g. it partially works, or errors differently), that's worth
  flagging prominently — it could matter for how Phase D MVP's consumption
  manifest is diagnosed when something goes wrong.
