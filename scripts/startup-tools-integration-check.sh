#!/usr/bin/env bash
# Integration checks for every tool scripts/conductor-startup-script-cloud.sh
# provisions. Run AFTER the startup script, as the sandbox user, in a fresh
# login shell (so PATH is what a later agent shell sees). Beyond "--version
# works", the Python tools do real work against a throwaway project with its
# own .venv — the acceptance surface of issues #128/#129.
#
# Driven by scripts/dagger_startup_tools_test.py; also runnable by hand.
set -uo pipefail

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
# check <name> <cmd...>: passes when the command exits 0.
check() {
  local name="$1"
  shift
  if out="$("$@" 2>&1)"; then pass "${name}"; else
    fail "${name}: ${out}"
  fi
}
# check_fails <name> <cmd...>: passes when the command exits non-zero (the
# tool must actually DETECT the planted problem, not just run).
check_fails() {
  local name="$1"
  shift
  if out="$("$@" 2>&1)"; then fail "${name}: expected findings, got exit 0"; else
    pass "${name}"
  fi
}

# --- Presence + version: every provisioned command resolves ---------------
for tool in roborev trunk rwx entire uv uvx python python3 pytest reflex ruff pyright pyrefly; do
  if command -v "${tool}" >/dev/null 2>&1; then pass "on PATH: ${tool}"; else fail "on PATH: ${tool}"; fi
done
check "roborev --version" roborev version
check "rwx --version" rwx --version
check "entire --version" entire --version
# pi needs npm (Node 22.19+); the startup script SKIPs it without npm.
if command -v npm >/dev/null 2>&1; then
  check "pi --version" pi --version
else
  echo "SKIP  pi (no npm in this sandbox)"
fi
check "uvx --version" uvx --version
check "uv --version" uv --version
case "$(python3 --version 2>&1)" in "Python 3.11."*) pass "python3 is 3.11" ;; *) fail "python3 is not 3.11: $(command -v python3) $(python3 --version 2>&1)" ;; esac
check "pytest --version" pytest --version
check "reflex --version" reflex --version
check "ruff --version" ruff --version
check "pyright --version" pyright --version
check "pyrefly --version" pyrefly --version

# Pinned versions match the startup script.
STARTUP="${STARTUP_SCRIPT:-/src/scripts/conductor-startup-script-cloud.sh}"
for pair in ruff:RUFF_PIN pyright:PYRIGHT_PIN pyrefly:PYREFLY_PIN pytest:PYTEST_PIN; do
  tool="${pair%%:*}"
  var="${pair##*:}"
  pin="$(sed -n "s/^${var}=\"\([^\"]*\)\".*/\1/p" "${STARTUP}")"
  if "${tool}" --version 2>&1 | grep -q "${pin}"; then pass "${tool} pinned ${pin}"; else fail "${tool} not at pinned ${pin}"; fi
done

# --- Functional: a throwaway project with its own .venv -------------------
proj="$(mktemp -d)"
trap 'rm -rf "${proj}"' EXIT
cd "${proj}" || exit 1
check "uv venv" uv venv .venv
VENV_PY="${proj}/.venv/bin/python"

cat >good.py <<'PY'
def add(a: int, b: int) -> int:
    return a + b
PY
cat >bad.py <<'PY'
import os


def add(a: int, b: int) -> int:
    return a + b


x: int = add("1", "2")
PY
cat >test_good.py <<'PY'
from good import add


def test_add():
    assert add(1, 2) == 3
PY

# ruff: lints (unused import in bad.py), formats.
check "ruff check passes clean file" ruff check good.py
check_fails "ruff check flags unused import" ruff check bad.py
check "ruff format --check" ruff format --check good.py

# pyright: against the project's .venv interpreter.
check "pyright clean file (.venv)" pyright --pythonpath "${VENV_PY}" good.py
check_fails "pyright flags type error (.venv)" pyright --pythonpath "${VENV_PY}" bad.py

# pyrefly: against the project's .venv interpreter.
check "pyrefly clean file (.venv)" pyrefly check --preset default --python-interpreter-path "${VENV_PY}" good.py
check_fails "pyrefly flags type error (.venv)" pyrefly check --preset default --python-interpreter-path "${VENV_PY}" bad.py

# pytest + reflex run in the pytools environment.
check "pytest runs a test" pytest -q test_good.py
check "import reflex" "${HOME}/.conductor-pytools/bin/python" -c 'import reflex'

echo
if [[ ${failures} -eq 0 ]]; then
  echo "=== ALL INTEGRATION CHECKS PASSED ==="
else
  echo "=== ${failures} INTEGRATION CHECK(S) FAILED ==="
  exit 1
fi
