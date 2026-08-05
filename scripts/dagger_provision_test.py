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

Set `INFISICAL_TOKEN` and `INFISICAL_PROJECT_ID` to additionally run the
real Beads/DoltHub bootstrap and `bd ready`/`bd list`/`bd show` checks. Set
`REQUIRE_BEADS_CHECK=1` in CI when those checks must run; the default keeps
the five/seven-tool provisioning check usable without downstream credentials.

Mirrors gtm-sdk's own `pytest_dagger.py`: the pipeline captures the
verification step's exit code into a file inside the container (so
`with_exec` stays green and its stdout is always exportable) and re-raises the
real failure afterward, instead of an `... || true` that would swallow it.

Platform note: the provisioning environment intentionally supports only
`x86_64-linux` and `aarch64-darwin`. `aarch64-linux` is not a Conductor target
and is excluded from the manifest, so a host-native Dagger run on an Apple
Silicon Mac cannot activate this Linux container successfully. Use a genuine
`x86_64-linux` host (the actual Conductor target class), or explicitly force
`DAGGER_PLATFORM=linux/amd64`; the latter may hit QEMU/Nix quirks unrelated
to Flox.
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
# aarch64-darwin only (envs/floxhub-provision/.flox/env/manifest.toml).
FULL_TOOLS = [
    "bd version",
    "roborev version",
    "uv --version",
    "dolt version",
    "infisical --version",
    "gh --version",
    "git version",
]

# Verify each tool actually resolves post-activation, don't just trust
# floxhub-provision.sh's exit code — a partial resolution failure (e.g.
# roborev present but bd missing) should be visible, not eaten.
VERIFY_RC_PATH = "/tmp/verify_rc"
BEADS_RC_PATH = "/tmp/beads_rc"


def verify_cmd(arch: str) -> str:
    # The manifest intentionally excludes aarch64-linux. Fail with a direct
    # platform message instead of attempting a partial five-tool activation.
    if arch != "x86_64":
        raise RuntimeError(
            "unsupported Dagger container architecture: "
            f"{arch}; this environment supports x86_64-linux only. "
            "Use DAGGER_PLATFORM=linux/amd64 or run on x86_64-linux."
        )
    check = " && ".join(FULL_TOOLS)
    return (
        "set +e; "
        f"flox activate --dir envs/floxhub-provision --mode run -- sh -c '{check}'; "
        f"echo $? > {VERIFY_RC_PATH}"
    )


def beads_cmd() -> str:
    # Keep the credential and the Dolt root inside the disposable container.
    # The pull script itself removes the temporary credential root on exit;
    # only the cloned .beads database remains for the read checks.
    return (
        "set +e; "
        "flox activate --dir envs/floxhub-provision --mode run -- "
        "bash scripts/beads-dolthub-pull.sh; "
        "pull_rc=$?; "
        "if [ $pull_rc -eq 0 ]; then "
        "  flox activate --dir envs/floxhub-provision --mode run -- "
        "bash scripts/beads-read-check.sh; "
        "  check_rc=$?; "
        "else check_rc=$pull_rc; fi; "
        "echo $check_rc > " + BEADS_RC_PATH
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

    require_beads = os.environ.get("REQUIRE_BEADS_CHECK", "").strip() == "1"
    infisical_token = os.environ.get("INFISICAL_TOKEN", "").strip()
    infisical_project_id = os.environ.get("INFISICAL_PROJECT_ID", "").strip()
    if require_beads and (not infisical_token or not infisical_project_id):
        print(
            "error: REQUIRE_BEADS_CHECK=1 requires INFISICAL_TOKEN and "
            "INFISICAL_PROJECT_ID",
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

        if infisical_token:
            container = container.with_secret_variable(
                "INFISICAL_TOKEN", client.set_secret("infisical-token", infisical_token)
            )
        if infisical_project_id:
            container = container.with_secret_variable(
                "INFISICAL_PROJECT_ID",
                client.set_secret("infisical-project-id", infisical_project_id),
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

        if require_beads:
            beads = container.with_exec(
                ["sh", "-c", beads_cmd()], expect=dagger.ReturnType.ANY
            )
            beads_stdout = await beads.stdout()
            beads_stderr = await beads.stderr()
            beads_rc = (await beads.file(BEADS_RC_PATH).contents()).strip()
            if beads_stdout:
                print(beads_stdout)
            if beads_stderr:
                print(beads_stderr, file=sys.stderr)
            if beads_rc != "0":
                raise RuntimeError(
                    "Beads/DoltHub bootstrap or bd read checks failed "
                    f"(exit {beads_rc})"
                )
            print("Beads/DoltHub bootstrap and bd ready/list/show checks passed.")

    print(
        f"All {len(FULL_TOOLS)} tools resolved under envs/floxhub-provision "
        "in a disposable container."
    )


if __name__ == "__main__":
    anyio.run(main)
