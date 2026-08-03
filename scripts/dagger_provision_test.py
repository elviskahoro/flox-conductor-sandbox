"""Dagger pipeline: run scripts/floxhub-provision.sh in a disposable container.

Proves the Flox-provisioning recipe (issue #16 §9's Phase D MVP) still works
end-to-end — `bd`/`roborev` + the five catalog tools resolving under
`.flox/run/.../bin` — without ever authenticating this workspace's own
Conductor sandbox. That sandbox must stay unauthenticated by default (issue
#16 trap 5: authenticating it permanently disqualifies it as the Stage 4/H4
tester). A Dagger container is thrown away after every run, so it can
authenticate freely.

Invocation — FLOXHUB_TOKEN always comes straight from the environment, no
Infisical fallback for this one token (deliberate: Infisical is for
downstream/consumed secrets, not FloxHub's own bootstrap credential here):

    TOKEN="$(flox auth token)"   # run on an already-authenticated machine
    FLOXHUB_TOKEN="${TOKEN}" uv run dagger run python scripts/dagger_provision_test.py

If `FLOXHUB_TOKEN` is unset, this script fails fast with an error rather than
silently proceeding unauthenticated.

Mirrors gtm-sdk's own `pytest_dagger.py`: the pipeline captures the
verification step's exit code into a file inside the container (so
`with_exec` stays green and its stdout is always exportable) and re-raises the
real failure afterward, instead of an `... || true` that would swallow it.

Platform note (same known gap as Stage 7 in scripts/sandbox-test.sh):
`elvis/bd`/`elvis/roborev` are only published for `x86_64-linux` and
`aarch64-darwin`, not `aarch64-linux`. This pipeline runs the container at
the *host's own* platform by default (fast, no emulation) — on an Apple
Silicon Mac that's `aarch64-linux`, so `bd`/`roborev` are expected to be
absent and only the 5 catalog tools are verified; a full 7/7 check needs a
genuine `x86_64-linux` host (e.g. a real Conductor cloud sandbox), which is
also the actual target class this whole repo validates against. Force
`x86_64-linux` explicitly with `DAGGER_PLATFORM=linux/amd64` if you want to
try it anyway — expect it to be slow and to hit QEMU-emulation quirks
unrelated to Flox (confirmed: nix's build sandbox fails under emulation with
"getting pseudoterminal attributes: Function not implemented").
"""

from __future__ import annotations

import os
import sys

import anyio
import dagger
from dagger import dag

BASE_IMAGE = "amazonlinux:2023"  # matches the real target class (issue #16 §6)
_platform_override = os.environ.get("DAGGER_PLATFORM", "").strip()
PLATFORM = dagger.Platform(_platform_override) if _platform_override else None

FLOX_BOOTSTRAP_CMD = (
    "set -euo pipefail; "
    # flox's rpm depends on sudo + tar, neither preinstalled on the base
    # amazonlinux:2023 image (unlike a real AL2023/Vercel sandbox, which
    # ships both).
    "dnf install -y xz sudo tar >/dev/null; "
    "arch=$(uname -m); "
    "curl -fsSLo /tmp/flox.rpm "
    "  \"https://downloads.flox.dev/by-env/stable/rpm/flox.${arch}-linux.rpm\"; "
    "rpm --import https://downloads.flox.dev/by-env/stable/rpm/flox-archive-keyring.asc; "
    "rpm -ivh /tmp/flox.rpm; "
    "rm -f /tmp/flox.rpm; "
    "flox --version"
)

# Containers have no systemd, so nix-daemon.socket is never auto-activated —
# same hand-start fallback as scripts/sandbox-test.sh Stage 1.
NIX_DAEMON_START_CMD = (
    "set -euo pipefail; "
    "if [ ! -S /nix/var/nix/daemon-socket/socket ]; then "
    "  nohup nix-daemon --daemon >/tmp/nix-daemon.log 2>&1 & "
    "  for _ in 1 2 3 4 5 6 7 8 9 10; do "
    "    [ -S /nix/var/nix/daemon-socket/socket ] && break; "
    "    sleep 1; "
    "  done; "
    "fi; "
    "ls -l /nix/var/nix/daemon-socket/socket"
)

