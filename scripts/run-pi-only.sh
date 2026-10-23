#!/usr/bin/env bash
# Runs only the pi stages of the container test (issue #85): its setup and
# guards, RUN 1 (which provisions the tools later runs reuse), then RUN 13
# onward. Much faster than the full suite while iterating on pi_install.
# The runs are sliced out of the real test at runtime, so this never drifts
# from it. Same invocation as the full suite, on the host's NATIVE platform
# (the test refuses qemu emulation, issue #92):
#
#   docker run --platform linux/<native-arch> --rm -v "$PWD":/src:ro -w /src \
#     amazonlinux:2023 bash scripts/run-pi-only.sh
set -euo pipefail

TEST="$(cd "$(dirname "$0")" && pwd)/conductor-startup-script-cloud-test.sh"
for marker in '^echo "=== VERIFY: every deliverable' '^echo "=== RUN 13:'; do
  grep -q "${marker}" "${TEST}" || { echo "run-pi-only: marker ${marker} not found in ${TEST}" >&2; exit 1; }
done
sliced="$(mktemp)"
trap 'rm -f "${sliced}"' EXIT
{
  sed -n '1,/^echo "=== VERIFY: every deliverable/p' "${TEST}" | sed '$d'
  # The full suite installs git before RUN 3's `git init`; RUN 13+ need it.
  echo 'dnf install -y git >/dev/null'
  sed -n '/^echo "=== RUN 13:/,$p' "${TEST}"
} >"${sliced}"
bash "${sliced}"
