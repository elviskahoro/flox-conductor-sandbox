# Navigating `findings/`

> **[Issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16) is
> the single source of truth for gtm-sdk#445 Phase A** — the verdict, the traps, and
> the open items. It also carries a run-by-run index marking which Stage 4 results are
> contaminated. Read it before drawing conclusions from anything here.

Each `scripts/sandbox-test.sh` run writes one pair of files, named by UTC
timestamp:

- `report-<STAMP>.md` — PASS/FAIL/SKIP summary table plus evidence
  (excerpts are only included for failing/interesting stages; a clean PASS
  just gets a one-line detail). **Read this first.**
- `full-log-<STAMP>.txt` — the complete raw transcript. Only dig in here if
  the report's excerpt isn't enough to understand a result.

See the top-level [README](../README.md) for what the hypotheses (H1-H4)
and stages mean, and how to produce a new run.

## Additional reports

- [Beads + Linear integration report](linear-beads-integration-report.md) —
  native integration findings, Linear team discovery, worktree database
  redirect hazard, and target-repository setup guidance.

## Runs so far, oldest to newest

| Stamp | Environment | Target class? | Headline result |
|---|---|---|---|
| `20260801-021231Z` | Claude Code remote container (Ubuntu 24.04) | No | H1 PASS; H3 FAIL (proxy 403 on GitHub archive fetch — environment-limited, not a flox defect) |
| `20260801-121814Z` | macOS (Darwin, developer machine) | No | H1 PASS; Stage 3a PASS but 3b FAIL (`tar` extraction error, never root-caused) |
| `20260801-123329Z` | Amazon Linux 2023 / Vercel / Conductor cloud | **Yes** | H1 + H3 (all sub-stages) PASS — first clean pass on the real target class |
| `20260801-125246Z` | Same sandbox as above, deliberate re-run with `FLAKE_REPRO=1` | **Yes** | Reproduces the prior run exactly (confirms idempotency) + H2 control PASS |
| `20260801-134157Z` | macOS (Darwin, developer machine), genuinely unauthenticated at the time | No | H1 PASS; Stage 3b FAIL (`tar` extraction, same cause as `121814Z`, later root-caused/fixed in PR #15); Stage 4 SKIP — `elviskahoro/hello-conductor` not found (pre-dates the handle fix and package rename, traps 1-2) |
| `20260801-141525Z` | Same Amazon Linux 2023 / Vercel / Conductor cloud sandbox | **Yes** | H1 + H3 PASS again; H4 and opt-in H2 skipped |
| `20260801-150017Z` | Amazon Linux 2023 / Vercel / Conductor cloud | **Yes** | H1 + H3 (all sub-stages) PASS; Stage 4 SKIP — but moot as an H4 data point, since it ran 6 minutes before PR #8 published `x86_64-linux` (trap 6) |
| `20260801-160419Z` | Fresh Conductor cloud sandbox, never authenticated to FloxHub | **Yes** | H1 + H3 PASS again; **H4 SKIP** — `flox show elvis/conductor-workspace-floxhub-01` fails unauthenticated even though PR #7/#8 confirm it's published for both platforms. Resolved by issue #11: expected — private-by-default catalog, not a visibility bug |
| `20260801-161442Z` | macOS, developer machine, **already authenticated to FloxHub** | No | Stage 3b bd repackage FAIL (`tar` extraction, same cause, later root-caused/fixed in PR #15); Stage 4 logged **PASS** with "no token plumbing needed" — **contaminated**, same reason as `20260801-201328Z` below: this run's own `flox auth status` shows it was logged in, so it never tested unauthenticated access (issue #16 trap 4) |
| `20260801-201328Z` | macOS, developer machine, **already authenticated to FloxHub** | No | Stage 3b bd repackage FAIL (`tar` extraction, unrelated); Stage 4 logged **PASS** with "no token plumbing needed" — **invalid**, see issue #11 resolution below: this run's own `flox auth status` shows it was logged in, so it never tested unauthenticated access |
| `20260801-220017Z` | macOS, developer machine, deliberately re-authenticated for `TEST_AUTH_PLUMBING=1` | No | New **Stage 6 (Phase D' prototype) PASS** — `flox auth login --token-file` + `flox activate` against a `pkg-path` manifest (`envs/floxhub-consume`) works end to end. Stage 4's "PASS" here is contaminated for the same reason as `20260801-201328Z` and should be ignored |
| `20260802-161922Z` | macOS, developer machine, **already authenticated to FloxHub** | No | The last run before the `tar` fix, one minute ahead of `20260802-162020Z` below and superseded by it. Stage 3b bd repackage FAIL (same `./bd` member-filter cause, root-caused in the next run). Stage 4 "PASS" is **contaminated** — logged-in machine, no auth precondition in the harness; ignore it, not an H4 data point (issue #16, trap 4) |
| `20260802-162020Z` | macOS, developer machine, **already authenticated to FloxHub** | No | Stage 3b bd repackage FAIL, **root-caused this run**: the beads release tarball stores entries as `./bd` etc., and the build's `tar -xzf ... bd` member filter never matches that name. Fixed in `envs/repackage/.flox/env/manifest.toml` by extracting the whole archive instead of filtering a member; verified locally (`flox build --dir envs/repackage bd` now succeeds, built `bd --version` runs). Stage 4 "PASS" is contaminated for the same reason as `20260801-201328Z` — ignore it, not a new H4 data point |
| `20260803-122518Z` | macOS, developer machine, **already authenticated to FloxHub** | No | Verifies the issue #16 open-item fix for the Stage 4 false-PASS bug: H1 + H3 all PASS; Stage 4 now correctly reports **SKIP** ("sandbox is already authenticated... not attempted") instead of the old hardcoded false PASS, because the harness now checks `flox auth status` before running show/install/search. Not a new H4/search data point — this Mac is still authenticated — but confirms the fix works |
| `20260803-131301Z` | macOS (Conductor `belgrade` workspace), **already authenticated to FloxHub** | No | Automatic provisioning run (`.conductor/settings.toml`), pre-dates the Phase D MVP work (issue #16 §9). H1 + H3 (all sub-stages) PASS; Stage 4 correctly SKIPs (already-authenticated, same as `20260803-122518Z`) |
| `20260803-134541Z` | macOS (Conductor `belgrade` workspace), deliberately re-authenticated for `TEST_FLOXHUB_PROVISION=1` | No | New **Stage 7 (Phase D MVP) PASS** — `scripts/floxhub-provision.sh` (Infisical-first token lookup, falls back to `FLOXHUB_TOKEN`; `flox auth login --token-file` via `scripts/floxhub-login.sh`; `flox activate` against the combined `envs/floxhub-provision` manifest) resolves and runs all 7 tools (`uv`, `dolt`, `infisical`, `gh`, `git`, `bd` 1.1.2, `roborev` 0.63.0) under `.flox/run/.../bin`. Token confirmed absent from both the report and full log (grepped before committing). Only proven on `aarch64-darwin` so far — `elvis/bd`/`elvis/roborev` aren't yet published for Linux (tracked as an open follow-up, same shape as the original package's PR #7/#8 split). Stage 4's "SKIP" here is the expected already-authenticated result, not a new H4 data point |
| `20260803-144830Z` | Amazon Linux 2023 / Vercel / Conductor cloud, genuinely never authenticated to FloxHub (`FLOXHUB_AUTOLOGIN` not set) | **Yes** | H1 + H3 (all sub-stages) PASS; **first real `flox search` unauthenticated data point (PR #19's probe, finally exercised)**: `flox search elvis/conductor-workspace-floxhub-01` → exit 1, `✘ ERROR: No packages matched this search term: 'elvis/conductor-workspace-floxhub-01'`. `flox show` on the same package → exit 1, `✘ ERROR: no packages matched this pkg-path: 'elvis/conductor-workspace-floxhub-01'`. **Search and show agree** — both fail explicitly and unambiguously, no silent-empty/exit-0 divergence. Stage 4 still correctly records SKIP (not PASS/FAIL), per issue #11's resolution |
| `20260803-150536Z` | Amazon Linux 2023 / Vercel / Conductor cloud | **Yes** | Automatic provisioning run (`.conductor/settings.toml`), genuinely never authenticated (`flox auth status`: logged-out). H1 + H3 (all sub-stages) PASS; Stage 4 correctly SKIPs unauthenticated. Committed just before the deliberate Stage 7 re-run below on this same sandbox |
| `20260803-153233Z` | Same Amazon Linux 2023 / Vercel / Conductor cloud sandbox, deliberately re-authenticated for `TEST_FLOXHUB_PROVISION=1` | **Yes** | **Stage 7 (Phase D MVP) PASS on the real target class** — closes the gap left by `20260803-134541Z` (macOS-only). `scripts/floxhub-provision.sh` resolves and runs all 7 tools (`uv`, `dolt`, `infisical`, `gh`, `git`, `bd` 1.1.2, `roborev` 0.63.0) under `envs/floxhub-provision/.flox/run/x86_64-linux.floxhub-provision-run/bin`. Token confirmed absent from both the report and full log (grepped before committing). Stage 4's SKIP in this same run was captured before Stage 7's auth side effect, so it's not contaminated |
| `20260803-214655Z` | macOS, developer machine, already authenticated to FloxHub | No | Verifies `scripts/floxhub-provision.sh`'s switch from `flox auth login --token-file` to exporting `FLOX_FLOXHUB_TOKEN` directly (Flox's documented CI pattern, see `findings/20260803-171000Z-floxhub-machine-token-cli-mechanics.md`'s follow-up). Stage 7 still PASSes — all 7 tools resolve — with no `flox auth login` call and no keyring/disk credential write. Token confirmed absent from report/full log |
| `20260803-215742Z` | macOS, developer machine, already authenticated to FloxHub | No | Routine default-path run (`FLAKE_REPRO=0`, `TEST_AUTH_PLUMBING=0`, `TEST_FLOXHUB_PROVISION=0`), no opt-in stages exercised. H1 + H3 (all sub-stages) PASS; Stage 4 correctly SKIPs (already-authenticated). Nothing new — committed for the record per this repo's one-commit-per-run convention |

## Current bottom line (as of the last run above)

- **H1** (prebuilt-catalog manifest activates atomically): PASS on every
  environment tested.
- **H3** (`flox build` repackage shape): PASS on the real target class,
  three times. The macOS-only `bd` repackage failures (`20260801-121814Z`,
  `20260801-201328Z`, `20260802-162020Z`) are now root-caused and fixed — the
  release tarball's entries are `./`-prefixed and the build's `tar`
  extraction didn't match, not a target-class issue (see table above).
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
  (An earlier draft also claimed `flox search` can't surface it
  unauthenticated — that was anecdotal from a manual check during PR #9, not
  something the harness ever ran, and issue #16 flagged it as unverified. A
  real `flox search ${FLOXHUB_TEST_PKG}` probe was added to Stage 4 to settle
  it with evidence, and run `20260803-144830Z` — on a genuinely fresh, never-
  authenticated Amazon Linux 2023 / Vercel / Conductor cloud sandbox —
  finally exercised it: `flox search elvis/conductor-workspace-floxhub-01`
  exits 1 with `✘ ERROR: No packages matched this search term:
  'elvis/conductor-workspace-floxhub-01'`, and `flox show` on the same
  package exits 1 with `✘ ERROR: no packages matched this pkg-path:
  'elvis/conductor-workspace-floxhub-01'`. **`flox search` and `flox show`
  agree** — both fail explicitly and unambiguously (nonzero exit, explicit
  "no match" error text), not a silent-empty-result vs. explicit-error
  divergence. The anecdote is now confirmed by evidence.)

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
- **Phase D MVP (Stage 7, new, opt-in):** issue #16 §9's follow-up to
  Stage 6 — prove the *actual* recipe, not just the mechanism. Published
  real `elvis/bd@1.1.2` and `elvis/roborev@0.63.0` packages (the latter
  never attempted before), built a combined `envs/floxhub-provision`
  manifest (the 5 catalog tools + both), and a real setup script
  (`scripts/floxhub-provision.sh`, Infisical-first token acquisition).
  Run `20260803-134541Z`: **PASS** — all 7 tools resolve under
  `.flox/run/.../bin`, but only proven on `aarch64-darwin` at the time.
  Commit `da731ee` closed that gap by publishing `elvis/bd`/`elvis/roborev`
  for `x86_64-linux` too, and run `20260803-153233Z` validated it
  end-to-end on the actual Amazon Linux 2023 / Vercel / Conductor cloud
  target class: **PASS**, same 7 tools resolving, genuinely
  never-before-authenticated sandbox. Phase D MVP (issue #16 §9) is now
  validated on the real target class, not just macOS.
- Nothing from the original hypothesis set is still unexplained. The macOS
  `tar` extraction failure that was open for four runs is root-caused and
  fixed (see the H3 bullet above). Remaining work is tracked as the open-items
  checklist in
  [issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16).

Full narrative synthesis: [PR #3](https://github.com/elviskahoro/flox-conductor-sandbox/pull/3),
and each findings commit's message body (`git log --oneline`, then
`git log -1 <sha>` for the run you care about) — that's where stage-by-stage
analysis lives, not in the generated report files themselves.

## If you're about to add another run

- Read the top-level README's "Running" section first.
- **Before trusting the run's Stage 4 row, grep its full log for
  `You are logged in as elvis on https://hub.flox.dev/`.** Stage 4 has no auth
  precondition, so on an already-authenticated machine it records a PASS reading
  "no token plumbing needed (#445 §6 is dead code)" — a conclusion issue #16
  falsified. Five committed runs already carry that false PASS; don't add a sixth
  without a caveat.
- One commit per run; add findings files by explicit name, never `git add -A`.
- Put a stage-by-stage analysis in the commit body (see recent findings
  commits for the expected shape) — don't hand-edit the generated
  `report-*.md`.
- Update the table above with the new run.
- If you run Stage 5 (`FLAKE_REPRO=1`), check for and remove any
  `envs/flake-repro/.flox/env/manifest.lock` it leaves behind — that env is
  deliberately kept lockless (see top-level README).
