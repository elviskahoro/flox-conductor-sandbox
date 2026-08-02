# Navigating `findings/`

Each `scripts/sandbox-test.sh` run writes one pair of files, named by UTC
timestamp:

- `report-<STAMP>.md` — PASS/FAIL/SKIP summary table plus evidence
  (excerpts are only included for failing/interesting stages; a clean PASS
  just gets a one-line detail). **Read this first.**
- `full-log-<STAMP>.txt` — the complete raw transcript. Only dig in here if
  the report's excerpt isn't enough to understand a result.

See the top-level [README](../README.md) for what the hypotheses (H1-H4)
and stages mean, and how to produce a new run.

## Runs so far, oldest to newest

| Stamp | Environment | Target class? | Headline result |
|---|---|---|---|
| `20260801-021231Z` | Claude Code remote container (Ubuntu 24.04) | No | H1 PASS; H3 FAIL (proxy 403 on GitHub archive fetch — environment-limited, not a flox defect) |
| `20260801-121814Z` | macOS (Darwin, developer machine) | No | H1 PASS; Stage 3a PASS but 3b FAIL (`tar` extraction error, never root-caused) |
| `20260801-123329Z` | Amazon Linux 2023 / Vercel / Conductor cloud | **Yes** | H1 + H3 (all sub-stages) PASS — first clean pass on the real target class |
| `20260801-125246Z` | Same sandbox as above, deliberate re-run with `FLAKE_REPRO=1` | **Yes** | Reproduces the prior run exactly (confirms idempotency) + H2 control PASS |
| `20260801-141525Z` | Same Amazon Linux 2023 / Vercel / Conductor cloud sandbox | **Yes** | H1 + H3 PASS again; H4 and opt-in H2 skipped |
| `20260801-160419Z` | Fresh Conductor cloud sandbox, never authenticated to FloxHub | **Yes** | H1 + H3 PASS again; **H4 SKIP** — `flox show elvis/conductor-workspace-floxhub-01` fails unauthenticated even though PR #7/#8 confirm it's published for both platforms; `flox search` also can't find it. Resolved by issue #11: expected — private-by-default catalog, not a visibility bug |
| `20260801-201328Z` | macOS, developer machine, **already authenticated to FloxHub** | No | Stage 3b bd repackage FAIL (`tar` extraction, unrelated); Stage 4 logged **PASS** with "no token plumbing needed" — **invalid**, see issue #11 resolution below: this run's own `flox auth status` shows it was logged in, so it never tested unauthenticated access |
| `20260801-220017Z` | macOS, developer machine, deliberately re-authenticated for `TEST_AUTH_PLUMBING=1` | No | New **Stage 6 (Phase D' prototype) PASS** — `flox auth login --token-file` + `flox activate` against a `pkg-path` manifest (`envs/floxhub-consume`) works end to end. Stage 4's "PASS" here is contaminated for the same reason as `20260801-201328Z` and should be ignored |

## Current bottom line (as of the last run above)

- **H1** (prebuilt-catalog manifest activates atomically): PASS on every
  environment tested.
- **H3** (`flox build` repackage shape): PASS on the real target class,
  three times. The two earlier failures are understood/explained, not open
  questions (see table above).
- **H2** (control repro of the original bug): PASS — the target sandbox
  class genuinely has the defect #445 describes, which is what makes the
  H1/H3 passes meaningful evidence rather than "the bug just doesn't exist
  here."
- **H4** (unauthenticated FloxHub fetch): run on a genuinely fresh,
  never-authenticated sandbox (`20260801-160419Z`), and it came back
  **SKIP, not PASS or FAIL** — `flox show
  elvis/conductor-workspace-floxhub-01` fails unauthenticated
  ("no packages matched"), even though the package is confirmed published
  for both `aarch64-darwin` (PR #7) and `x86_64-linux` (see
  [`floxhub-x86_64-linux-publish-20260801.md`](floxhub-x86_64-linux-publish-20260801.md)).
  `flox search` also can't surface it unauthenticated.

  **Resolved (issue #11):** SKIP is the correct, expected result — not an
  ambiguous signal. `flox publish <pkg>` with no `-o`/`--org` flag (exactly
  what PR #7 and PR #8 ran) always publishes to the **publisher's private
  catalog**. Per `flox publish --help` and
  https://flox.dev/docs/concepts/publishing/: "individual users will not be
  able to share packages they've published with other users." The only
  visibility knob `flox publish` exposes is `--org`, and even org-shared
  packages "cannot be viewed by anyone outside the organization" (a paid
  Flox-for-Teams feature) — there is no flag that makes a published package
  fetchable by the general public or by an unauthenticated caller. A
  second-account test isn't needed to confirm this; the CLI/docs already
  rule out any other outcome for a bare `flox publish`.

  **Conclusion: Phase D' (#445 §6 FloxHub auth-token plumbing) is required**
  for any real unauthenticated or CI consumption of a FloxHub-hosted
  package — the catalog entry is private by construction, not
  misconfigured.

  Note: a separate run, `20260801-201328Z`, logged this stage as **PASS**
  with the note "no token plumbing needed (#445 §6 is dead code)". That
  conclusion is **invalid and superseded** — the run's own
  `flox auth status` output shows it executed on an already-authenticated
  machine ("You are logged in as elvis... Credential stored in your system
  keyring"), so its `flox show` success proves nothing about unauthenticated
  visibility. Kept in the runs table above for the record, not as evidence.

- **Phase D' prototype (Stage 6, new, opt-in):** issue #11's follow-up —
  prove the auth-token recipe works, not just that it's needed. Run
  `20260801-220017Z` authenticated via `scripts/floxhub-login.sh` and then
  `flox activate --dir envs/floxhub-consume` — a manifest whose
  `[install]` references the real published `pkg-path`
  (`elvis/conductor-workspace-floxhub-01`), the actual gtm-sdk consumption
  pattern, not Stage 4's ad hoc `flox install`. **Result: PASS** — the
  binary resolves under `.flox/run/.../bin` after authenticated activation.
  This is the concrete recipe to port into
  `gtm-sdk/scripts/conductor-workspace-setup.sh`: mint/obtain a token (via
  Infisical in real gtm-sdk provisioning) → `flox auth login
  --token-file=...` → `flox activate` against a `pkg-path` manifest.
- Still unexplained: the macOS `tar` extraction failure in the second run —
  worth root-causing if `bd`/`roborev` provisioning needs to work on
  developer Macs, not just cloud sandboxes.

Full narrative synthesis: [PR #3](https://github.com/elviskahoro/flox-conductor-sandbox/pull/3),
and each findings commit's message body (`git log --oneline`, then
`git log -1 <sha>` for the run you care about) — that's where stage-by-stage
analysis lives, not in the generated report files themselves.

## If you're about to add another run

- Read the top-level README's "Running" section first.
- One commit per run; add findings files by explicit name, never `git add -A`.
- Put a stage-by-stage analysis in the commit body (see recent findings
  commits for the expected shape) — don't hand-edit the generated
  `report-*.md`.
- Update the table above with the new run.
- If you run Stage 5 (`FLAKE_REPRO=1`), check for and remove any
  `envs/flake-repro/.flox/env/manifest.lock` it leaves behind — that env is
  deliberately kept lockless (see top-level README).
