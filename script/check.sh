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
# claim in the README: 75 of 79 bodies analysed, 3 refused by name (bulk memory,
# two multi-value), 1 skipped (SIMD). Before `call_indirect` was generated the
# count was 72 and 6 — three real bodies were refused for a construct this
# project now handles.
stats=$(cli disasm corpus/good/moonbit_fib.wasm --stats)
if printf '%s' "$stats" | grep -q '^analysed        75 of 79 bodies$'; then
  printf 'ok   moonbit_fib: 75 of 79 bodies analysed\n'
else
  printf 'FAIL moonbit_fib: expected 75 analysed bodies\n'
  printf '%s\n' "$stats" | grep -E '^(analysed|skipped|refused)' | head -4
  fail=1
fi
if printf '%s' "$stats" | grep -q '^refused         3$'; then
  printf 'ok   moonbit_fib: 3 refusals, each named\n'
else
  printf 'FAIL moonbit_fib: expected 3 refusals\n'; fail=1
fi
if printf '%s' "$stats" | grep -q 'rejected'; then
  printf 'FAIL moonbit_fib: a valid module was rejected as malformed\n'; fail=1
else
  printf 'ok   moonbit_fib: nothing rejected as malformed\n'
fi
# 110 forced spills against 1 hazard spill is the shape the design predicts:
# almost every temporary is a call result (an ordering requirement of the source),
# and the reordering hazards are rare — but they are the ones that matter.
if printf '%s' "$stats" | grep -q '^spills          115 (114 forced, 1 hazard)$'; then
  printf 'ok   moonbit_fib: 115 spills, 1 of them a reordering hazard\n'
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
#
# `nodes` is 1115, and the six over the 1109 the first S6 gate recorded are the
# six `br_if`-to-the-end-of-the-body sites that used to be emitted as bare
# returns: each one now needs an `if` wrapper to keep its condition.
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
structured|75 of 79 bodies
nodes|1136
blocks emitted|400 of 400
guards|32
switches|0
max depth|7
skipped|1
refused|3
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

step "decompile: every fixture produces a package that compiles cleanly"
# The claim is not "it writes files": it is that the files are MoonBit a compiler
# accepts, with nothing left to warn about. Warnings count here too, because the
# emitter spends real work on them (underscored names for locals nothing reads, a
# `mut` only where something is stored, unreachable tails dropped), and a
# regression in any of that shows up as a warning rather than as an error.
gen=/tmp/moonlift_gen
rm -rf "$gen"
mkdir -p "$gen"
while IFS='|' read -r wasm want; do
  [ -z "$wasm" ] && continue
  d="$gen/${wasm%.wasm}"
  out=$(cli decompile "corpus/good/$wasm" -o "$d")
  got=$(printf '%s' "$out" | sed -n '2p' | sed -E 's/^functions +//')
  if [ "$got" != "$want" ]; then
    printf 'FAIL %s: [%s], expected [%s]\n' "$wasm" "$got" "$want"
    fail=1
    continue
  fi
  if ( cd "$d" && moon check --target wasm-gc > /tmp/moonlift_gen.log 2>&1 ); then
    if grep -qi 'warning' /tmp/moonlift_gen.log; then
      printf 'FAIL %s: generated package compiles with warnings\n' "$wasm"
      grep -A3 'Warning' /tmp/moonlift_gen.log | head -6
      fail=1
    else
      printf 'ok   %s: %s, and the package compiles with 0 warnings\n' "$wasm" "$want"
    fi
  else
    printf 'FAIL %s: generated package does not compile\n' "$wasm"
    grep -A4 'Error: \[' /tmp/moonlift_gen.log | head -10
    fail=1
  fi
done <<'EOF'
arith.wasm|13 emitted, 0 refused, 0 skipped
control.wasm|6 emitted, 0 refused, 0 skipped
fib.wasm|3 emitted, 0 refused, 0 skipped
globals.wasm|5 emitted, 0 refused, 0 skipped
imports.wasm|3 emitted, 0 refused, 0 skipped
imported.wasm|8 emitted, 0 refused, 0 skipped
alias.wasm|4 emitted, 0 refused, 0 skipped
memory.wasm|6 emitted, 0 refused, 0 skipped
nested.wasm|2 emitted, 0 refused, 0 skipped
stack.wasm|8 emitted, 0 refused, 0 skipped
table.wasm|6 emitted, 0 refused, 0 skipped
indirect.wasm|12 emitted, 0 refused, 0 skipped
moonbit_fib.wasm|75 emitted, 3 refused, 1 skipped
EOF

