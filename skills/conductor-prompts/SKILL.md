---
name: conductor-prompts
description: Use when editing the shared Conductor prompts in prompts/conductor/ (general, create-pr, fix-errors, resolve-merge-conflicts), installing them into another repo's .conductor settings, or fixing a prompt drift failure from scripts/install-conductor-prompts.py --check.
---

# Shared Conductor prompts

Conductor reads prompts only from a repo's `.conductor/settings.toml` (or `settings.local.toml`) `[prompts]` table, and TOML has no include mechanism. Hand-copied prompts drift: gtm-sdk's TOML still said `git roborev` after its `.md` was fixed. So:

- `prompts/conductor/<slot>.md` is the only source. Never hand-edit an installed TOML copy. Edit the `.md` and re-run the installer.
- `scripts/install-conductor-prompts.py` copies the text in, preserving comments and unrelated keys. It's idempotent. `--check` fails when a copy has drifted, and `--self-test` runs its behavior matrix. Both run in CI.
- Shell logic the prompts need lives in `scripts/conductor-prompts/` (with `self-test.sh` in CI), not inline in the prompt.

From inside a target repo:

```bash
# The script path must be absolute: uv run resolves it against cwd, not --project.
# --no-project --with tomlkit skips the full dependency sync.
uv run --no-project --with "tomlkit>=0.15.1" \
    /path/to/flox-conductor-sandbox/scripts/install-conductor-prompts.py --check
```

`prompts/README.md` covers the slot mapping (kebab-case filename to snake_case slot) and the `--local`/`--print` variants.
