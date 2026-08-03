# FloxHub machine-token CLI mechanics — exploration findings

Follow-up to the token-strategy decision brief
(`findings/20260803-131800Z-floxhub-token-strategy-decision-brief.md`, PR #21)
and issue #16 §7's owner-decision item. That brief left two things
unconfirmed from public docs alone:

1. Whether `flox auth login --token-file` accepts an org machine token the
   same way it accepts a personal token.
2. What machine-token provisioning actually costs/requires beyond the
   headline Team-tier price.

This is CLI-level and API-level exploration (no org signup, no real machine
token — Flox's provisioning is still a manual "contact us" step, see below)
using flox 1.14.0 on this sandbox, plus a real personal token minted after
signing up for Flox-for-Teams.

## What we found

**1. The `flox` binary hardcodes a single OAuth client for personal login,
and that client is explicitly blocked from `client_credentials` grants.**

`strings` on the underlying Nix-built binary
(`.../bin/.flox-wrapped`, not the `flox` wrapper script) surfaces the OAuth
config baked in at build time:

```
_FLOX_OAUTH_AUTH_URL=https://auth.flox.dev/authorize
_FLOX_OAUTH_TOKEN_URL=https://auth.flox.dev/oauth/token
_FLOX_OAUTH_DEVICE_AUTH_URL=https://auth.flox.dev/oauth/device/code
_FLOX_OAUTH_CLIENT_ID=fGrotHBfQr9X1PHGbFoifEWaDPyWZDmc
```

The only OAuth `grant_type` string present anywhere in the binary is
`urn:ietf:params:oauth:grant-type:device_code` — there is no
`client_credentials` grant_type compiled in. The CLI cannot mint a machine
token itself; the curl-to-Auth0 step described in
[flox.dev/docs/concepts/organizations](https://flox.dev/docs/concepts/organizations/)
is something you run entirely outside the CLI, using credentials Flox
provisions separately.

Confirmed live against the real endpoint — the CLI's own public client is
rejected for that grant type:

```
$ curl -s -X POST https://auth.flox.dev/oauth/token \
    -d 'grant_type=client_credentials' \
    -d 'client_id=fGrotHBfQr9X1PHGbFoifEWaDPyWZDmc' \
    -d 'audience=https://hub.flox.dev/api'
{"error":"unauthorized_client","error_description":"Grant type 'client_credentials' not allowed for the client.", ...}
HTTP 403
```

This rules out any shortcut: there is no way to get an org-scoped token
without Flox provisioning a distinct, authorized client (contact-us only —
no self-serve UI, confirmed both in docs and by the owner directly checking
the FloxHub dashboard).

**2. `--token-file` does zero network validation — it's purely local, and it
requires a specific JWT claim shape.**

Tested in an isolated sandbox `$HOME` (not the real keyring) with
hand-crafted, unsigned JWTs:

- A JWT missing `https://flox.dev/handle` is rejected immediately, locally,
  with `invalid token: JSON error: missing field` — before any network call.
  The CLI deserializes the token payload into a Rust struct that requires
  this field to exist.
- A JWT with `https://flox.dev/handle` (any value), `https://flox.dev/roles`,
  a `sub` in `client|...@clients` shape, and a future `exp` is accepted
  *completely* — `✔ Authentication complete`, `✔ Logged in as <handle>` —
  with a garbage/unverifiable signature (`fakesig`). No JWKS/signature
  verification happens client-side; `man flox-auth`'s claim of "no network
  access involved" for `--token-file` checks out exactly. Real verification
  only happens later, server-side, when the token is presented to
  `hub.flox.dev` on an actual API call.

**This narrows the open question from the original brief to one precise,
answerable thing**: does Flox's org machine-token JWT include an
`https://flox.dev/handle` claim (e.g. set to the org handle)? If yes,
`--token-file` accepting it is a foregone conclusion, not an assumption. If
no, `flox auth login --token-file` will hard-fail locally on every machine
token, regardless of what the server-side API would otherwise accept.

**3. Re-confirmed Option A (personal token) live, post-Teams-signup.**

Logged in for real with a freshly-minted personal token (still
`https://flox.dev/handle: elvis`, `https://flox.dev/roles: {}` — signing up
for Flox-for-Teams did not change the shape or grant of the personal token,
and there is still no machine-token option surfaced anywhere in the FloxHub
web dashboard). `flox auth status`, `flox show elvis/bd`, and `flox search
bd` all succeeded live against `hub.flox.dev` with this token. This is the
same mechanism Stage 6 (PR #13) already proved — no new capability, just a
fresh confirmation that it's still the only thing actually available
without contacting Flox.

## Decision

**Sticking with Option A (personal `flox auth token`) for the Phase D MVP
and for now, full stop.** Option B remains blocked on Flox's manual
provisioning (no self-serve path exists), and even once unblocked would need
the `https://flox.dev/handle` claim question answered before it could be
trusted as a drop-in swap. Given Option A is free, fully proven (twice now),
and Option B's remaining path requires an external, un-schedulable dependency
(waiting on Flox support), this project is not pursuing Option B further.

The only real operational debt on Option A is the ~1-month personal-token
expiry noted in the prior brief — worth tracking as its own small follow-up
(scripted renewal/rotation) if/when it becomes a live CI concern, but not a
blocker on anything today.

## Unknowns intentionally left unresolved

- Whether Flox's actual machine-token JWTs include `https://flox.dev/handle`.
  Not investigated further since Option B is no longer being pursued — would
  require actually contacting Flox to answer.
- Server-side behavior of a machine token on `flox push`/`flox publish`/
  `flox build` calls (as opposed to just `login`) — same reason, moot now.
