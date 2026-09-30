#!/usr/bin/env bash
#
# MoonProbe - official acceptance check (Linux / macOS)
#
# Runs, in order, the checks the project has to pass to be accepted:
#
#   1. core code size   non-test .mbt lines, required to exceed 1500
#   2. compile check    moon check --target wasm-gc / js, 0 error 0 warning
#   3. build check      moon build --target js
#   4. unit tests       moon test --target wasm-gc, every test green
#   5. formatting       moon fmt --check
#   6. commit history   commits reachable from HEAD
#
# Every check prints one [OK] / [FAIL] line, a failing check prints the tail of
# the command output, and the exit status is 0 only when all of them passed.
#
# Usage: bash check_验收.sh

set -u

cd "$(dirname "$0")" || exit 1

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

PASSED=0
FAILED=0

heading() { printf '\n== %s\n' "$1"; }
ok() { printf '   [OK]   %s\n' "$1"; PASSED=$((PASSED + 1)); }
no() { printf '   [FAIL] %s\n' "$1"; FAILED=$((FAILED + 1)); }
show_log() { sed 's/^/          /' "$LOG" | tail -n "${1:-30}"; }

# ---------------------------------------------------------------------------
# 1. Core code size
# ---------------------------------------------------------------------------

heading '1/6  Core code size (non-test .mbt)'

CORE_LINES="$(
  find . -type f -name '*.mbt' \
    ! -name '*_test.mbt' \
    ! -path './_build/*' \
    ! -path './.git/*' \
    -print0 | xargs -0 wc -l | tail -n 1 | awk '{print $1}'
)"
CORE_LINES="${CORE_LINES:-0}"

printf '   non-test .mbt lines: %s (required > 1500)\n' "$CORE_LINES"
if [ "$CORE_LINES" -gt 1500 ]; then
  ok "code size $CORE_LINES lines"
else
  no "code size $CORE_LINES lines is not above 1500"
fi

# ---------------------------------------------------------------------------
# 2. Compile check
# ---------------------------------------------------------------------------

heading '2/6  Compile check (0 error / 0 warning)'

for target in wasm-gc js; do
  if moon check --target "$target" --deny-warn >"$LOG" 2>&1; then
    ok "moon check --target $target --deny-warn"
  else
    no "moon check --target $target --deny-warn"
    show_log 40
  fi
done

# ---------------------------------------------------------------------------
# 3. Build check
# ---------------------------------------------------------------------------

heading '3/6  Build check (js)'

if moon build --target js >"$LOG" 2>&1; then
  ok 'moon build --target js'
else
  no 'moon build --target js'
  show_log 40
fi

# ---------------------------------------------------------------------------
# 4. Unit tests
# ---------------------------------------------------------------------------

heading '4/6  Unit tests (wasm-gc)'

if moon test --target wasm-gc >"$LOG" 2>&1; then
  SUMMARY="$(grep -m 1 'Total tests:' "$LOG" || true)"
  ok "moon test --target wasm-gc${SUMMARY:+ - $SUMMARY}"
else
  no 'moon test --target wasm-gc'
  show_log 60
fi

# ---------------------------------------------------------------------------
# 5. Formatting
# ---------------------------------------------------------------------------

heading '5/6  Formatting (moon fmt --check)'

if moon fmt --check >"$LOG" 2>&1; then
  ok 'moon fmt --check'
else
  no 'moon fmt --check'
  show_log 40
fi

# ---------------------------------------------------------------------------
# 6. Commit history
# ---------------------------------------------------------------------------

heading '6/6  Commit history'

COMMITS="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
COMMITS="${COMMITS:-0}"

printf '   commits reachable from HEAD: %s\n' "$COMMITS"
if [ "$COMMITS" -gt 0 ]; then
  ok "git history present"
else
  no 'no commits found'
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

heading 'Summary'

printf '   %s passed, %s failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -eq 0 ]; then
  printf '   Result: PASSED - MoonProbe meets the acceptance criteria\n'
  exit 0
fi
printf '   Result: FAILED\n'
exit 1