PROVISION_CMD = ["bash", "scripts/floxhub-provision.sh"]

# elvis/bd and elvis/roborev are published for x86_64-linux and
# aarch64-darwin only (envs/floxhub-provision/.flox/env/manifest.toml) — on
# aarch64-linux (e.g. an unforced run on Apple Silicon) they're absent by
# design, not a provisioning failure, so don't check for them there.
CATALOG_TOOLS = ["uv --version", "dolt version", "infisical --version", "gh --version", "git version"]
FULL_TOOLS = ["bd version", "roborev version", *CATALOG_TOOLS]

# Verify each tool actually resolves post-activation, don't just trust
# floxhub-provision.sh's exit code — a partial resolution failure (e.g.
# roborev present but bd missing) should be visible, not eaten.
VERIFY_RC_PATH = "/tmp/verify_rc"


def verify_cmd(arch: str) -> str:
    # arch is uname -m from *inside* the container — not the Python-side
    # PLATFORM string, which is None (host-native) in the common case and
    # would otherwise make CATALOG_TOOLS-vs-FULL_TOOLS a guess rather than a
    # fact about what actually got built.
    tools = FULL_TOOLS if arch == "x86_64" else CATALOG_TOOLS
    if tools is CATALOG_TOOLS:
        print(
            "note: platform is aarch64-linux — elvis/bd/elvis/roborev aren't "
            "published for it, so only the 5 catalog tools are verified "
            "(same known gap as Stage 7). Set DAGGER_PLATFORM=linux/amd64 for "
            "the full 7-tool check.",
            file=sys.stderr,
        )
    check = " && ".join(tools)
    return (
        "set +e; "
        f"flox activate --dir envs/floxhub-provision --mode run -- sh -c '{check}'; "
        f"echo $? > {VERIFY_RC_PATH}"
    )


async def main() -> None:
    token = os.environ.get("FLOXHUB_TOKEN", "").strip()
    if not token:
        print(
            "error: FLOXHUB_TOKEN is not set in this process's environment. "
            "Set it directly, e.g.:\n"
            '  FLOXHUB_TOKEN="$(flox auth token)" uv run dagger run python '
            "scripts/dagger_provision_test.py",
            file=sys.stderr,
        )
        raise SystemExit(1)

    async with dagger.Connection(dagger.Config(log_output=sys.stderr)) as client:
        secret = client.set_secret("floxhub-token", token)
        source = client.host().directory(".", exclude=[".git", "tmp"])

        container = (
            client.container(platform=PLATFORM)
            .from_(BASE_IMAGE)
            .with_exec(["sh", "-c", FLOX_BOOTSTRAP_CMD])
            .with_exec(["sh", "-c", NIX_DAEMON_START_CMD])
            .with_directory("/src", source)
            .with_workdir("/src")
            .with_secret_variable("FLOXHUB_TOKEN", secret)
            .with_exec(PROVISION_CMD)
        )

        arch = (await container.with_exec(["uname", "-m"]).stdout()).strip()

        verify = container.with_exec(
            ["sh", "-c", verify_cmd(arch)], expect=dagger.ReturnType.ANY
        )
        stdout = await verify.stdout()
        stderr = await verify.stderr()
        rc_raw = (await verify.file(VERIFY_RC_PATH).contents()).strip()

        print(stdout)
        if stderr:
            print(stderr, file=sys.stderr)

        if rc_raw != "0":
            raise RuntimeError(
                f"verification step failed inside the container (exit {rc_raw}); "
                "see stdout/stderr above for which tool(s) didn't resolve"
            )

    tools = FULL_TOOLS if arch == "x86_64" else CATALOG_TOOLS
    print(f"All {len(tools)} tools resolved under envs/floxhub-provision in a disposable container.")


if __name__ == "__main__":
    anyio.run(main)
