---
name: entire-device-login
description: Use when the Entire CLI (`entire`) must be authenticated inside a Conductor cloud sandbox via `entire login --device`, when login says "Not logged in" after approval, or when it fails with "org.freedesktop.secrets was not provided" (no OS keyring).
---

# Entire CLI device login in a headless sandbox

Sandboxes have no OS keyring, so a plain `entire login --device` can be approved in the browser and still fail at the save step. Store tokens in a file instead, and set the same variable on **every** `entire` command, or the CLI reports "Not logged in".

The token lands in `~/.config/entire/tokens.json` (0600), outside the repo. Never copy it into the working tree. The login lasts about 29 days and survives only while the sandbox keeps its files.

If a short-lived token is enough, skip all this: run `entire auth token` on the user's own machine and set the output as `ENTIRE_TOKEN` (valid 8 hours).

## Steps

1. Check first: `ENTIRE_TOKEN_STORE=file entire auth status`. Stop if it says "Logged in".
2. Start the login detached, so it keeps waiting while the user approves (a foreground command with a timeout kills it, and a plain `&` inside the tool can be reaped):

   ```bash
   cd /tmp
   ENTIRE_TOKEN_STORE=file setsid nohup entire login --device \
     > /tmp/entire-login.log 2>&1 < /dev/null &
   sleep 3; cat /tmp/entire-login.log
   ```

3. Give the user the printed Login URL and code, and ask them to approve it **now**. Codes expire within a few minutes.
4. When the user says done, check `cat /tmp/entire-login.log` for "Login complete", then `ENTIRE_TOKEN_STORE=file entire auth status`.
5. Make it stick for later commands: export `ENTIRE_TOKEN_STORE=file` in the agent's environment (shell profile or provisioning script).

## Failure modes

| Log says | Cause / fix |
|---|---|
| `device authorization expired` | User was too slow. Rerun step 2 for a fresh code. |
| `org.freedesktop.secrets was not provided` | Forgot `ENTIRE_TOKEN_STORE=file`. Rerun with it. |
| `Not logged in` after a successful login | `ENTIRE_TOKEN_STORE=file` missing from the status/other command. |
| Process gone, no log output | It was killed with the tool call. Use `setsid nohup`, not a timeout. |
