---
name: floxhub-auth
description: Use when a sandbox must authenticate to FloxHub, publish a package with flox publish, or consume a private FloxHub pkg-path (elvis/bd, elvis/roborev); when choosing between scripts/floxhub-login.sh and scripts/floxhub-provision.sh; or when running the Dagger / GitHub Actions staging check for the provisioning recipe.
---

# FloxHub authentication

Packages published with `flox publish` are private to the publisher, so any sandbox that consumes them must authenticate. Whatever you do, never wire authentication into the default provisioning path: an authenticated sandbox can never again serve as the unauthenticated Stage 4 tester (see `flox-sandbox-harness`).

## Getting a token

- On an already-authenticated machine, run `flox auth token`. Non-interactive login needs flox 1.14.0+. 1.13.2 has neither `--token-file` nor `auth token`.
- Hand the token over through a secret-safe channel. Values in `.conductor/settings.toml` env vars are plain, unmasked strings, so prefer Infisical (`FLOXHUB_TOKEN`).
- For CI, Flox recommends a dedicated low-privilege service account, not a person's token.

## Consuming packages: `scripts/floxhub-provision.sh` (preferred)

```bash
FLOXHUB_TOKEN=<token> bash scripts/floxhub-provision.sh
FLOXHUB_ACTIVATE_DIR=/path/to/repo bash scripts/floxhub-provision.sh   # activate another repo's committed .flox env
```

- It uses `FLOXHUB_TOKEN` if already set, else Infisical (`infisical secrets get FLOXHUB_TOKEN --plain`, with the name overridable via `FLOXHUB_TOKEN_SECRET_NAME`). There's no interactive fallback. A stale `FLOXHUB_TOKEN` left in the shell wins over a rotated Infisical secret, so unset it when rotating.
- It exports `FLOX_FLOXHUB_TOKEN` and runs `flox activate`, which is Flox's documented CI pattern. Nothing is written to the keyring or disk, and it has been confirmed to work from a fresh `$HOME`.
- `elvis/bd` and `elvis/roborev` are published for `aarch64-darwin` and `x86_64-linux` only.

## Publishing: `scripts/floxhub-login.sh`

`flox publish` needs a persistent login:

```bash
FLOXHUB_TOKEN=<token> bash scripts/floxhub-login.sh
```

It fails loudly if the token is unset, and it only ever holds the token in a `mktemp`/`umask 077` tempfile that's shredded on exit. The sandbox stays authenticated afterward. Setup does the same login only when both `FLOXHUB_AUTOLOGIN=1` and `FLOXHUB_TOKEN` are set, using `--insecure-storage` because sandboxes have no keyring.

## Proving the recipe without authenticating this sandbox

- **Dagger:** `FLOXHUB_TOKEN=<t> uv run dagger run python scripts/dagger_provision_test.py` runs `floxhub-provision.sh` unmodified in a throwaway `amazonlinux:2023` container. It reads the token from the environment only, with no Infisical fallback. **It can't run inside a Conductor cloud workspace**, because Dagger needs cgroups/overlayfs access that the nested container doesn't have. Run it on a Mac.
- **GitHub Actions:** for a real `x86_64-linux` run with the full 7/7 tools, use `gh workflow run floxhub-provision-check.yml`, which reads the `FLOXHUB_TOKEN` repo secret.
