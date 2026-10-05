# Trunk merge headless auth — file-based login provisioning

Research closing the open question in issue #40 Workstream B (from
gtm-sdk#702): *solve non-interactive auth for `trunk merge` in a headless
sandbox*. This supersedes the "cloud workspaces can't and shouldn't do
this" conclusion in
[`20261005-141227Z-trunk-cli-env-var-setup-mechanics.md`](20261005-141227Z-trunk-cli-env-var-setup-mechanics.md)
§7 — that verdict was correct for **env-var** auth but missed that the
**login file itself** is provisionable.

Method: live runs on an aarch64-darwin Mac with trunk launcher + CLI 1.25.0
(the version gtm-sdk's `.trunk/trunk.yaml` pins), scratch `TRUNK_CACHE`
directories to simulate fresh machines, `strings` on the CLI binary, and a
real Infisical round-trip. All claims below were executed, not inferred.

## Verdict

**`trunk merge` has no env-var auth — confirmed — but a provisioned
`user.yaml` authenticates it fully, headlessly.** The recipe: an operator
runs `trunk login` once on an authenticated machine, stores the contents of
`~/.cache/trunk/user.yaml` in Infisical as `TRUNK_USER_YAML`, and the
workspace setup writes them into the sandbox's `~/.cache/trunk/user.yaml`
(only when no login already exists, `0600`, never echoed or logged).
`trunk check` remains fully unauthenticated and needs nothing.

## What was found

### 1. No env-var alternative exists for merge — now proven, not just read out of strings

- A garbage `TRUNK_TOKEN` set in the environment, fresh cache:
  `trunk merge status` → **"User not logged in: please run trunk login"**.
  The variable is simply ignored by the merge CLI (`TRUNK_TOKEN` is the
  check-upload token; `TRUNK_API_TOKEN` belongs to the flaky-tests
  analytics CLI — see the env-var mechanics doc's three-program split).
- `trunk login --help` exposes no flags at all — browser flow only.
- Binary strings corroborate: the only token plumbing near merge is
  `user.yaml` ("user.yaml failed validation" / "User not logged in").

### 2. The login file is machine-independent — proven by transfer

`~/.cache/trunk/user.yaml` (shape: `version`, `anonymous_id`,
`trunk_user.{email, full_name, id.value, tokens.access_token}` — a single
32-char access token, no refresh token) copied into a **fresh**
`TRUNK_CACHE` on this machine:

- fresh cache, no file → "User not logged in: please run trunk login"
  (the exact failure gtm-sdk#702 hit when landing #699 by hand);
- same cache + the copied file → **full `Trunk Merge Status [main]
  [Running]` output against gtm-sdk's real queue** — authenticated.

So the file is a portable credential, not machine-bound state.

### 3. Repo authorization is a separate wall from authentication

The same provisioned file in the flox-conductor-sandbox repo (which has no
merge queue) yields **"User not authorized"** — the token was accepted, the
*repo* wasn't. Correct behavior; it means headless merge auth only works
where the merge queue actually exists (gtm-sdk does — `trunk merge status`
renders its queue).

### 4. The full production path, including Infisical, works end-to-end

The exact flow gtm-sdk's `conductor-workspace-setup.sh` now implements was
rehearsed live: `infisical secrets get TRUNK_USER_YAML --env=dev --plain`
→ written to a scratch cache's `user.yaml` → `trunk merge status` exit 0
with real queue output. The secret was created in gtm-sdk's Infisical
project from the operator machine's login file and validates.

## Ported where

`gtm-sdk` branch `agent/conductor-flox-trunk-completion` (issue #40):

- `scripts/conductor-workspace-setup.sh` provisions the launcher
  (checksum-pinned, same pin as `.rwx/trunk-check.yml`) and the login file
  from Infisical `TRUNK_USER_YAML` (name overridable via
  `TRUNK_USER_YAML_SECRET_NAME`), never clobbering an existing login;
- `.github/workflows/ci/conductor_provision_dagger.py` +
  `conductor-provision-check.yml` prove the whole surface in one cold
  amazonlinux:2023 run (Infisical identity in, FloxHub token + trunk login
  fetched inside, `trunk check --all --ci` unauthenticated, `trunk merge
  status` headless).

## Traps checklist

- `TRUNK_TOKEN`/`TRUNK_API_TOKEN` do nothing for `trunk merge` — don't
  re-derive this; the file is the only non-interactive path (as of CLI
  1.25.0).
- The yaml holds a **session access token with no refresh token** — when
  it expires, merge starts reporting not-logged-in; the operator re-runs
  `trunk login` on an authenticated machine and re-stores the secret.
  Budget for that as a periodic credential rotation, same operational
  posture as `FLOXHUB_TOKEN`.
- Only provision when `~/.cache/trunk/user.yaml` is absent — an interactive
  login on the machine is strictly better than a provisioned copy and must
  never be overwritten.
- Write it `0600` (and the cache dir `0700`); the file is a bearer
  credential. It must never be echoed, logged, or passed through argv —
  including in test fixtures.
- "User not authorized" ≠ broken token: check that the target repo actually
  has a Trunk merge queue before blaming the credential.
- `trunk check` needs none of this — lint stays unauthenticated by design;
  only `trunk merge` (and web-app upload) consume the login.