# A refused body still gets a function: the signature is real and the body traps.
# Dropping it instead would leave its callers uncompilable, which is what the
# first version of the emitter did — 155 errors on the real artifact, all of them
# "identifier f47 is unbound".
if [ -f "$gen/moonbit_fib/funcs.mbt" ]; then
  n=$(grep -c '^pub fn f' "$gen/moonbit_fib/funcs.mbt")
  s=$(grep -cE '^/// wasm function [0-9]+: \*\*not decompiled\*\*' "$gen/moonbit_fib/funcs.mbt")
  if [ "$n" -eq 79 ] && [ "$s" -eq 4 ]; then
    printf 'ok   moonbit_fib: 79 function definitions, 4 of them trapping stubs\n'
  else
    printf 'FAIL moonbit_fib: %s definitions, %s stubs (expected 79 and 4)\n' "$n" "$s"
    fail=1
  fi
else
  printf 'FAIL moonbit_fib was not generated\n'; fail=1
fi

step "decompile: the generated package behaves like the original"
# Compiling is not behaving. Each fixture below is generated, given a test file
# from `script/smoke/`, and run. The expected values in those files came from the
# *original* module under Node (`corpus/tools/oracle.js`), so this compares two
# implementations rather than one implementation against itself.
#
# Three bugs found while writing the emitter were invisible to the compile check:
# a conditional branch to the end of the body emitted as an unconditional
# `return` (a loop that runs once), a block entry value read without ever being
# written, and a dispatch that carries a value read from a temporary nobody
# stored. All three change values, and only these tests would have said so.
for pair in control:control_wbtest.mbt fib:fib_wbtest.mbt nested:nested_wbtest.mbt \
  table:table_wbtest.mbt indirect:indirect_wbtest.mbt imported:imported_wbtest.mbt; do
  f=${pair%%:*}
  t=${pair##*:}
  d="$gen/$f"
  if [ ! -d "$d" ]; then
    printf 'FAIL %s was not generated\n' "$f"; fail=1; continue
  fi
  cp "script/smoke/$t" "$d/$t"
  if ( cd "$d" && moon test --target wasm-gc > /tmp/moonlift_smoke.log 2>&1 ); then
    printf 'ok   %s: %s\n' "$f" "$(grep -E '^Total tests' /tmp/moonlift_smoke.log | head -1)"
  else
    printf 'FAIL %s: generated code does not behave like the original\n' "$f"
    tail -8 /tmp/moonlift_smoke.log
    fail=1
  fi
done

step "verify: the generated packages agree with the original modules"
# The only check here that compares against an implementation that is not this
# one. `script/verify.sh` asks Node to run the *original* module for every planned
# call, writes the values into a test file inside the generated package, and runs
# it; the numbers below are pinned so that a drop in coverage is visible rather
# than absorbed.
#
# `moonbit_fib` is excluded and says so: it calls into a host, and a host is
# exactly what neither side has. Its generated package still compiles (the step
# above proves it) and its imports are trapping stubs. `imported` is now
# *included*: the plan carries the shape of every non-function import, so Node
# can build the host object and the comparison covers the exports that do not go
# through a function import.
if bash script/verify.sh > /tmp/moonlift_verify.log 2>&1; then
  line=$(grep '^calls compared:' /tmp/moonlift_verify.log)
  compared=$(printf '%s' "$line" | sed -E 's/.*compared: ([0-9]+).*/\1/')
  matched=$(printf '%s' "$line" | sed -E 's/.*matched: ([0-9]+).*/\1/')
  skipped=$(printf '%s' "$line" | sed -E 's/.*skipped \(trap\/NaN\): ([0-9]+).*/\1/')
  failed=$(printf '%s' "$line" | sed -E 's/.*failed: ([0-9]+).*/\1/')
  if [ "$compared" -eq 498 ] && [ "$matched" -eq 498 ] && [ "$failed" -eq 0 ]; then
    printf 'ok   498 calls compared against Node, 498 matched, %s skipped\n' "$skipped"
  else
    printf 'FAIL verify: %s compared, %s matched, %s failed (expected 498/498/0)\n' \
      "$compared" "$matched" "$failed"
    fail=1
  fi
  # A skipped call is a call where the original trapped or returned NaN, so it is
  # not evidence either way. The count is pinned for the same reason as above:
  # if it jumps, coverage moved even though every assertion still passed.
  if [ "$skipped" -le 280 ]; then
    printf 'ok   skipped calls stayed at %s (traps and NaNs in the original)\n' "$skipped"
  else
    printf 'FAIL verify: %s calls were skipped, expected at most 280\n' "$skipped"
    fail=1
  fi
else
  printf 'FAIL verify: the generated packages do not agree with the originals\n'
  grep -E '^(TOTAL|verify:|.*FAILED)' /tmp/moonlift_verify.log | head -6
  fail=1
fi

step "indirect: values equal, and the traps fire in the dispatcher"
# `verify.sh` counts a call whose original traps as skipped. For `call_indirect`
# that is most of the interesting surface, because three of its four outcomes
# are traps: the index is outside the table, the slot was never initialised, or
# the function there has another signature. `script/indirect.sh` runs one
# process per call, compares value-vs-value and trap-vs-trap, and requires the
# generated message to name `call_indirect` when the original's trap came from
# the table — so an unrelated crash cannot be counted as the right trap.
if bash script/indirect.sh > /tmp/moonlift_indirect.log 2>&1; then
  while read -r line; do
    printf 'ok   %s\n' "$line"
  done <<< "$(grep -E '^(indirect|table) ' /tmp/moonlift_indirect.log)"
else
  printf 'FAIL indirect: a value or a trap disagrees with the original\n'
  grep -E 'case |FAILED' /tmp/moonlift_indirect.log | head -6
  fail=1
fi

step "sharing: imported instances are bound, not copied"
# The reviewer's question, as a gate: two import entries naming one `(module,
# name)` must be one cell, binding must replace the stand-in, and binding must
# not mean pre-filling — a fresh memory handed to `moonlift_bind()` gets the
# module's segments in `moonlift_init()`. `verify.sh` compares one call at a
# time; these are properties of the binding model, which no single call shows.
if bash script/sharing.sh > /tmp/moonlift_sharing.log 2>&1; then
  while read -r line; do
    printf '%s\n' "$line"
  done <<< "$(grep -E '^ok ' /tmp/moonlift_sharing.log)"
else
  printf 'FAIL sharing: a binding property does not hold\n'
  grep -E '^(FAIL|sharing:)' /tmp/moonlift_sharing.log | head -6
  fail=1
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

step "cross-target: identical verification plan"
# The plan decides what gets compared, so it must not depend on the backend that
# produced it: a different ordering would mean a different set of calls.
# `moonbit_fib` is deliberately not here: its only export is `_start`, which
# returns nothing, so its plan is empty and there is nothing to compare.
for f in corpus/good/arith.wasm corpus/good/control.wasm; do
  rm -rf /tmp/moonlift_plan_a /tmp/moonlift_plan_b /tmp/moonlift_plan_c
  moon run cmd/main --target wasm-gc -- verify "$f" -o /tmp/moonlift_plan_a -n 6 >/dev/null 2>&1
  moon run cmd/main --target js -- verify "$f" -o /tmp/moonlift_plan_b -n 6 >/dev/null 2>&1
  moon run cmd/main --target wasm -- verify "$f" -o /tmp/moonlift_plan_c -n 6 >/dev/null 2>&1
  if cmp -s /tmp/moonlift_plan_a/calls.tsv /tmp/moonlift_plan_b/calls.tsv &&
     cmp -s /tmp/moonlift_plan_a/calls.tsv /tmp/moonlift_plan_c/calls.tsv &&
     [ -s /tmp/moonlift_plan_a/calls.tsv ]; then
    printf 'ok   %s plans identically on wasm-gc / js / wasm\n' "$f"
  else
    printf 'FAIL %s verification plan differs across backends\n' "$f"
    diff /tmp/moonlift_plan_a/calls.tsv /tmp/moonlift_plan_b/calls.tsv | head -4
    fail=1
  fi
done
rm -rf /tmp/moonlift_plan_a /tmp/moonlift_plan_b /tmp/moonlift_plan_c

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

step "extended corpus: real compiler output, checked end to end"
# `corpus/extended/` holds 31 modules built by MoonBit's own compiler, each with
# a recorded SHA-256 and the source that produced it. `script/extended.sh`
# verifies the checksum, decodes the module, decompiles it and runs `moon check`
# on the generated package with zero warnings. These are deliberately separate
# from `corpus/good/`: their internals are compiler-version-dependent, so pinning
# instruction counts on them would fail on a toolchain upgrade, not on a bug.
if bash script/extended.sh > /tmp/moonlift_extended.log 2>&1; then
  printf 'ok   %s\n' "$(grep '^extended:' /tmp/moonlift_extended.log | tail -1)"
  printf 'ok   %s\n' "$(grep 'modules,' /tmp/moonlift_extended.log | tail -1)"
else
  printf 'FAIL extended corpus\n'
  grep -E '^(FAIL|extended:)' /tmp/moonlift_extended.log | head -10
  fail=1
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf 'ALL GREEN\n'
else
  printf 'SOME CHECKS FAILED\n'
fi
exit "$fail"
