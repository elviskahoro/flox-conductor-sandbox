"""Dagger pipeline: run the startup script, then integration-check every tool.

Spins up a disposable amazonlinux:2023 container shaped like the real
sandbox (non-root user with passwordless sudo), runs
scripts/conductor-startup-script-cloud.sh with STARTUP_PY_DEV_TOOLS=1, then
runs scripts/startup-tools-integration-check.sh in a fresh login shell as that
user. The checks go beyond --version: ruff, pyright and pyrefly must flag
planted problems and pass clean code against a project `.venv`, and pytest
must run a test.

    uv run dagger run python scripts/dagger_startup_tools_test.py

Uses the host's native platform (never emulated — see the header of
scripts/conductor-startup-script-cloud-test.sh, issue #92). Mirrors
dagger_provision_test.py: the check's exit code is captured into a file so
output is always exportable, then re-raised.
"""

from __future__ import annotations

import sys

import anyio
import dagger

BASE_IMAGE = "amazonlinux:2023"
RC_PATH = "/tmp/integration_rc"

USER_SETUP_CMD = (
    "set -euo pipefail; "
    "dnf install -y sudo shadow-utils util-linux tar >/dev/null; "
    "useradd -m sandbox-user; "
    'echo "sandbox-user ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/sandbox-user; '
    "chmod 440 /etc/sudoers.d/sandbox-user; "
    # Under the Dagger engine pam_unix cannot read /etc/shadow, so sudo dies
    # with "PAM account management error" even for NOPASSWD. Permit-all PAM
    # for sudo restores what a real sandbox (and `docker run`) does.
    "printf 'auth sufficient pam_permit.so\\naccount sufficient pam_permit.so\\n"
    "session sufficient pam_permit.so\\n' >/etc/pam.d/sudo"
)

# Same posture as this repo's .conductor/settings.toml.
STARTUP_CMD = (
    "su - sandbox-user -c "
    "'cd /tmp && STARTUP_BEST_EFFORT=1 STARTUP_PY_DEV_TOOLS=1 "
    "bash /src/scripts/conductor-startup-script-cloud.sh'"
)

# Fresh login shell: PATH is what a later agent shell would get.
CHECK_CMD = (
    "set +e; "
    "su - sandbox-user -c 'bash /src/scripts/startup-tools-integration-check.sh'; "
    f"echo $? > {RC_PATH}"
)


async def main() -> None:
    async with dagger.Connection(dagger.Config(log_output=sys.stderr)) as client:
        source = client.host().directory(".", exclude=[".git", "tmp"])
        container = (
            client.container()
            .from_(BASE_IMAGE)
            .with_exec(["sh", "-c", USER_SETUP_CMD])
            .with_directory("/src", source)
        )
        # Privileged exec: without it the engine sets no_new_privs, so sudo
        # cannot elevate and the python3.11/placement stages silently differ
        # from a real sandbox.
        started = container.with_exec(
            ["sh", "-c", STARTUP_CMD], insecure_root_capabilities=True
        )
        print(await started.stdout())
        container = started
        checked = container.with_exec(
            ["sh", "-c", CHECK_CMD],
            expect=dagger.ReturnType.ANY,
            insecure_root_capabilities=True,
        )
        print(await checked.stdout())
        stderr = await checked.stderr()
        if stderr:
            print(stderr, file=sys.stderr)
        rc = (await checked.file(RC_PATH).contents()).strip()
        if rc != "0":
            raise RuntimeError(f"integration checks failed (exit {rc}); see above")
    print("All startup-script tools passed their integration checks.")


if __name__ == "__main__":
    anyio.run(main)
