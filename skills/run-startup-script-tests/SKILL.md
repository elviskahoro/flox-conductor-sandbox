---
name: run-startup-script-tests
description: Use when you need to run or verify scripts/conductor-startup-script-cloud-test.sh (the container test for conductor-startup-script-cloud.sh), e.g. after changing pins, the roborev model, or the Pi install path. Covers the Colima Docker setup on macOS and what CI runs.
---

# Running the startup-script container test

`scripts/conductor-startup-script-cloud-test.sh` verifies `conductor-startup-script-cloud.sh` inside an `amazonlinux:2023` container. It is **Linux-only**: it reads `/proc/$$/cmdline` and expects the repo mounted at `/src`. Running it directly on macOS fails at once (`/proc/<pid>/cmdline: No such file or directory`). That is not a script bug; use a container.

## Preferred locally: apple/container (verified)

On Apple Silicon, try https://github.com/apple/container first. It runs the test natively on arm64, so it avoids the qemu guard below. Verified with `container` 1.1.0 on macOS 26.5: exit 0, `=== ALL CHECKS PASSED ===`.

```bash
container system start   # no-op if already running
container run --rm -v "$PWD":/src:ro -w /src \
  amazonlinux:2023 bash scripts/conductor-startup-script-cloud-test.sh
```

Note there is no `--platform linux/amd64`; this is the native arm64 image. CI still runs x86_64.

## Fallback: Colima (not Docker Desktop)

If you need Docker, it is provided here by **Colima**. The `docker` CLI is installed, but its daemon only exists while a Colima VM is running. If `docker info` fails, start it:

```bash
colima status || colima start
docker info >/dev/null && echo up
```

Do not assume Docker Desktop is available. Stop the VM with `colima stop` when done if the user wants resources back.

## Run it

Same command CI uses (`.github/workflows/conductor-startup-script-cloud.yml`):

```bash
docker run --platform linux/amd64 --rm \
  -v "$PWD":/src:ro -w /src \
  amazonlinux:2023 bash scripts/conductor-startup-script-cloud-test.sh
```

The test exits non-zero on the first broken assertion; the last lines say which.

## Gotchas

- **No qemu emulation (issue #92).** The test aborts with `running under qemu-... emulation` because the pinned Go binaries crash or hang under it. On an Apple Silicon Colima VM, `--platform linux/amd64` is emulated, so it will hit this guard. Either start Colima with an x86_64 VM (`colima start --arch x86_64`, itself emulated, so likely the same guard) or drop `--platform` to run natively on arm64. Prefer apple/container above, which is verified native arm64; if that fails for a script reason, rely on CI.
- **CI is the authoritative run** (x86_64 runner). Check it with `gh pr checks <PR>`.
- Also run `bash scripts/validate-pins.sh` on the host; it needs no container and checks the Pi/roborev pins and integrity hashes.
- After a pin bump, take `PI_INTEGRITY` from `npm view @earendil-works/pi-coding-agent@<ver> dist.integrity` verbatim; never retype it.
