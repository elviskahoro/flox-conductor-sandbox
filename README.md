# flox-conductor-sandbox

Minimal-scope test bed for [elviskahoro/gtm-sdk#445](https://github.com/elviskahoro/gtm-sdk/issues/445):
*"Publish bd/roborev to FloxHub as prebuilt binaries — flake source builds
break on Vercel sandbox."*

This repo isolates the load-bearing unknowns of that issue's plan into the
smallest possible harness, so a fresh Conductor cloud sandbox can answer
"is the proposed fix even possible?" in one provisioning run — before any
real FloxHub publishing work is invested in gtm-sdk itself.

## Current status

> **Start here: [issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16)**
> — the single source of truth for gtm-sdk#445 Phase A. It carries the verdict, the
> full evidence index (including which runs are contaminated), the traps not to
> re-derive, and what's still open. It supersedes issues #4, #5, and #11, whose
> bodies contain instructions that later work falsified.

On the actual target sandbox class (Amazon Linux 2023 / Vercel / Conductor
cloud), flox bootstraps cleanly, **H1 and H3 both PASS**, and **H2's control
repro also PASSes** — confirming this sandbox genuinely has the defect #445
describes, which is what makes the H1/H3 passes real evidence rather than an
artifact of an easier environment. **H4 was run on a genuinely fresh,
never-authenticated sandbox and came back SKIP, not PASS/FAIL**: the
published package is confirmed to exist, but `flox show` itself fails
unauthenticated, so the harness never reaches the `flox install` step.
**Resolved (issue #11): SKIP is the correct, expected result.**
`flox publish` (no `--org`) always publishes to the publisher's private
catalog — there is no flag to make a package publicly fetchable, per `flox
publish --help` and https://flox.dev/docs/concepts/publishing/. Phase D'
(FloxHub auth-token plumbing, §6) **is needed** for any real unauthenticated
consumption of a FloxHub-hosted package.

14 runs exist so far across three environment classes (a non-target
container, macOS, and the target sandbox class). For the full run-by-run
breakdown, see [`findings/README.md`](findings/README.md) — that table is the
definitive count, not this sentence; for the narrative writeup, see
[PR #3](https://github.com/elviskahoro/flox-conductor-sandbox/pull/3).

## Hypotheses under test

| Stage | Hypothesis | Maps to #445 | Result |
|---|---|---|---|
| 1 | Flox itself bootstraps on this sandbox class (rpm/deb install, `/dev/fd` shim, hand-started `nix-daemon`) | precondition for everything | **PASS** on target class |
| 2 | **H1 (core):** a manifest containing *only* prebuilt catalog packages (`pkg-path`) — the exact five gtm-sdk uses (`uv` pinned 0.11.26, `dolt`, `infisical`, `gh`, `git`) — materializes cleanly via one atomic `flox activate`, with every tool resolving under `.flox/run/.../bin` | "Why this should fix dolt/infisical/gh/git provisioning too" | **PASS** — all 3 environments tested |
| 3 | **H3:** `flox build` manifest builds work here — a trivial no-network build, then the real Option-A shape: repackage the official `beads` v1.1.2 release binary (pinned URL + sha256) into `$out/bin`, then verify the CLI flag surface the gtm-sdk setup script depends on | Phase B "Option 1" + Phase C flag-surface check | **PASS** on target class (2 non-target environments hit unrelated, environment-specific issues) |
| 4 | **H4 (the fork in the road):** an unauthenticated sandbox can fetch a package from a project-controlled FloxHub catalog (`flox install <owner>/<pkg>`) | Phase A preflight — decides whether token plumbing (§6) is needed | **SKIP** — resolved (#11): expected. Bare `flox publish` is private-by-default; §6 token plumbing is needed |
| 5 | **H2 (control, opt-in):** the `bd.flake = "github:gastownhall/beads/v1.1.0"` source build reproduces the `/homeless-shelter` purity failure on this sandbox, confirming root-cause attribution | "Problem" section repro | **PASS** — target class confirmed to share the defect |
| 6 | **Phase D' prototype (opt-in):** an authenticated sandbox (`scripts/floxhub-login.sh`) can `flox activate` a manifest whose `[install]` references the published `pkg-path` (`envs/floxhub-consume`) — the real gtm-sdk consumption pattern, not Stage 4's ad hoc `flox install` | #445 §6 — proves the auth-token recipe before porting it to gtm-sdk | opt-in, not yet run by default |
| 7 | **Phase D MVP (opt-in):** `scripts/floxhub-provision.sh` (token → `flox auth login` → `flox activate`) against `envs/floxhub-provision`, a *combined* manifest — the same 5 catalog tools plus real `elvis/bd`/`elvis/roborev` packages published from `envs/repackage`, not Stage 6's trivial smoke package | #445 §9 — the actual recipe for `gtm-sdk/scripts/conductor-workspace-setup.sh`, proven here first | opt-in, PASS on `aarch64-darwin`; `elvis/bd`/`elvis/roborev` not yet published for Linux (see [Known scope reductions](#known-scope-reductions)) |

## Layout

```
envs/prebuilt/        H1: gtm-sdk's five catalog packages, zero flake pins
envs/repackage/       H3: [build.conductor-workspace-floxhub-01] + [build.bd] (upstream-binary repackage)
envs/flake-repro/     H2: the failing bd flake pin, nothing else (opt-in stage)
envs/floxhub-consume/ Phase D' prototype: [install] pkg-path = "elvis/conductor-workspace-floxhub-01" (opt-in stage 6, needs auth)
envs/floxhub-provision/ Phase D MVP: [install] the 5 catalog tools + elvis/bd + elvis/roborev (opt-in stage 7, needs auth)
scripts/sandbox-test.sh   the harness — runs all stages, never hard-fails
scripts/floxhub-provision.sh  Phase D MVP setup-script recipe (token → login → activate envs/floxhub-provision)
findings/          harness output: report-*.md (summary + evidence) and full-log-*.txt
                   — see findings/README.md for a run-by-run index
```

Each env is a self-contained Flox environment (own `.flox/env.json` +
`manifest.toml`) so stages are isolated: a failing stage cannot poison the
others the way the atomic activation in gtm-sdk does today.

`manifest.lock` files for `envs/prebuilt` and `envs/repackage` are committed
(generated by the first smoke run), matching gtm-sdk's lock-committed flow —
so Stage 2 tests exactly what a fresh gtm-sdk sandbox would do: materialize
from a lock. In-sandbox resolution *without* a lock was already validated in
the first smoke run (32s including locking; see
`findings/report-20260801-021231Z.md`). `envs/flake-repro` stays lockless —
locking a flake pin requires fetching/evaluating the flake, which is the very
thing under test there.

## Running

A Conductor sandbox runs everything automatically via
`.conductor/settings.toml` → `scripts/sandbox-test.sh`, logging to
`$HOME/.conductor-setup.log`. Manually:

```bash
bash scripts/sandbox-test.sh                      # stages 0–4
FLAKE_REPRO=1 bash scripts/sandbox-test.sh        # also run the H2 failure repro (slow: real Go build attempt)
FLOXHUB_TEST_PKG=elvis/conductor-workspace-floxhub-01 bash scripts/sandbox-test.sh  # (default shown)
TEST_AUTH_PLUMBING=1 FLOXHUB_TOKEN=<token> bash scripts/sandbox-test.sh  # opt-in Phase D' prototype (stage 6) — permanently authenticates this sandbox
TEST_FLOXHUB_PROVISION=1 FLOXHUB_TOKEN=<token> bash scripts/sandbox-test.sh  # opt-in Phase D MVP (stage 7) — permanently authenticates this sandbox
```

The harness writes `findings/report-<UTC timestamp>.md` with a PASS/FAIL/SKIP
table plus evidence, and a full transcript alongside. Commit the findings back
(or paste the report into #445).

### Authenticating a publisher sandbox

Stage 4 (H4) only means anything if the sandbox running it has *never*
authenticated to FloxHub. Publishing a package (`flox publish`, needed for
Phase A3 / #445 §6 preflight) requires the opposite: an authenticated
sandbox. `scripts/floxhub-login.sh` bridges that gap non-interactively.

**As of PR #23/#25, `.conductor/settings.toml`'s `scripts.setup` now calls
`flox auth login` automatically whenever `FLOXHUB_TOKEN` is present in the
sandbox's environment** (see the setup script for the exact guard). This is
a deliberate, accepted tradeoff: any sandbox provisioned with
`FLOXHUB_TOKEN` set is permanently authenticated and **cannot** be used as
the never-authenticated Stage 4 tester. If you need to re-run Stage 4, use
a sandbox/workspace that deliberately does not have `FLOXHUB_TOKEN` set —
e.g. don't set it at the Conductor user level for that workspace, or run
Stage 4 before ever setting the token on that machine.

flox 1.14.0+ supports non-interactive login via `flox auth login
--token-file=PATH` and `flox auth token` (prints the current token on an
already-authenticated machine). flox 1.13.2 has neither. To turn a sandbox
into a publisher:

1. On an already-authenticated machine, run `flox auth token` to print a
   token.
2. Hand it to the target sandbox. Conductor's `.conductor/settings.toml`
   schema has an `environment_variables` facility (with `local`/`cloud`
   scoping) and `environment_variable_files`, but no dedicated secrets table —
   values there are plain strings with no masking/encryption. Prefer whatever
   secret-safe channel your operator setup already uses over hardcoding a
   token in that file.
3. With `FLOXHUB_TOKEN` set in the target sandbox's environment, run:
   ```bash
   FLOXHUB_TOKEN=<token> bash scripts/floxhub-login.sh
   ```
   The script fails loudly if `FLOXHUB_TOKEN` is unset (no silent fallback to
   interactive login) and never persists the token anywhere but a
   `mktemp`/`umask 077` tempfile, shredded on exit.
4. A sandbox that runs this script is now authenticated and permanently
   disqualified from ever being the unauthenticated Stage 4 tester — use a
   separate, never-touched sandbox for that.

### Prototyping the consumer side (Phase D', opt-in, manual only)

Once Stage 4 confirms (as it now has, per issue #11) that the catalog is
private, the actual question for gtm-sdk#445 §6 is whether a sandbox can
authenticate *and then consume* the package the way gtm-sdk really would —
via a `pkg-path` in `[install]`, materialized by `flox activate`, not an
ad hoc `flox install`. `envs/floxhub-consume/.flox/env/manifest.toml`
exists for exactly this and Stage 6 of `scripts/sandbox-test.sh` tests it,
opt-in only (same reasoning as `floxhub-login.sh` above — running this on
the sandbox you also want to use for Stage 4 disqualifies it):

```bash
TOKEN="$(flox auth token)"   # run on an already-authenticated machine
TEST_AUTH_PLUMBING=1 FLOXHUB_TOKEN="${TOKEN}" bash scripts/sandbox-test.sh
```

Stage 6 reuses `scripts/floxhub-login.sh` verbatim to authenticate, then
`flox activate --dir envs/floxhub-consume --mode run -- true` and checks
the binary resolves under `.flox/run/.../bin`, mirroring Stage 2's
verification. A PASS here is the recipe to port into
`gtm-sdk/scripts/conductor-workspace-setup.sh`: obtain a token (in real
gtm-sdk provisioning, from Infisical via `infisical secrets get`, not a
hand-copied value — see this repo's parent secrets-management convention)
→ `flox auth login --token-file=...` → `flox activate` against a manifest
that lists the FloxHub `pkg-path`.

### Prototyping the full MVP (Phase D, opt-in, manual only)

Stage 6 proves the auth-token *mechanism* with a single trivial package.
Issue #16 §9's Phase D MVP goes one step further: prove the *actual*
recipe `gtm-sdk/scripts/conductor-workspace-setup.sh` needs — the 5
catalog tools plus real `bd`/`roborev` packages, obtained via one script
rather than assembled by hand in the harness. `scripts/floxhub-provision.sh`
is that script (token → `flox activate` against `envs/floxhub-provision`),
and Stage 7 of `scripts/sandbox-test.sh` runs it and verifies all 7 tools,
opt-in only, same reasoning as Stage 6:

```bash
TOKEN="$(flox auth token)"   # run on an already-authenticated machine
TEST_FLOXHUB_PROVISION=1 FLOXHUB_TOKEN="${TOKEN}" bash scripts/sandbox-test.sh
# or, standalone, without the harness:
FLOXHUB_TOKEN="${TOKEN}" bash scripts/floxhub-provision.sh
```

`scripts/floxhub-provision.sh` tries Infisical first (`infisical secrets
get FLOXHUB_TOKEN --plain`, secret name overridable via
`FLOXHUB_TOKEN_SECRET_NAME`) before falling back to a `FLOXHUB_TOKEN` env
var already set — no interactive fallback either way. The resolved token is
exported as `FLOX_FLOXHUB_TOKEN` and read directly by `flox activate` —
Flox's own documented CI pattern
([flox.dev/docs/tutorials/ci-cd](https://flox.dev/docs/tutorials/ci-cd)).
No `flox auth login` step, no credential written to the keyring or to disk:
confirmed working from a completely fresh, never-authenticated `$HOME`.
Flox's docs recommend backing this with a dedicated low-privilege FloxHub
service account rather than a real person's token, to keep CI blast radius
scoped to read/install only. **Known gap:** `elvis/bd`/`elvis/roborev` are
so far only published for `aarch64-darwin` and `x86_64-linux` (see [Known
scope reductions](#known-scope-reductions)); Stage 7 doesn't yet PASS on
`aarch64-linux`.

## Interpreting outcomes

- **Stage 2 PASS** → #445's central claim holds: remove the flake pins and the
  whole gtm-sdk manifest materializes; the curl fallbacks stop firing.
- **Stage 3 PASS** → the Option-A `[build]` shape (repackage upstream release
  binaries) is viable as the publish source, and bd v1.1.2's flag surface is
  compatible with `conductor-workspace-setup.sh`.
- **Stage 4** — run on a genuinely fresh, never-authenticated sandbox
  (`20260801-160419Z`): result is **SKIP, not PASS/FAIL**.
  `elvis/conductor-workspace-floxhub-01` is confirmed published for both
  `aarch64-darwin` and `x86_64-linux` (see
  `findings/floxhub-x86_64-linux-publish-20260801.md`), but `flox show`
  itself fails to find it unauthenticated — the harness never reaches the
  `flox install` step PASS/FAIL depends on. **Resolved (issue #11):** this
  is expected, not a misconfiguration. `flox publish` (the bare form used in
  PR #7/#8, no `-o`/`--org`) always lands in the publisher's **private**
  catalog — per `flox publish --help` and
  https://flox.dev/docs/concepts/publishing/, "individual users will not be
  able to share packages they've published with other users," and the only
  visibility knob (`--org`) is a paid feature that shares with an
  organization, never the general public. There is no way to make a
  `flox publish`-ed package fetchable unauthenticated. Phase D' (#445 §6
  token plumbing) **is required** for real unauthenticated/CI usage. (A
  later, uncommitted-until-now run, `20260801-201328Z`, logged this stage as
  PASS with a "no token plumbing needed" conclusion — that run's own log
  shows it executed on an already-authenticated machine, so its PASS does
  not test unauthenticated access and that conclusion is superseded by the
  above.)
- **Stage 5 PASS (opt-in)** = the repro fails with `/homeless-shelter`,
  confirming this sandbox has the same single-user/no-sandbox Nix defect the
  issue describes. If it *succeeds*, this sandbox class differs from the one
  in #445 and Stage 2's PASS is weaker evidence.
- **Stage 6 PASS (opt-in)** = the Phase D' auth-token recipe works
  end-to-end (`flox auth login --token-file` then `flox activate` against a
  `pkg-path` manifest) — this is the concrete mechanism to port into
  `gtm-sdk/scripts/conductor-workspace-setup.sh`. A FAIL here means the
  recipe itself needs rework before porting, not just the visibility
  conclusion from Stage 4.
- **Stage 7 PASS (opt-in)** = the Phase D MVP setup script
  (`scripts/floxhub-provision.sh`) works end-to-end against the *combined*
  manifest (5 catalog tools + real `elvis/bd`/`elvis/roborev`), not just
  Stage 6's single trivial package — this is the actual recipe issue #16 §9
  scopes for `gtm-sdk/scripts/conductor-workspace-setup.sh`. Currently only
  PASSes on `aarch64-darwin`, since `elvis/bd`/`elvis/roborev` aren't yet
  published for Linux (see Known scope reductions below) — a FAIL/SKIP on a
  Linux sandbox right now means that, not a recipe defect.

## Known scope reductions

- **`elvis/bd` and `elvis/roborev` are only published for `aarch64-darwin`
  so far** (issue #16 §9). `flox publish` only publishes the host's own
  system (trap 6) — the original throwaway package needed a separate Mac
  publish (PR #7) and Linux publish (PR #8) for the same reason; the same
  follow-up is still needed here before Stage 7 / `envs/floxhub-provision`
  work on the actual `x86_64-linux` Conductor cloud target class.
- No DoltHub/beads-DB bootstrap, no uv sync — tool *provisioning* is the
  main thing under test (Stage 7 does exercise real Infisical-first token
  acquisition in `scripts/floxhub-provision.sh`, but doesn't bootstrap any
  Infisical secrets beyond that one lookup).
- The repackage env carries `curl`/`gnutar`/`gzip`/`coreutils`/`cacert` as
  build-time deps because `sandbox = "off"` builds run inside the activated
  env. If gtm-sdk adopts this shape, those deps land in whatever env hosts
  the `[build]` sections (or the builds move to a dedicated publish env) —
  a real tradeoff this test is meant to surface.
