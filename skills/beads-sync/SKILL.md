---
name: beads-sync
description: Use when pulling Beads (bd) issues into this workspace, either from the private DoltHub remote (scripts/beads-dolthub-pull.sh) or from the Linear AI team (scripts/beads-linear-pull.sh), or when debugging Dolt credential JWKs or a .beads database with the wrong remote.
---

# Pulling Beads issues

Both pulls are manual. Conductor setup never runs them (#45 removed Beads from setup). Both need `INFISICAL_TOKEN` and `INFISICAL_PROJECT_ID` in the shell, and both keep secrets in the process environment only.

## From DoltHub (`dolthub://elviskahoro/gtm-sdk`)

```bash
bash scripts/beads-dolthub-pull.sh
bd ready --json; bd list --json; bd show <bead-id>
```

- DoltHub authenticates with a Dolt credential JWK, not an API token. Create one with `dolt creds new` (or `dolt login`), register its public key on DoltHub, and store the private JWK JSON itself in Infisical as `DOLTHUB_DOLT_CREDENTIAL_JWK`. Never commit it.
- The script imports the JWK into a temp Dolt credential dir that's removed on exit. The `.beads` DB and its remote config persist between pulls.
- Overrides: `BEADS_DOLTHUB_REMOTE`, `DOLTHUB_DOLT_CREDENTIAL_SECRET_NAME`, and `INFISICAL_ENV` (default `dev`).

## From Linear (AI team, pull-only pilot)

```bash
bash scripts/beads-linear-pull.sh --dry-run   # preview
bash scripts/beads-linear-pull.sh             # import/update
bd linear status --json
```

- Linear stays the source of truth. This creates a separate stealth `.beads` DB with no Dolt remote.
- `LINEAR_API_KEY` comes from Infisical. For an already-initialized DB, the explicit equivalent is `bd linear sync --pull --relations` with that key in the environment.
- It refuses to reuse a `.beads` DB that already has a Dolt remote, so the two workflows never mix. Re-runs update existing issues instead of duplicating them.
- See `findings/linear-beads-integration-report.md` for the worktree database redirect hazard.
