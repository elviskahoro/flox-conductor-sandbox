Here's a comprehensive handoff prompt for a fresh, never-authenticated sandbox to run the actual Stage 4 (H4) test now that publishing is unblocked:

---

You're working in `flox-conductor-sandbox`, a test harness for gtm-sdk#445 ("publish bd/roborev to FloxHub as prebuilt binaries"). Read `README.md` and `findings/README.md` first — don't re-derive history that's already written down there. Base your work on `claude/gtm-sdk-445-test-d0wx5c` (this repo's target branch) — fast-forward onto `origin/claude/gtm-sdk-445-test-d0wx5c` if behind.

**Background**: Stage 4 (H4) of `scripts/sandbox-test.sh` tests whether an *unauthenticated* sandbox can `flox install` a package from FloxHub. This answers whether gtm-sdk#445's planned auth-token plumbing (Phase D') is necessary at all. That test is only meaningful on a sandbox that has **never** run `flox auth login` — auth is one-way and irreversible for this purpose.

Two prior PRs already did the setup work this test needed:
- PR #7 authenticated a Mac and published `elvis/conductor-workspace-floxhub-01` for `aarch64-darwin`.
- PR #8 (this session) authenticated an x86_64-linux Conductor sandbox and published the same package for `x86_64-linux`.

`flox show elvis/conductor-workspace-floxhub-01` now lists `Systems: aarch64-darwin, x86_64-linux` — the package the H4 test needs is finally visible on the right platform. **Both of those sandboxes are now permanently authenticated and disqualified from ever running H4 again.** You are (per the instructions below) a genuinely fresh sandbox that must stay that way until the test completes.

**Your task**:

1. **Do not run `scripts/floxhub-login.sh` or `flox auth login` at any point in this session**, not even to "double check" something. The entire point of this run is that `flox auth status` reports logged-out throughout. If you find yourself reaching for an auth step, stop and re-read this paragraph.
2. Confirm the precondition first: `flox auth status` should report not logged in. If it reports logged in, **stop immediately** — this sandbox is already disqualified, report that back, and do not proceed with steps below (running the test here would produce a meaningless result).
3. Run the harness with the now-published package:
   ```bash
   FLOXHUB_TEST_PKG=elvis/conductor-workspace-floxhub-01 bash scripts/sandbox-test.sh
   ```
   This runs all stages (0–4); Stage 4 is the one that matters here, but don't skip the others — they're cheap and the existing findings convention records the whole run.
4. Read the generated `findings/report-<STAMP>.md`, specifically the Stage 4 line. Three possible outcomes:
   - **PASS** ("unauthenticated install ... works — no token plumbing needed"): this is a real, load-bearing result for gtm-sdk#445 — it means Phase D' (auth token plumbing) can likely be skipped.
   - **FAIL** ("package visible but install failed — likely auth"): FloxHub requires auth even for install, not just for `flox show`. This means Phase D' probably **is** required after all. Capture the exact error text from `full-log-<STAMP>.txt`.
   - **SKIP**: means something regressed (package not visible, or `flox` unavailable) — investigate before assuming either PASS/FAIL narrative.
5. Do not editorialize past what the log shows — if the result is ambiguous (e.g. a network error that's neither clearly "auth" nor clearly something else), say so explicitly rather than picking the more convenient interpretation.
6. Commit the findings pair (`report-<STAMP>.md` and `full-log-<STAMP>.txt`) by explicit filename (never `git add -A`, per `findings/README.md`'s own instructions), update the "Runs so far" table and "Current bottom line" section in `findings/README.md` with the real H4 verdict, and update the top-level `README.md`'s "Interpreting outcomes" section if the Stage 4 status text there is now stale.
7. Open a PR against `claude/gtm-sdk-445-test-d0wx5c`. In the description, state plainly whether H4 PASSed or FAILed and what that implies for gtm-sdk#445 Phase D' — this is the actual deliverable this whole chain of sandboxes (issue #5 → PR #7 → PR #8 → this one) was building up to.
8. Out of scope, per issue #5's original stop condition: do not attempt gtm-sdk#445 Phase B/C/D/D' implementation itself, even if H4 clearly indicates it's needed — just report the verdict and let a human decide next steps.

**Notes for whoever redeploys with this prompt:**
- Confirm you're actually handing this to a sandbox that has never had FloxHub credentials touch it — a reused or long-lived sandbox may already be authenticated for unrelated reasons, which would silently invalidate the test.
- If H4 PASSes, it's worth flagging to the operator that gtm-sdk#445's Phase D' scope may be reducible — that's a bigger finding than it looks and deserves visibility beyond this repo's own PR thread (e.g. a comment on gtm-sdk#445 itself, if you have access).
