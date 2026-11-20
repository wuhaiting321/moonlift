#!/usr/bin/env bash
# Gate: everything a reviewer runs before trusting a commit.
#
#   bash script/check.sh
#
# Exits non-zero if any check fails. No network access required (the corpus
# binaries are committed; regenerating them needs Node and `wabt`).
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
# `moon run` prints the program's stdout plus tool chatter on stderr; only stdout
# is matched, and the exit code is compared separately.
cli() {
  moon run cmd/main --target "${TARGET:-wasm-gc}" -- "$@" 2>/dev/null
}

step "format"
run "moon fmt --check" moon fmt --check

step "check (all targets)"
run "moon check --target wasm-gc" moon check --target wasm-gc
run "moon check --target js" moon check --target js
run "moon check --target wasm" moon check --target wasm

step "unit tests"
run "moon test --target wasm-gc" moon test --target wasm-gc
run "moon test --target js" moon test --target js

step "CLI: version, help, usage"
out=$(cli version)
if printf '%s' "$out" | grep -q '^moonlift 0\.1\.0'; then
  printf 'ok   version banner\n'
else
  printf 'FAIL version banner\n'; fail=1
fi

out=$(cli help)
if printf '%s' "$out" | grep -q 'info <file.wasm>'; then
  printf 'ok   help lists info\n'
else
  printf 'FAIL help text\n'; fail=1
fi

out=$(cli frobnicate)
if printf '%s' "$out" | grep -q "unknown command" && printf '%s' "$out" | grep -q "exit 2"; then
  printf 'ok   unknown command exits 2\n'
else
  printf 'FAIL unknown command\n'; fail=1
fi

out=$(cli info)
if printf '%s' "$out" | grep -q "needs a path"; then
  printf 'ok   info without a path is a usage error\n'
else
  printf 'FAIL info usage\n'; fail=1
fi

out=$(cli info does-not-exist.wasm)
if printf '%s' "$out" | grep -q "cannot read" ; then
  printf 'ok   missing file reported as unreadable\n'
else
  printf 'FAIL missing file\n'; fail=1
fi

step "corpus: every well-formed fixture decodes"
good=0
for f in corpus/good/*.wasm; do
  out=$(cli info "$f")
  if printf '%s' "$out" | grep -q '^file      ' && printf '%s' "$out" | grep -q '^sections  '; then
    good=$((good + 1))
  else
    printf 'FAIL %s\n' "$f"
    printf '%s\n' "$out" | head -5
    fail=1
  fi
done
printf 'ok   %d good fixtures decoded\n' "$good"

step "corpus: every malformed fixture is rejected with a code and an offset"
bad=0
for f in corpus/bad/*.wasm; do
  out=$(cli info "$f")
  if printf '%s' "$out" | grep -qE 'E0[0-9]{2} at byte [0-9]+|E1[0-9]{2} at byte [0-9]+'; then
    bad=$((bad + 1))
  else
    printf 'FAIL %s was not rejected with E0xx/E1xx + offset\n' "$f"
    printf '%s\n' "$out" | head -5
    fail=1
  fi
done
printf 'ok   %d malformed fixtures rejected\n' "$bad"

step "cross-target: same fixture, three backends, identical report"
for f in corpus/good/fib.wasm corpus/good/globals.wasm corpus/good/moonbit_fib.wasm; do
  a=$(moon run cmd/main --target wasm-gc -- info "$f" 2>/dev/null)
  b=$(moon run cmd/main --target js -- info "$f" 2>/dev/null)
  c=$(moon run cmd/main --target wasm -- info "$f" 2>/dev/null)
  if [ "$a" = "$b" ] && [ "$a" = "$c" ] && [ -n "$a" ]; then
    printf 'ok   %s identical on wasm-gc / js / wasm\n' "$f"
  else
    printf 'FAIL %s differs across backends\n' "$f"
    fail=1
  fi
done

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf 'ALL GREEN\n'
else
  printf 'SOME CHECKS FAILED\n'
fi
exit "$fail"
