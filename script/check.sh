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

step "corpus: code-layer corruption is caught with the code in the filename"
# Two claims per file, and both matter: `info` must still accept the container
# (the layers are independent), and the body must be rejected with exactly the
# expected code. `--stack` is the analyser used here because it is the strongest
# of the three: it runs the decoder *and* the type checker, so a sample that only
# fails type checking is still caught. The one such sample is checked separately
# below, where plain `disasm` must still list it.
for f in corpus/badcode/*.wasm; do
  want=$(basename "$f" | sed -E 's/.*_([eE][0-9]{3})\.wasm/\1/' | tr 'a-z' 'A-Z')
  got=$(cli disasm "$f" --stack | grep -oE 'E[0-9]{3} at byte [0-9]+' | head -1)
  case "$got" in
    "$want at byte "*) printf 'ok   %s -> %s\n' "$(basename "$f")" "$got" ;;
    *) printf 'FAIL %s expected %s, got %s\n' "$(basename "$f")" "$want" "${got:-nothing}"; fail=1 ;;
  esac
  if cli info "$f" >/dev/null; then :; else
    printf 'FAIL %s: info should still describe the container\n' "$(basename "$f")"; fail=1
  fi
done

# The layers are independent in one direction only: a body that decodes but does
# not type-check is still *listed*. If `disasm` started type checking, this would
# fail — and the listing is what makes a type error debuggable in the first place.
if cli disasm corpus/badcode/type_mismatch_e011.wasm | grep -q 'f32.const'; then
  printf 'ok   a type error still lists (decode and type check are separate layers)\n'
else
  printf 'FAIL the type-mismatch sample no longer lists\n'; fail=1
fi

step "corpus: every body decodes, and only SIMD stops early"
# Expected partial bodies: exactly one, in the real compiler artifact, at a
# function whose name ends in `simd`. Anything else is a decoder regression.
stats=$(cli disasm corpus/good/moonbit_fib.wasm --stats)
if printf '%s' "$stats" | grep -q '^partial bodies  1$'; then
  printf 'ok   moonbit_fib: 1 partial body\n'
else
  printf 'FAIL moonbit_fib: expected exactly 1 partial body\n'
  printf '%s\n' "$stats" | head -6
  fail=1
fi
if printf '%s' "$stats" | grep -q 'simd'; then
  printf 'ok   the partial body is the SIMD helper\n'
else
  printf 'FAIL partial body is not the SIMD helper\n'; fail=1
fi
for f in corpus/good/*.wasm; do
  if cli disasm "$f" >/dev/null; then :; else printf 'FAIL %s does not disassemble\n' "$f"; fail=1; fi
done
printf 'ok   all good fixtures disassemble\n'

step "decoder vs wabt (independent implementation)"
if node corpus/tools/verify_decode.js > /tmp/moonlift_verify.log 2>&1; then
  printf 'ok   %s\n' "$(grep -E '^(matched|not attempted)' /tmp/moonlift_verify.log | tr '\n' ' ')"
else
  if grep -q '^SKIP' /tmp/moonlift_verify.log; then
    printf 'ok   skipped (wabt not installed: npm --prefix corpus/tools i wabt)\n'
  else
    printf 'FAIL decoder disagrees with wabt\n'
    tail -12 /tmp/moonlift_verify.log
    fail=1
  fi
fi

step "cfg: every body yields a block graph"
for f in corpus/good/*.wasm; do
  if cli disasm "$f" --cfg >/dev/null; then :; else
    printf 'FAIL %s --cfg\n' "$f"; fail=1
  fi
done
printf 'ok   all good fixtures produce a graph\n'

cfg=$(cli disasm corpus/good/moonbit_fib.wasm --cfg)
if printf '%s' "$cfg" | grep -q '^  skipped: stopped at byte .*simd'; then
  printf 'ok   the partial body is reported, not guessed at\n'
else
  printf 'FAIL the partial body is not reported in --cfg\n'; fail=1
fi
if printf '%s' "$cfg" | grep -q 'reducible no'; then
  printf 'FAIL structured wasm produced an irreducible graph\n'; fail=1
else
  printf 'ok   every complete body in the real artifact is reducible\n'
fi

# The four-way dispatch in control.wasm is the shape a `switch` compiles to: one
# `br_table` leaving three different block nests, so its first block has three
# successors and the graph has three exit edges. Pinning the exact line is
# deliberate — this is the number a regression in target resolution would move.
out=$(cli disasm corpus/good/control.wasm --cfg)
if printf '%s' "$out" | grep -q '^  b0   ops 0..2       succ b1 b2 b3$'; then
  printf 'ok   br_table dispatch resolves to three successors\n'
else
  printf 'FAIL br_table dispatch\n'
  printf '%s\n' "$out" | head -8
  fail=1
fi

step "stack: every fixture type-checks, and every block recovers"
for f in corpus/good/*.wasm; do
  if cli disasm "$f" --stack >/dev/null; then :; else
    printf 'FAIL %s --stack\n' "$f"; fail=1
  fi
done
printf 'ok   all good fixtures type-check\n'

# The real artifact is the only input large enough to exercise the recovery on
# code nobody wrote for it. The counts are pinned because every one of them is a
# claim in the README: 72 of 79 bodies analysed, 6 refused by name (bulk memory,
# two call_indirect, two multi-value), 1 skipped (SIMD).
stats=$(cli disasm corpus/good/moonbit_fib.wasm --stats)
if printf '%s' "$stats" | grep -q '^analysed        72 of 79 bodies$'; then
  printf 'ok   moonbit_fib: 72 of 79 bodies analysed\n'
else
  printf 'FAIL moonbit_fib: expected 72 analysed bodies\n'
  printf '%s\n' "$stats" | grep -E '^(analysed|skipped|refused)' | head -4
  fail=1
fi
if printf '%s' "$stats" | grep -q '^refused         6$'; then
  printf 'ok   moonbit_fib: 6 refusals, each named\n'
else
  printf 'FAIL moonbit_fib: expected 6 refusals\n'; fail=1
fi
if printf '%s' "$stats" | grep -q 'rejected'; then
  printf 'FAIL moonbit_fib: a valid module was rejected as malformed\n'; fail=1
else
  printf 'ok   moonbit_fib: nothing rejected as malformed\n'
fi
# 110 forced spills against 1 hazard spill is the shape the design predicts:
# almost every temporary is a call result (an ordering requirement of the source),
# and the reordering hazards are rare — but they are the ones that matter.
if printf '%s' "$stats" | grep -q '^spills          111 (110 forced, 1 hazard)$'; then
  printf 'ok   moonbit_fib: 111 spills, 1 of them a reordering hazard\n'
else
  printf 'FAIL moonbit_fib: spill counts changed\n'
  printf '%s\n' "$stats" | grep '^spills' ; fail=1
fi

# The two hazards, pinned to the line that would be wrong without the spill. A
# decompiler that evaluates the trees at the point of use prints `local 0 = local
# 0` order swapped, or nothing at all between the load and the store.
out=$(cli disasm corpus/good/stack.wasm --stack)
if printf '%s' "$out" | grep -q 't0 = local 0' &&
   printf '%s' "$out" | grep -q 'out \[i32\] = (i32.add(t0, local 0))'; then
  printf 'ok   a read live across an overwrite is sunk first\n'
else
  printf 'FAIL local-overwrite hazard\n'; fail=1
fi
if printf '%s' "$out" | grep -q 't0 = i32.load\[offset=0 align=4\](local 0)'; then
  printf 'ok   a load live across a store is sunk first\n'
else
  printf 'FAIL load/store hazard\n'; fail=1
fi
if printf '%s' "$out" | grep -q 'out \[i32\] = (i32.mul(local 0, local 0))'; then
  printf 'ok   local.tee followed by a read does not spill\n'
else
  printf 'FAIL tee must not spill\n'; fail=1
fi

step "struct: every body structures, and no raw branch statement survives"
# A structurer that silently gives up looks exactly like a good one unless the
# output is inspected: the fallback is to leave `br 1 ()` in place verbatim.
# Every branch must become `break` / `continue` / `brk = n; break`, and every
# `if (...)` block statement must become a real `if (...) { ... }`.
for f in corpus/good/*.wasm; do
  if ! out=$(cli disasm "$f" --struct); then
    printf 'FAIL %s does not structure\n' "$f"; fail=1
  elif [ -z "$out" ]; then
    printf 'FAIL %s structures to nothing\n' "$f"; fail=1
  else
    n=$(printf '%s' "$out" | grep -cE '^[[:space:]]*(br|br_if|br_table)([[:space:](]|$)|^[[:space:]]*if \(.*\)[[:space:]]*$')
    if [ "$n" -eq 0 ]; then
      printf 'ok   %s: no raw branch statement left\n' "$f"
    else
      printf 'FAIL %s: %s raw branch statement(s) left\n' "$f" "$n"; fail=1
    fi
  fi
done

step "struct: block coverage, and the pinned real-artifact counts"
# `blocks emitted N of N` is the structurer's own invariant: every reachable
# block is lowered exactly once. The other numbers are pinned so that a change
# in the tree walk shows up here as a diff rather than as a silent regression.
out=$(cli disasm corpus/good/moonbit_fib.wasm --struct-stats)
while IFS='|' read -r label want; do
  [ -z "$label" ] && continue
  got=$(printf '%s' "$out" | grep -E "^$label" | sed -E 's/^[a-z ]+ +//; s/ +$//')
  if [ "$got" = "$want" ]; then
    printf 'ok   %s = %s\n' "$label" "$want"
  else
    printf 'FAIL %s is [%s], expected [%s]\n' "$label" "$got" "$want"; fail=1
  fi
done <<'EOF'
structured|72 of 79 bodies
nodes|1012
blocks emitted|395 of 395
guards|32
switches|0
max depth|7
skipped|1
refused|6
EOF
# The two counts must add up: a body that is neither structured nor accounted
# for has been dropped somewhere.
a=$(printf '%s' "$out" | grep -E '^structured' | sed -E 's/[^0-9]+/ /g' | awk '{print $1}')
b=$(printf '%s' "$out" | grep -E '^(skipped|refused)' | awk '{s += $2} END {print s + 0}')
if [ "$((a + b))" -eq 79 ]; then
  printf 'ok   structured %s + skipped/refused %s = 79 bodies\n' "$a" "$b"
else
  printf 'FAIL %s structured + %s skipped/refused != 79 bodies\n' "$a" "$b"; fail=1
fi

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

step "cross-target: identical instruction stream"
for f in corpus/good/arith.wasm corpus/good/control.wasm corpus/good/moonbit_fib.wasm; do
  a=$(moon run cmd/main --target wasm-gc -- disasm "$f" --ops 2>/dev/null)
  b=$(moon run cmd/main --target js -- disasm "$f" --ops 2>/dev/null)
  c=$(moon run cmd/main --target wasm -- disasm "$f" --ops 2>/dev/null)
  if [ "$a" = "$b" ] && [ "$a" = "$c" ] && [ -n "$a" ]; then
    printf 'ok   %s decodes identically on wasm-gc / js / wasm\n' "$f"
  else
    printf 'FAIL %s instruction stream differs across backends\n' "$f"
    fail=1
  fi
done

step "cross-target: identical control-flow graph"
# The CFG sorts sets (loop nodes, tails) before printing, and an unstable sort
# would show up here as a backend-dependent byte difference.
for f in corpus/good/control.wasm corpus/good/moonbit_fib.wasm; do
  a=$(moon run cmd/main --target wasm-gc -- disasm "$f" --cfg 2>/dev/null)
  b=$(moon run cmd/main --target js -- disasm "$f" --cfg 2>/dev/null)
  c=$(moon run cmd/main --target wasm -- disasm "$f" --cfg 2>/dev/null)
  if [ "$a" = "$b" ] && [ "$a" = "$c" ] && [ -n "$a" ]; then
    printf 'ok   %s graphs identically on wasm-gc / js / wasm\n' "$f"
  else
    printf 'FAIL %s control-flow graph differs across backends\n' "$f"
    fail=1
  fi
done

step "cross-target: identical recovered expressions"
for f in corpus/good/control.wasm corpus/good/stack.wasm corpus/good/moonbit_fib.wasm; do
  a=$(moon run cmd/main --target wasm-gc -- disasm "$f" --stack 2>/dev/null)
  b=$(moon run cmd/main --target js -- disasm "$f" --stack 2>/dev/null)
  c=$(moon run cmd/main --target wasm -- disasm "$f" --stack 2>/dev/null)
  if [ "$a" = "$b" ] && [ "$a" = "$c" ] && [ -n "$a" ]; then
    printf 'ok   %s recovers identically on wasm-gc / js / wasm\n' "$f"
  else
    printf 'FAIL %s expressions differ across backends\n' "$f"
    fail=1
  fi
done

step "cross-target: identical structured control flow"
for f in corpus/good/control.wasm corpus/good/stack.wasm corpus/good/moonbit_fib.wasm; do
  a=$(moon run cmd/main --target wasm-gc -- disasm "$f" --struct 2>/dev/null)
  b=$(moon run cmd/main --target js -- disasm "$f" --struct 2>/dev/null)
  c=$(moon run cmd/main --target wasm -- disasm "$f" --struct 2>/dev/null)
  if [ "$a" = "$b" ] && [ "$a" = "$c" ] && [ -n "$a" ]; then
    printf 'ok   %s structures identically on wasm-gc / js / wasm\n' "$f"
  else
    printf 'FAIL %s structured control flow differs across backends\n' "$f"
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
