# Trunk CLI env-var setup mechanics — exploration findings

Research for running `trunk check` in Conductor cloud workspaces
(AL2023/Vercel sandboxes, provisioned by
`scripts/conductor-cloud-install.sh` + `scripts/conductor-trunk-preflight.sh`)
configured **entirely through environment variables** — no interactive
`trunk init`, no browser `trunk login`, no hand-edited machine state.

Method: read the launcher bash script that both install scripts already
pin and deploy (`/opt/homebrew/bin/trunk`, launcher 1.3.4 — byte-identical
role to the `trunk.io/releases/trunk` artifact the cloud scripts install),
`strings` on the real CLI binary it manages
(`~/.cache/trunk/cli/1.25.0-darwin-arm64/trunk`, the version this repo's
`.trunk/trunk.yaml` pins), the public docs (docs.trunk.io), and live
empirical runs on this sandbox with a scratch `TRUNK_CACHE`. Trunk
publishes no env-var reference page, so the binary and launcher source are
the ground truth here.

## Verdict

**Yes — everything a cloud workspace needs is env-var-only, with one
exception: the repo's lint config.** Trunk Code Quality is local and
intentionally unauthenticated (this repo's `.conductor/settings.toml`
already relies on that: setup runs `trunk check --ci --no-fix --all` on a
fresh sandbox with no token and no login). The env vars cover version
pinning, cache placement, output behavior, telemetry, proxies, and — if
wanted later — authenticated upload. The one thing no env var can supply
is the linter config itself: `trunk check` requires a committed
`.trunk/trunk.yaml` in the repo being checked (proven below), or a
one-shot `trunk init --yes-to-all` to generate one.

Trunk's env surface splits across **three different programs** that ship
under the `trunk` command — conflating them is the main trap:

| Layer | What it is | Env vars it reads |
| --- | --- | --- |
| Launcher | portable bash script (what the cloud scripts install at `/usr/local/bin/trunk`) | `TRUNK_CLI_VERSION`, `TRUNK_CACHE`, `TRUNK_QUIET`, `TRUNK_LAUNCHER_QUIET`, `TRUNK_LAUNCHER_DEBUG`, `CI`, `CURL_FLAGS`, `WGET_FLAGS` |
| CLI | the C++ binary the launcher downloads (`trunk check`, `trunk fmt`, `trunk merge`, daemon) | `TRUNK_CACHE`, `TRUNK_TELEMETRY`, `TRUNK_TOKEN`, `TRUNK_LOG_LEVEL`, `TRUNK_CLI_COLOR`, `TRUNK_HEAD_SHA`, `TRUNK_GITHUB_CONTEXT`, proxy + `SSL_CERT_FILE`, CI-detection set |
| Analytics CLI | separate Rust binary (`trunk flakytests` → `trunk-analytics-cli`) | `TRUNK_API_TOKEN`, `TRUNK_ORG_URL_SLUG`, `TRUNK_TEST_COLLECTION_ID`, `TRUNK_DRY_RUN`, … |

Note the naming split on tokens: the check CLI's upload token env var is
**`TRUNK_TOKEN`** (a 40-hex-char value, validated against
`[0-9a-f]{40}` in the binary), while **`TRUNK_API_TOKEN`** belongs to the
separate flaky-tests analytics CLI. They are not interchangeable.

## What we found

### 1. The launcher pins the CLI version via `TRUNK_CLI_VERSION` — no repo config required

Launcher source, CLI-resolution block: the version is resolved in priority
order — `TRUNK_CLI_VERSION` env var **wins over** the repo's
`.trunk/trunk.yaml` `cli.version`, and if neither exists it fetches
`https://trunk.io/releases/latest`:

```bash
version="${TRUNK_CLI_VERSION:-}"
if [[ ... || -n ${version:-} ]]; then     # env var set → use it, skip trunk.yaml
  :
elif [[ -f ${CONFIG_ABSPATH} ]]; then     # else: repo's .trunk/trunk.yaml
  ...
else                                      # else: network lookup of latest
```

So a cloud workspace can pin exactly which trunk CLI runs regardless of
what repo it's pointed at. **Caution:** this also means an exported
`TRUNK_CLI_VERSION` silently overrides the repo-pinned version this repo
relies on (`cli: version: 1.25.0`) — only export it deliberately (e.g. as
a floor for repos without trunk config), or not at all for normal agent
work.

When the env var supplies the version, the launcher skips its sha256
verification step (no pinned hash exists for an arbitrary version string)
— the download is still https from `trunk.io/releases/...`, same channel
the repo-pinned path uses when `.trunk/trunk.yaml` carries no
`<platform>:` sha line.

### 2. Everything trunk downloads lands under `TRUNK_CACHE` (default `~/.cache/trunk`)

Launcher source:

