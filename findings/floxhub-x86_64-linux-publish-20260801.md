# x86_64-linux publish of `elvis/conductor-workspace-floxhub-01` — 20260801

Closes the gap PR #7 explicitly left open: that PR authenticated and
re-published `elvis/conductor-workspace-floxhub-01` for `aarch64-darwin` only,
since `flox build`/`flox publish` build for the host's own system and PR #7
ran from a Mac. This sandbox is x86_64-linux (Amazon Linux 2023 / Vercel /
Conductor cloud) — the platform PR #7 said still needed a publish.

## What was done

1. Authenticated via `scripts/floxhub-login.sh` with a `FLOXHUB_TOKEN`
   supplied by the operator (from `flox auth token` on an already-logged-in
   machine). Confirmed with `flox auth status` → logged in as `elvis`.
   **This sandbox is now permanently authenticated and disqualified from
   ever being the unauthenticated Stage 4 (H4) cold-fetch tester** — a
   separate, never-touched sandbox is still needed for that test.
2. `cd envs/repackage && flox build conductor-workspace-floxhub-01` — built
   clean, same trivial smoke-test package as before.
3. `flox publish conductor-workspace-floxhub-01` — required setting an
   upstream remote for the branch first (`flox publish` refuses to run
   without one); pushed the existing local branch to `origin` (no force, no
   history rewrite), then publish succeeded:
   ```
   ✔ Package published successfully.
   Use 'flox install elvis/conductor-workspace-floxhub-01' to install it.
   ```

## Verification

```
$ flox show elvis/conductor-workspace-floxhub-01
elvis/conductor-workspace-floxhub-01 - Trivial flox build smoke test (gtm-sdk#445 preflight)
Catalog: elvis
Latest:  elvis/conductor-workspace-floxhub-01@0.0.1
Outputs: out* (* installed by default)
Systems: aarch64-darwin, x86_64-linux

Other versions:
    elvis/conductor-workspace-floxhub-01@0.0.1 (aarch64-darwin, x86_64-linux only)
```

Both platforms now present. The x86_64-linux gap PR #7 left open is closed.

## What's still open

- Stage 4 (H4, unauthenticated FloxHub fetch) is still untested end-to-end
  on a genuinely fresh sandbox — this one no longer qualifies as a tester
  (see above). The next fresh sandbox can now run
  `FLOXHUB_TEST_PKG=elvis/conductor-workspace-floxhub-01 bash scripts/sandbox-test.sh`
  and get a real PASS/FAIL instead of the prior SKIP, since the package is
  now visible on both platforms.
- No Phase B/C/D/D' work from gtm-sdk#445 attempted here — out of scope per
  issue #5's stop condition.
