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
| 3 | **H3:** `flox build` manifest builds work here — a trivial no-network build, then the real Option-A shape: repackage pinned, checksum-verified `bd` and Hookdeck upstream release binaries into `$out/bin`; verify the `bd` CLI flag surface the gtm-sdk setup script depends on | Phase B "Option 1" + Phase C flag-surface check | **PASS** on target class (2 non-target environments hit unrelated, environment-specific issues) |
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
scripts/conductor-startup-script-cloud.sh  the single workspace startup script: pinned roborev/trunk/rwx + python3.11 for the AL2023 class + opt-in uv/pytest/reflex (issue #44) + rwx auth + roborev config/daemon (reviews on demand with --wait, never a background auto-review hook) — wired into this repo's setup, and paste-ready for other repos' workspaces
scripts/validate-pins.sh  pin-drift check: roborev/trunk pins vs the Flox manifests and the trunk preflight (CI)
scripts/conductor-startup-script-cloud-test.sh  codified amazonlinux:2023 container verification of conductor-startup-script-cloud.sh (CI)
prompts/conductor/   canonical cross-repo Conductor prompts (create-pr.md today)
                    — see prompts/README.md; installed into .conductor/settings.toml
                    by scripts/install-conductor-prompts.py, drift-checked in CI
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

### The startup script — this repo's setup, paste-ready for other repos

`scripts/conductor-startup-script-cloud.sh` is the single provisioning
script (it replaced the former conductor-cloud-install.sh +
conductor-startup-script.sh pair, whose duplicated pins were exactly the
drift class `scripts/validate-pins.sh` was built to catch): the pinned,
checksum-verified roborev, trunk, and rwx binaries, Python 3.11 on the
AL2023 sandbox class (whose system python3 is 3.9 while pyproject.toml
requires >=3.11; reuse-if-present and SKIP elsewhere, so pasting it into a
repo that needs neither costs nothing), plus the pieces that make the
tools work rather than merely exist — `RWX_ACCESS_TOKEN` validated before
it is atomically persisted to `~/.config/rwx/accesstoken` (a bad token
never overwrites a good one), roborev repo config written directly plus
an ensured daemon and an agent smoke check. Reviews in a provisioned
workspace are **on demand and blocking** — the push gate the repo's agent
instructions and the create-pr prompt define is `roborev review --wait` —
so the script **never installs a post-commit auto-review hook**: `roborev
init` is never run (it installs the post-commit/post-rewrite hooks and
has no flag to suppress that), `.roborev.toml` is written directly, a
leftover roborev hook from an older setup (or a bare `roborev init`) is
actively removed, and when `core.hooksPath` points at a machine-global
hooks dir nothing is ever written there (a WARN tells the user to remove
any roborev hook found in it by hand; a foreign hook is never replaced).
The reasoning: roborev's post-commit entry point can only enqueue a
background daemon job — it has no blocking form — so an auto-review hook
means reviews drift out of the caller's hands and findings surface after
the fact, while the gate treats "enqueued" as *not passed*. This repo's
`.conductor/settings.toml` runs it directly as its setup's provisioning
step. For repos without a committed `.conductor/settings.toml` setup,
paste the file's contents into the setup-script field in the Conductor
GUI (stored as `scripts.setup`) — Conductor exposes no API for setting
that field, so the GUI paste is the only mechanism; the file keeps the
paste-safety constraints (no triple-double-quotes, no backslash
line-continuations) that Conductor's TOML serialization requires, and
`scripts/validate-pins.sh` enforces them in CI. Set `RWX_ACCESS_TOKEN` —
and optionally `ROBOREV_AGENT` (default `claude-code`) — in the same
settings' environment variables, never inline in the script. The rwx
pin's sibling copy in gtm-sdk's conductor-workspace-setup.sh is
comment-synced (that repo is private, so no machine check reaches it).

### Python dev tools: uv, pytest, Reflex (opt-in, issue #44)

A fresh Conductor cloud workspace has Python but not the Python dev
tools agents need: `uv` and `reflex` are not on PATH (the Flox manifests'
uv is process-scoped — activation-only), and `python3 -m pytest` fails
with `No module named pytest`. The startup script therefore carries an
opt-in stage, enabled by `STARTUP_PY_DEV_TOOLS=1`, which this repo's
`.conductor/settings.toml` exports. Pasted standalone (or in a repo that
sets only its own flags) the stage records a SKIP row and the surface is
unchanged.

What it provisions:

- **uv** — the pinned, checksum-verified release binary
  (`UV_PIN="0.11.26"` in the startup script, deliberately the same
  version `envs/prebuilt` and `envs/floxhub-provision` pin;
  `scripts/validate-pins.sh` cross-checks all three in CI), placed in
  `/usr/local/bin` like every other persistent tool, with the same
  `~/.local/bin` no-sudo fallback.
- **pytest + Reflex** — exact-pinned Python packages (`PYTEST_PIN="9.1.1"`,
  `REFLEX_PIN="0.9.12"`, single-homed in the startup script and
  shape-checked by `scripts/validate-pins.sh`) installed into one
  uv-managed venv at `~/.conductor-pytools`, Python 3.11 — the system 3.11
  the startup script installs on the AL2023 class, or a uv-managed
  CPython 3.11 download elsewhere. The console scripts are symlinked into
  the same bin dirs, so later agent shells get `pytest` and `reflex` as
  commands.

That venv is the intended Python environment for the two packages (the
issue's managed-environment allowance), so the supported invocations are:

```bash
pytest --version                                   # command form
reflex --version
~/.conductor-pytools/bin/python -m pytest ...       # module form
~/.conductor-pytools/bin/python -c 'import reflex'
```

Bare `python3 -m pytest` in an arbitrary later shell is not one of them —
the system python3's site-packages stay clean; use the venv's interpreter
(or activate `~/.conductor-pytools`) instead. The stage provisions the
Reflex *package* (`reflex --version`, `import reflex`); Reflex's frontend
toolchain (bun/node, needed by `reflex init`/`reflex run`) is out of
scope.

Availability and version policy: every run records each tool's resolved
version and path in the startup summary (and `~/.conductor-setup.log`).
Re-running setup reuses what is already functional, with the split the
stage body documents: uv is reused as-is when functional — the same
reuse-if-present contract as roborev/trunk/rwx, with the resolved version
recorded in its row — so a `UV_PIN` bump applies to fresh installs (and
to re-running after removing a stale binary), while
`scripts/validate-pins.sh` guards the file-level drift against the Flox
manifests; the pytest/reflex pins are satisfied in place — left untouched
when they already match, upgraded or healed in place when stale — so the
venv never accumulates duplicate or competing installs. Every run
re-proves the commands, the module invocation, and the import, so a
reused install is verified, not presumed. A provisioning failure is fatal
under both failure postures (default and `STARTUP_BEST_EFFORT=1`): the
stage only runs when the workspace explicitly requested these tools, and
a requested tool that cannot be provisioned must fail setup loudly, never
leave a workspace that appears ready but lacks them. Pin bumps: uv must
be bumped in the startup script and both Flox manifests (and their locks)
together; pytest/reflex live only in the startup script.

### Standardized Conductor prompts for other repos' workspaces

`prompts/conductor/` is the canonical home for Conductor prompts shared
across repos (ported from gtm-sdk's `prompts/conductor/create-pr.md`). The
same drift class `scripts/validate-pins.sh` guards against applies here:
Conductor only reads prompts from each repo's `.conductor` settings TOML,
and gtm-sdk's hand-maintained inline copy drifted from its `.md` source (the
TOML still said `git roborev` after gtm-sdk#921 fixed the `.md`). So the
`.md` files are the single source of truth and
`scripts/install-conductor-prompts.py` is the only way they get into a
repo's settings — preserving comments and unrelated keys, idempotent, with
a `--self-test` behavior matrix and `--check` drift guard both wired into
the `conductor-startup-script-cloud checks` workflow for this repo, and available
to any consuming repo:

```bash
# from inside the target repo — script path must be absolute (uv run
# resolves it against cwd, not --project); --no-project --with tomlkit
# skips the full dependency sync
uv run --no-project --with "tomlkit>=0.15.1" \
    /path/to/flox-conductor-sandbox/scripts/install-conductor-prompts.py --check
```

See [`prompts/README.md`](prompts/README.md) for the slot mapping, the
`--local`/`--print` variants, and exactly what was standardized from
gtm-sdk's version.

### Pulling Beads tickets from DoltHub

This repository can initialize and refresh its Beads database from the
private DoltHub remote `dolthub://elviskahoro/gtm-sdk`. Pulling is
manual only (#45 removed the automatic startup pull along with the rest
of Beads from the Conductor setup path) — run the script below by hand
when you want a refresh.

DoltHub remotes authenticate with a Dolt credential JWK, rather than a
generic API token. On an authenticated machine, create or select a credential
with `dolt creds new` (or `dolt login`), register its public key in DoltHub,
and store the private JWK contents in Infisical as
`DOLTHUB_DOLT_CREDENTIAL_JWK`. The secret must be the JWK JSON itself; do not
commit it or put it in a repository config file.

For a manual pull, or to refresh outside workspace setup, run this with
`INFISICAL_TOKEN` and `INFISICAL_PROJECT_ID` available in the shell:

```bash
bash scripts/beads-dolthub-pull.sh
bd ready --json
bd list --json
bd show <bead-id>
```

The script imports the JWK into a temporary Dolt credential directory and
removes that directory on exit. The local `.beads` database and remote
configuration are retained for subsequent pulls. Override the defaults when
needed with `BEADS_DOLTHUB_REMOTE` and
`DOLTHUB_DOLT_CREDENTIAL_SECRET_NAME`; use `INFISICAL_ENV` for a non-`dev`
Infisical environment.

The harness writes `findings/report-<UTC timestamp>.md` with a PASS/FAIL/SKIP
table plus evidence, and a full transcript alongside. Commit the findings back
(or paste the report into #445).

### Pulling Linear AI issues into local Beads

This repository also includes an opt-in Linear intake pilot. It creates a
separate stealth `.beads` database in the workspace and pulls issues from the
Linear **AI** team. Linear remains authoritative: the workflow is pull-only,
does not configure a DoltHub remote, and is never run automatically by
Conductor setup.

The script reads `LINEAR_API_KEY` from Infisical using the existing
`INFISICAL_TOKEN` and `INFISICAL_PROJECT_ID` environment variables. The API key
is held only in the process environment and is not written to the repository:

```bash
bash scripts/beads-linear-pull.sh --dry-run  # preview the first pull
bash scripts/beads-linear-pull.sh             # import/update local issues
bd ready --json
bd list --json
bd linear status --json
```

For an already initialized pilot database, the equivalent explicit pull is:

```bash
LINEAR_API_KEY="$(infisical secrets get LINEAR_API_KEY --env=dev \
  --projectId "$INFISICAL_PROJECT_ID" --plain)" \
  bd linear sync --pull --relations
```

The Linear script refuses to reuse a `.beads` database that already has a
configured Dolt remote, preventing this pilot from mixing with the separate
DoltHub-backed Beads workflow above. It is safe to run repeatedly; existing
Linear references are updated rather than duplicated.

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
`aarch64-linux`; that platform is intentionally out of scope because it is
not a Conductor target and the published `bd`/`roborev` packages do not cover
it.

### Staging check: the provisioning recipe in a disposable container (Dagger)

Stage 7 above proves the recipe by authenticating *this* sandbox — which is
exactly the trade-off issue #16 trap 5 warns against (an authenticated
sandbox can never again serve as the Stage 4/H4 unauthenticated tester).
`scripts/dagger_provision_test.py` gets the same proof without that cost: it
spins up a throwaway `amazonlinux:2023` container (matching the real target
class), bootstraps `flox` the same way Stage 1 does, runs
`scripts/floxhub-provision.sh` unmodified inside it, and verifies all 7 tools
resolve — then the container is discarded. This workspace's own Flox auth
state never changes.

```bash
TOKEN="$(flox auth token)"   # run on an already-authenticated machine
FLOXHUB_TOKEN="${TOKEN}" uv run dagger run python scripts/dagger_provision_test.py
```

Unlike `scripts/floxhub-provision.sh`'s own Infisical-first lookup, this
pipeline always takes `FLOXHUB_TOKEN` directly from the environment — no
Infisical fallback for this particular token, by deliberate choice: Infisical
is for downstream/consumed secrets, not for FloxHub's own bootstrap
credential here. The script fails fast (no silent unauthenticated fallback)
if `FLOXHUB_TOKEN` is unset. Requires `uv` and the `dagger` CLI on `PATH`
locally. Same opt-in-only rule as Stage 6/7: never wire this into
`.conductor/settings.toml` or `scripts/sandbox-test.sh`'s default path.

**Cannot be run from a Conductor cloud workspace itself** — it's already a
nested container, and Dagger's engine needs cgroups/overlayfs access that
isn't available there. For a real, non-emulated `x86_64-linux` run (the
actual target class, and the only way to get the full 7/7 check including
`bd`/`roborev`), use the manual GitHub Actions workflow instead:
[`.github/workflows/floxhub-provision-check.yml`](.github/workflows/floxhub-provision-check.yml),
triggered via `workflow_dispatch` (Actions tab, or
`gh workflow run floxhub-provision-check.yml`). It reads `FLOXHUB_TOKEN` from
a repo secret of the same name.

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
  scopes for `gtm-sdk/scripts/conductor-workspace-setup.sh`. It is expected
  to PASS on both supported systems, `aarch64-darwin` and `x86_64-linux`;
  `aarch64-linux` is intentionally outside the Conductor support policy.

## Known scope reductions

- **`elvis/bd@1.1.2` and `elvis/roborev@0.63.0` are published for both
  supported systems**, `aarch64-darwin` and `x86_64-linux`. The manifest pins
  those versions and excludes `aarch64-linux`, which is not a Conductor target.
- No DoltHub/beads-DB bootstrap, no uv sync — tool *provisioning* is the
  main thing under test (Stage 7 does exercise real Infisical-first token
  acquisition in `scripts/floxhub-provision.sh`, but doesn't bootstrap any
  Infisical secrets beyond that one lookup). The startup script does
  provision the uv binary itself in the persistent environment when
  `STARTUP_PY_DEV_TOOLS=1` is set (issue #44), but it never syncs this
  repo's own Python project environment.
- The repackage env carries `curl`/`gnutar`/`gzip`/`coreutils`/`cacert` as
  build-time deps because `sandbox = "off"` builds run inside the activated
  env. If gtm-sdk adopts this shape, those deps land in whatever env hosts
  the `[build]` sections (or the builds move to a dedicated publish env) —
  a real tradeoff this test is meant to surface.