```bash
TRUNK_CACHE="${TRUNK_CACHE:-}"
... elif XDG_CACHE_HOME → "${XDG_CACHE_HOME}/trunk"
... else "${HOME}/.cache/trunk"
```

The CLI binary honors the same variable (present in its strings) and
places its managed downloads there: `cli/` (the binaries), `repos/`
(plugin repo checkouts), `tools/`, `plugins/`. This is the knob that
matters on ephemeral sandboxes:

- **Ephemeral, no persistence** — nothing to do; first `trunk check` pays
  a one-time cold start (downloads the CLI + every enabled linter's
  runtime; the launcher downloads on first invocation, which is why
  `conductor-cloud-install.sh` retries `trunk --version` once).
- **Persistent volume available** — point `TRUNK_CACHE` at it and warm it
  once with `trunk check download` (docs: "include a seeded trunk cache in
  a regularly updated image … by running `trunk check download`"), which
  pre-fetches linters without running a check.

### 3. Fully unauthenticated operation, proven live

Empirical run on this sandbox — fresh cache, env-pinned version, a git
repo with **no** `.trunk/` directory, no login, telemetry off:

```
$ git init scratch && echo hello > hi.py && git commit ...
$ TRUNK_CACHE="$T/cache" TRUNK_CLI_VERSION=1.25.0 \
    TRUNK_TELEMETRY=off TRUNK_LAUNCHER_QUIET=1 trunk --version
1.25.0                       # launcher downloaded the CLI into the scratch cache

$ ls "$T/cache"
cli repos                    # bootstrap happened entirely from env vars
```

Then, in that same unconfigured repo:

```
$ trunk check --ci </dev/null
✖ Please run 'trunk init' to setup trunk in this repository.
```

— confirming (a) login/`user.yaml` is never consulted for `trunk check`,
and (b) **a committed `.trunk/trunk.yaml` in the target repo is a hard
prerequisite**; there is no env var that carries lint config. For repos
that don't have one yet, the non-interactive form exists:

```
trunk init --yes-to-all        # answers all prompts yes; also --no-to-all,
                               # --single-player-mode (gitignored config)
```

Login state, when it exists at all, lives in `~/.cache/trunk/user.yaml`
(access tokens) — only needed for web-app upload / merge-queue operations,
none of which the cloud check path touches. No env var mints it.

### 4. Quiet, non-TTY-friendly output control

The launcher checks `CI` first and goes quiet automatically:

```bash
if [[ ! -z ${CI:-} && "${CI}" = true && -z ${TRUNK_LAUNCHER_QUIET:-} ]]; then
  TRUNK_LAUNCHER_QUIET=1
```

`TRUNK_LAUNCHER_QUIET=1` (or `TRUNK_QUIET`) forces it regardless — useful
in agent shells where `CI` isn't set but a TTY isn't attached either. The
CLI itself additionally offers `TRUNK_CLI_COLOR` (color on/off) and
`TRUNK_PRETEND_TTY`/`TRUNK_STDIN_IS_TTY` in the binary. `--ci` mode also
implies `--ci-progress` (progress at most every 30s) and turns on
print-failures, which is what the sandbox setup already leans on.

### 5. Telemetry off, and the proxy story for Vercel sandboxes

- `TRUNK_TELEMETRY=off` — documented kill switch (docs.trunk.io
  code-quality/configuration/telemetry). The binary additionally has
  `TRUNK_SEGMENT`/`TRUNK_MIXPANEL`/`TRUNK_SENTRY` strings, presumably
  internal overrides; `TRUNK_TELEMETRY=off` is the supported one.
- The CLI binary contains `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`,
  `NO_PROXY`, **and `SSL_CERT_FILE`** — so its own downloads (linters,
  plugin repos) respect the standard proxy vars and a custom CA bundle.
  Conductor cloud sandboxes already trust the proxy CA system-wide, so
  this should be a non-issue there; if a sandbox ever presents the
  classic "downloads fail behind proxy" symptoms, `SSL_CERT_FILE` is the
  knob trunk will honor. The launcher's own curl/wget downloads are
  tunable via `CURL_FLAGS`/`WGET_FLAGS`.

### 6. CI-mode detection is env-var driven (and matters for the daemon)

The binary probes the standard provider set: `CI`, `GITHUB_ACTIONS`,
`CIRCLECI`, `BUILDKITE`, `GITLAB_CI`, `JENKINS_URL`, `TRAVIS`, `CIRRUS_CI`,
`TEAMCITY_VERSION` (plus per-provider detail vars like
`GITHUB_REPOSITORY`, `BUILDKITE_COMMIT`…). Two consequences for cloud
workspaces:

- `--ci` mode **does not spawn the trunk daemon** (verified: no
  `trunk daemon` process after `trunk check --ci`), so one-shot agent runs
  leave nothing behind. Outside `--ci`, a check can auto-launch the
  daemon; pass `--monitor=false` for one-shot semantics without the rest
  of `--ci`'s behaviors, or `trunk daemon kill` after.
- These vars feed Trunk's CI annotations/PR-comment features. If a cloud
  sandbox happens to export `CI=true` for unrelated reasons, the launcher
  also auto-quiets (see #4) — harmless, but explains output differences
  between environments.

### 7. Authenticated paths, if ever wanted

- **Upload check results to the Trunk web app** (non-GitHub CI):
  `trunk check --upload --series <branch>` with the token supplied by env
  `TRUNK_TOKEN` (40-hex org/repo token) — the `--token` flag's env
  counterpart, confirmed in the binary's flag table ("trunk api token" ↔
  `TRUNK_TOKEN`, validated `[0-9a-f]{40}`).
- **GitHub annotation flows** additionally read `GITHUB_TOKEN` (PR
  comments) and `TRUNK_GITHUB_CONTEXT` (action-context JSON, what
  trunk-io/trunk-action injects).
- **Flaky-tests uploads** (separate `trunk-analytics-cli`, invoked as
  `trunk flakytests`): `TRUNK_API_TOKEN`, `TRUNK_ORG_URL_SLUG`,
  `TRUNK_TEST_COLLECTION_ID` (all three required),
  `TRUNK_DRY_RUN`, `TRUNK_ALLOW_FORKED_PR_UPLOADS`,
  `TRUNK_PUBLIC_REPO_ID`, `TRUNK_HIDE_TEST_COLLECTION_LINKS`.
- **Merge queue** (`trunk merge`) has **no** env-var auth — it requires
  `trunk login` (browser) writing `~/.cache/trunk/user.yaml`. Cloud
  workspaces can't and shouldn't do this; the create-PR prompt's Step 13
  (`trunk merge <pr>`) is a local-machine operation.

### 8. Misc knobs surfaced in the binary (lower confidence, internal-leaning)

`TRUNK_LOG_LEVEL` (spdlog-style levels), `TRUNK_TMPDIR`,
`TRUNK_DOWNLOAD_CACHE`/`TRUNK_PLUGINS_CACHE` (appear to override cache
subdirectories), `TRUNK_GIT_STDIN_FILE`, `TRUNK_GITHUB_CHECK_RUN_TITLE`,
`TRUNK_TEST_NO_AUTOLAUNCH`, `TRUNK_DAEMON_ARGS_SKIP`. These are visible in
`strings` but not documented; treat them as available-but-unsupported, and
prefer the flags/`trunk.yaml` equivalents where possible.

## Recommended env set for a Conductor cloud workspace

Minimal, unauthenticated, quiet, deterministic — nothing here requires
secrets:

```bash
# Silence the launcher in agent shells (CI=true sandboxes get this free)
export TRUNK_LAUNCHER_QUIET=1

# Opt out of usage telemetry
export TRUNK_TELEMETRY=off

# ONLY if deliberately overriding repo-pinned versions (see caveat in #1):
# export TRUNK_CLI_VERSION=1.25.0

# ONLY on a persistent volume, warmed once by `trunk check download`:
# export TRUNK_CACHE=/mnt/state/trunk-cache
```

Operationally, the invocation the sandboxes should standardize on for
one-shot agent runs is the one `.conductor/settings.toml` already uses —
`trunk check --ci --no-fix --all` (no daemon, prints failures, no prompts)
— with `trunk init --yes-to-all` as the bootstrap step for any target repo
that lacks `.trunk/trunk.yaml`. No changes to `conductor-trunk-preflight.sh`/`conductor-cloud-install.sh` are required
for any of this: they already install the launcher that consumes these
vars, and the vars themselves belong in the workspace env layer
(`[environment_variables.cloud]` in `~/.conductor/settings.toml`) or the
agent shell profile, not in the install scripts. The repo root carries
this set as a committed template: [`.env.cloud`](../.env.cloud) — static
section works as-is, placeholder section is filled per workspace (real
keys never committed).

## Traps checklist

- `TRUNK_TOKEN` (check upload) vs `TRUNK_API_TOKEN` (flaky-tests upload) —
  different programs, different tokens.
- `TRUNK_CLI_VERSION` overrides the repo's pinned `cli.version` — don't
  export it "for safety"; it can silently version-skew a repo that pins
  deliberately.
- No env var replaces `.trunk/trunk.yaml` — repos without it fail with
  "Please run 'trunk init'", and init needs `--yes-to-all` to be
  non-interactive.
- `trunk merge`/web-app login is browser-based and machine-local — never
  wire a token into cloud workspaces for it.
- Fresh sandbox + fresh cache = first check pays the full linter-download
  cold start (the launcher's own CLI bootstrap is why
  conductor-cloud-install.sh already retries `trunk --version` once).
