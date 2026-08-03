Here's a comprehensive research prompt for the FloxHub auth-token strategy
decision that's been blocking Phase D/D′ since issue #16 was written. This is
a **research and brief-writing task, not a decision task** — the agent's job
is to hand the owner (Elvis) everything needed to decide in five minutes, not
to decide for him.

---

You're working in `flox-conductor-sandbox`, a test harness for gtm-sdk#445
("publish bd/roborev to FloxHub as prebuilt binaries"). Read `README.md` and
`findings/README.md` first, then read
[issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16) in
full, especially §7's owner-decision item and §9 (Phase D MVP). Base your work
on `main`.

**Background**: Phase D′ (FloxHub auth-token plumbing) is confirmed necessary
— a bare `flox publish` is private by construction (issue #16 §1), so any real
unauthenticated/CI consumption needs authentication. The Stage 6 prototype
(`envs/floxhub-consume`, PR #13) already proves the mechanics work using a
**personal FloxHub handle + a personal `flox auth token`**. What's still open
is which credential strategy to actually use going forward:

- **Option A — personal handle + personal token** (what the prototype already
  uses): free, already proven end-to-end, but means a human-account credential
  living in CI-like contexts (Conductor sandboxes today, gtm-sdk CI
  eventually).
- **Option B — paid Flox-for-Teams org + Auth0 client-credentials machine
  token** with Reader role, stored in Infisical as `FLOXHUB_MACHINE_TOKEN`
  (what gtm-sdk#445 §6/A1 specifies, and what this repo's secrets-management
  convention — Infisical for all app secrets, per this workspace's CLAUDE.md —
  implies is the "correct" shape). Costs money, adds setup steps, presumably
  safer to leak (scoped role, not a full personal account).
- **Fallback (v2 §10's worst case)** if Teams pricing is a blocker: a plain Nix
  binary cache (Cachix hosted, or a self-hosted S3 substituter + signing key)
  — same build-once/fetch-everywhere property as FloxHub, more moving parts,
  no Flox-native UX (no `flox auth login`/`pkg-path` — just a substituter URL
  and a public key).

**Your task** — pure research, no purchasing, no signups, no org creation, no
money spent, no code changes:

1. **Current Flox-for-Teams pricing and plan details.** Check flox.dev's
   pricing/docs pages directly (don't rely on training-data memory — pricing
   pages change). Find: cost per seat/org, what "org-shared catalog" actually
   includes, and whether Auth0 client-credentials machine tokens are a
   documented, generally-available feature today or something still
   in-progress/beta. Cite what you find with URLs.
2. **Confirm the machine-token mechanics concretely**, not just from the plan
   description in issue #16. Check `flox auth --help` / `man flox-auth` on
   this machine (flox 1.14.0 is installed) for any org/machine-token-specific
   subcommands, and check Flox's docs for how a client-credentials token is
   minted and whether `flox auth login --token-file=<path>` accepts a machine
   token identically to a personal one (issue #16 flags this as an
   **unverified assumption** — if you can't confirm it from docs, say so
   explicitly rather than assuming it works).
3. **Current Cachix (or equivalent) pricing** for the fallback option, at the
   same level of specificity as #1 — free tier limits, paid tier cost, what a
   self-hosted S3 substituter + signing key would cost/require instead if
   Cachix itself isn't attractive.
4. **Security/blast-radius comparison**, grounded in what each token actually
   grants: for a personal `flox auth token`, what's the actual scope if it
   leaks (full account access? read-only to published packages? can it
   publish/delete on the owner's behalf?) — check `flox auth token --help` and
   FloxHub docs for token scoping. For an org machine token with Reader role,
   confirm what "Reader" actually restricts to. Don't guess at this — find the
   actual docs language.
5. **Rough implementation-effort estimate for each path**, scoped against the
   Phase D MVP being built in this repo (issue #16 §9): Option A needs no new
   work (Stage 6 already proves it). Option B needs: Teams signup, org
   creation, minting a machine token, wiring `FLOXHUB_MACHINE_TOKEN` into
   Infisical, and re-running Stage 6's validation with that token instead of a
   personal one to confirm it's a drop-in swap (flag this as unconfirmed until
   someone actually does it).

**Deliverable**:
- Write `findings/<UTC-stamp>-floxhub-token-strategy-decision-brief.md` (a
  one-off findings doc, same convention as the existing
  `findings/floxhub-x86_64-linux-publish-20260801.md`) containing: a
  side-by-side comparison table (cost, setup effort, security posture, current
  confirmation status of each open technical question above), an explicit
  "Unknowns / assumptions not yet verified" section, and a **recommendation**
  clearly labeled as a recommendation, not a decision — end it with something
  like "this is Elvis's call; the above is what it takes to make it quickly."
- Post one comment on
  [issue #16](https://github.com/elviskahoro/flox-conductor-sandbox/issues/16)
  linking the new findings doc and summarizing the comparison in 3-5 bullets —
  do not edit the issue body to declare a decision made, since none has been.
- Commit the findings doc through the normal PR flow (branch, `git roborev
  review --wait`, push, PR against `main`) — same process as PR #19.

**Out of scope**:
- Do not sign up for Flox-for-Teams, create an org, generate any real
  machine token, or spend any money — this is desk research using public
  docs/pricing pages plus what's already proven in this repo's code and
  findings.
- Do not start implementing either path in the Phase D MVP (issue #16 §9) —
  that's separate, larger-scoped work that depends on this decision landing
  first (or explicitly proceeding with Option A as a placeholder — see §9).
- Do not attempt the `flox search` unauthenticated-evidence task — that has
  its own dedicated prompt
  (`prompts/20260803-124431Z-flox-search-unauthenticated-evidence-handoff.md`).

**Notes for whoever redeploys with this prompt**:
- If pricing or feature availability has changed since issue #16 was written
  (2026-08-02/03), that's exactly the kind of drift this brief exists to
  catch — don't anchor on the numbers in the issue body, re-verify them.
- If Option B's machine-token mechanics turn out to be unconfirmable from
  public docs alone (e.g. it requires an actual paid account to see), say so
  plainly in the brief rather than guessing that it "should" work the same as
  personal tokens.
