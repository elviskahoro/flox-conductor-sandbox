You're working in flox-conductor-sandbox, a test harness for gtm-sdk#445
("publish bd/roborev to FloxHub as prebuilt binaries — flake source builds
break on Vercel sandbox"). Read README.md and findings/README.md first, then
read issue #16 in full — it's the single source of truth, carries the
verdict, evidence index, traps not to re-derive, and the open Phase D MVP
plan (§9). Base your work on main.

## The gap

PR #22 (Phase D MVP) published `elvis/bd` and `elvis/roborev` to FloxHub —
but only from a macOS (aarch64-darwin) machine. `envs/floxhub-provision/.flox/env/manifest.toml`
scopes both packages to `bd.systems = ["aarch64-darwin"]` /
`roborev.systems = ["aarch64-darwin"]` with a comment explicitly flagging
this as a known, tracked gap (not a silent workaround): the Conductor cloud
target class is x86_64-linux, and bd/roborev don't resolve there yet.

Your task: publish both packages for x86_64-linux from this sandbox, then
widen the manifest back to both systems.

This is a distinct task from the `sanhedrin`-org / Stage 6 publish gap
(already closed, see `prompts/20260803-135843Z-sanhedrin-org-linux-publish-handoff-v2.md`
for that precedent) — do not conflate the two. This one is about `elvis/bd`
and `elvis/roborev` (personal catalog), not `sanhedrin/conductor-workspace-floxhub-01`.

## Steps

1. Confirm environment: `uname -m` (must be x86_64), `flox --version`
   (tested against 1.14.0).
2. Confirm auth: `flox auth status`. FloxHub auth now happens automatically
   via FLOXHUB_TOKEN in sandbox setup (fixed ordering bug, see
   `.conductor/settings.toml`'s `scripts.setup` — the auth-login block now
   runs after `scripts/sandbox-test.sh` installs the `flox` binary) — check
   `~/.conductor-setup.log` if not already logged in before treating it as
   a blocker.
3. Read `envs/repackage/.flox/env/manifest.toml`'s `[build.bd]` and
   `[build.roborev]` targets in full — confirm they're unchanged from
   what's already published for aarch64-darwin (version pins: bd 1.1.2,
   roborev 0.63.0). Do not touch envs/repackage or the build definitions.
4. Verify `flox publish`'s preconditions: `git status --short` must be
   completely empty (any dirty tracked file, even unrelated, blocks
   publish per `man flox-publish` — clean-repo + pushed-revision
   requirements; also confirm your branch has an upstream remote set and
   is pushed before publishing, or `flox publish` will refuse). If the
   tree isn't clean, stop and say so rather than resolving it yourself —
   except self-generated `findings/full-log-*.txt` / `findings/report-*.md`
   pairs dropped by this repo's own setup harness, which are expected and
   harmless to leave untouched.
5. Publish both:
   ```
   flox publish -d envs/repackage -o elvis bd
   flox publish -d envs/repackage -o elvis roborev
   ```
   (No `-o` needed if publishing to the personal catalog is the existing
   convention here — check how PR #22's original publish was invoked and
   match it; do not switch either package to the `sanhedrin` org catalog,
   that's a separate, undecided question, issue #16 §7.)
6. Verify: `flox show elvis/bd` and `flox show elvis/roborev` should each
   now list aarch64-darwin AND x86_64-linux under Systems.
7. Edit `envs/floxhub-provision/.flox/env/manifest.toml`: widen
   `bd.systems` and `roborev.systems` back to
   `["aarch64-darwin", "x86_64-linux"]` (or drop the per-package systems
   overrides entirely if the env-wide `[options].systems` already covers
   both — check which is cleaner). Update or remove the comment describing
   the gap since it'll be closed. Regenerate `manifest.lock` by running
   `bash scripts/floxhub-provision.sh` (opt-in script — see its own header
   for token requirements) or `flox activate --dir envs/floxhub-provision --mode run -- true`
   directly if already authenticated. Confirm bd/roborev both resolve and
   run (`bd version`, `roborev --version` or equivalent) on this
   x86_64-linux sandbox.
8. Do not touch `envs/repackage`'s build targets, `envs/floxhub-consume`,
   the `sanhedrin` org catalog, the machine-token decision (§7), or Stage
   4/flox-search work — all separate, tracked threads.

## Git workflow

1. Branch off main with an `agent/` prefix (e.g.
   `agent/bd-roborev-linux-publish`).
2. Commit the manifest + lock changes together, with a message stating
   plainly what was published and verified (packages, platform, commands
   run, `flox show` output confirming both systems).
3. Run `git roborev review --wait` before pushing. If genuinely
   unavailable (no binary on $PATH, no `git roborev` subcommand — check
   both before concluding this), say so explicitly and check with the repo
   owner before pushing rather than skipping the gate yourself.
4. Push and open a PR against main with a Summary + Test plan checklist,
   matching the style of recent PRs. Do not merge it yourself unless
   explicitly asked.

## Deliverable

A PR against main that publishes elvis/bd and elvis/roborev for
x86_64-linux, widens envs/floxhub-provision's manifest back to full
platform coverage with a regenerated lock, and documents exactly what was
published/verified so the next reader doesn't have to re-derive it.
