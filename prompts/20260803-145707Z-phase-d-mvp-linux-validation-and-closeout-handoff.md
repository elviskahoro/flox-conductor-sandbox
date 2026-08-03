# Handoff: validate Phase D MVP on Linux, close out remaining issue #16 items

## Where this picks up

Issue #16 is the single source of truth for gtm-sdk#445 Phase A/D. As of this
handoff:

- H1/H2/H3/H4 are all resolved (§1/§3 of issue #16). Nothing left there.
- Phase D′ (Stage 6, auth mechanism) PASSed on macOS (run `20260801-220017Z`).
- Phase D MVP (Stage 7, the real recipe — §9) PASSed, but **only on macOS**
  (`aarch64-darwin`, run `20260803-134541Z`), and at the time of that run
  `elvis/bd`/`elvis/roborev` were only published for `aarch64-darwin` — a
  known gap the run's own commit flagged.
- That gap has since been closed: commit `da731ee` published both
  `elvis/bd@1.1.2` and `elvis/roborev@0.63.0` for `x86_64-linux` from a real
  Conductor cloud sandbox, and widened
  `envs/floxhub-provision/.flox/env/manifest.toml`'s per-package `systems`
  accordingly. `flox show` confirmed both systems for each package at
  publish time.
- Commit `4501e22` made FloxHub auto-login opt-in (`FLOXHUB_AUTOLOGIN=1`)
  rather than automatic — relevant context if you're touching
  `.conductor/settings.toml` or `scripts/floxhub-provision.sh`.
- Commit `6ae0853` closed the last H4 loose thread (real `flox search`
  evidence, unauthenticated) and I've since landed the corresponding issue
  #16 body edit (§4 blockquote resolved, §7 item checked off).

**What's NOT yet done: nobody has re-run Stage 7 on the actual target
sandbox class (Amazon Linux 2023 / Vercel / Conductor cloud) now that both
packages are published for `x86_64-linux`.** The MVP's own definition of
done (§9 point 6) is explicit: *"a fresh, never-before-authenticated
Conductor cloud sandbox goes from provisioned to `bd`+`roborev` resolving
under `.flox/run/.../bin`... validated the same rigorous way Stage 6 was."*
That hasn't happened on the target class yet — only on macOS, which the
whole harness treats as non-authoritative for target-class conclusions (see
issue #16 §2's stage/hypothesis table and trap 6).

Separately, `findings/README.md`'s Phase D MVP bullet (the "Known gap:
`elvis/bd`/`elvis/roborev` are only published for `aarch64-darwin` so far"
sentence, in the "If you're about to add another run" section's preceding
paragraph) is now **stale** — it still describes the gap `da731ee` closed.

## Task

1. **Run Stage 7 on the real target class.** On a genuinely fresh,
   never-before-authenticated Amazon Linux 2023 / Vercel / Conductor cloud
   sandbox, run `scripts/sandbox-test.sh` with `TEST_FLOXHUB_PROVISION=1`
   (check the script/README for the exact opt-in var name and any other
   required env vars — do not guess; re-read `scripts/floxhub-provision.sh`
   and the `20260803-134541Z` findings commit for the exact recipe first).
   This deliberately authenticates the sandbox, so:
   - Confirm `flox auth status` reports logged-out **before** the run (same
     precondition discipline as the `144830Z` H4 run).
   - Do **not** wire this into `.conductor/settings.toml`'s default path —
     same non-negotiable rule as `scripts/floxhub-login.sh` (issue #16 trap
     5). This must stay a deliberate, manually-invoked opt-in run.
2. **Record the result** the same rigorous way every other run has been:
   `findings/report-<STAMP>.md` + `findings/full-log-<STAMP>.txt` committed
   by explicit name (never `git add -A`), a stage-by-stage commit body (see
   recent findings commits for the shape), and a new row in
   `findings/README.md`'s run table.
3. **Fix the stale gap note** in `findings/README.md`'s Phase D MVP bullet —
   replace "Known gap: ... a Linux publish is still needed" with the actual
   outcome (gap closed by `da731ee`, now validated end-to-end by the new
   Linux run from step 1/2).
4. **Update issue #16 §9's checklist framing** if the new run makes the MVP
   fully done: the six numbered scope items in §9 aren't currently a
   checklist (they're prose), so use your judgment on whether to convert
   them or add a short "Status" line noting the MVP is now validated on the
   target class — match this repo's convention of editing issue bodies
   directly for resolved items (see §7's strikethrough style), not posting
   a comment.
5. **If Stage 7 does NOT pass on Linux**, do not paper over it — record the
   FAIL/whatever the harness reports as a real finding (same discipline as
   H2's inverted-polarity check, trap 7), and leave issue #16 §9 open with
   the specific blocker noted. Do not guess a fix without evidence from the
   actual run.

## Also still open in issue #16 (lower priority, pick up if time allows)

- **§7 token-strategy decision** (personal `flox auth token` vs. paid
  Flox-for-Teams org + Auth0 machine token in Infisical as
  `FLOXHUB_MACHINE_TOKEN`). A research-only prompt already exists:
  [`prompts/20260803-124531Z-floxhub-token-strategy-decision-research.md`](../prompts/20260803-124531Z-floxhub-token-strategy-decision-research.md).
  This is a **human decision**, not something to resolve unilaterally — at
  most, produce the comparison brief that prompt calls for.
- **gtm-sdk#445 A6**: delete/ignore the throwaway
  `elvis/conductor-workspace-floxhub-01` package once Phase A is fully
  closed out. Explicitly deferred — still gated on the token-strategy
  decision above and on whether §9's MVP wants to keep/reuse it. Don't
  action this without checking with the user first.

## Out of scope (do not touch)

- `gtm-sdk/` itself — porting the validated recipe into
  `gtm-sdk/scripts/conductor-workspace-setup.sh` is a separate, explicit
  decision made *after* this repo's MVP is fully validated (issue #16 §8).
- Re-litigating H1–H4 or the Phase D′ (Stage 6) mechanism — those are
  closed.
- Any section of issue #16 not named above.

## Where to look first

- `findings/README.md` — the run table and "if you're about to add another
  run" checklist (grep-for-logged-in-user reminder, one-commit-per-run,
  lockless `envs/flake-repro` caveat).
- `scripts/floxhub-provision.sh`, `scripts/sandbox-test.sh` — the actual
  Stage 7 mechanics.
- `envs/floxhub-provision/.flox/env/manifest.toml` — the manifest under
  test, already widened for `x86_64-linux`.
- Issue #16 §9 — the MVP's scope and definition of done, verbatim.
