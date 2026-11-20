#!/usr/bin/env bash
# S0 gate: everything a reviewer runs before trusting a commit.
#
#   bash script/check.sh
#
# Exits non-zero on the first failure. No network access required.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fail=0
step() { printf '\n== %s\n' "$1"; }
run() {
  local label="$1"; shift
  if "$@"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label"
    fail=1
  fi
}

step "format"
run "moon fmt --check" moon fmt --check

step "check (all targets that exist today)"
run "moon check --target wasm-gc" moon check --target wasm-gc
run "moon check --target js" moon check --target js
run "moon check --target wasm" moon check --target wasm

step "unit tests"
run "moon test --target wasm-gc" moon test --target wasm-gc
run "moon test --target js" moon test --target js

step "CLI smoke"
out=$(moon run cmd/main --target wasm-gc -- version 2>&1)
printf '%s\n' "$out"
if printf '%s' "$out" | grep -q '^moonlift 0\.1\.0'; then
  printf 'ok   version banner\n'
else
  printf 'FAIL version banner\n'
  fail=1
fi

out=$(moon run cmd/main --target js -- help 2>&1)
if printf '%s' "$out" | grep -q 'Usage:'; then
  printf 'ok   help text\n'
else
  printf 'FAIL help text\n'
  fail=1
fi

out=$(moon run cmd/main --target wasm -- info dummy.wasm 2>&1)
if printf '%s' "$out" | grep -q "not implemented yet"; then
  printf 'ok   unimplemented command reports honestly\n'
else
  printf 'FAIL unimplemented command\n'
  fail=1
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf 'ALL GREEN\n'
else
  printf 'SOME CHECKS FAILED\n'
fi
exit "$fail"
