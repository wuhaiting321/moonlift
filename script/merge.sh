#!/usr/bin/env bash
# Two modules, one memory: the cross-module case, end to end.
#
#   bash script/merge.sh
#
# Why this cannot be a `verify.sh` case: `verify.sh` compares one module's calls
# against Node, and the property under test here does not exist inside a single
# module. It exists *between* two of them — `shared_a` grows a memory that
# `shared_b` only observes.
#
# Why it cannot be two packages either: each generated package copies
# `runtime.mbt`, so `pkg_a.Memory` and `pkg_b.Memory` are distinct types. A host
# cannot hand one instance to both, and "A grows, B sees it" becomes
# unrepresentable — the honest answer would be "supported in principle". One
# package, two modules, one `Memory` type, and the claim is a test.
#
# What is checked:
#
#   1. `moonlift decompile a.wasm b.wasm -o pkg` produces a package that
#      `moon check` accepts, with `m0_` / `m1_` prefixes on every top-level name.
#   2. Both modules' binding records are distinct (`M0_MoonliftExterns`,
#      `M1_MoonliftExterns`) but name the same field for the same import
#      (`env_mem`), which is what lets one object fill both.
#   3. With one `Memory` bound to both: a segment in A is readable in B, a store
#      in A is a load in B, and `memory.grow` in A changes `memory.size` in B.
#   4. With two `Memory` values bound: B stays at one page after A grows — the
#      sharing is the host's choice, not a side effect of merging.
#
# Then the same three questions for a shared *function table*, because a table is
# an externval too: A's element segment fills a slot, B calls through it, and the
# answer has to be A's function. `shared_tab_a` fills slot 0 with a function that
# returns 42; `shared_tab_b` only calls through slot 0, and its own function 0
# returns 7 — so a per-module index answers 7, which is the bug this pair catches.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

tmp=/tmp/moonlift_merge
rm -rf "$tmp"
mkdir -p "$tmp"

pass=0
fail=0
ok() {
  printf 'ok   %-56s %s\n' "$1" "$2"
  pass=$((pass + 1))
}
no() {
  printf 'FAIL %-56s %s\n' "$1" "$2"
  fail=$((fail + 1))
}

pkg="$tmp/pkg"
if moon run cmd/main --target "${TARGET:-wasm-gc}" -- decompile \
  corpus/good/shared_a.wasm corpus/good/shared_b.wasm -o "$pkg" \
  > "$tmp/decompile.log" 2>&1; then
  ok "merge: two modules, one package" "$(grep -c 'prefix m' "$tmp/decompile.log") prefixed"
else
  no "merge: two modules, one package" "see $tmp/decompile.log"
  printf 'merge: %d ok, %d failed\n' "$pass" "$fail"
  exit 1
fi

if ( cd "$pkg" && moon check > "$tmp/check.log" 2>&1 ); then
  ok "merge: the merged package compiles cleanly" "moon check"
else
  no "merge: the merged package compiles cleanly" "see $tmp/check.log"
  tail -6 "$tmp/check.log"
fi

# One field per module for the same import: the two records must agree on the
# name, because the host fills both with the same object.
fields=$(grep -c '^  env_mem : Memory$' "$pkg/module.mbt" 2>/dev/null || echo 0)
if [ "$fields" = "2" ] &&
  grep -q '^pub struct M0_MoonliftExterns {' "$pkg/module.mbt" &&
  grep -q '^pub struct M1_MoonliftExterns {' "$pkg/module.mbt"; then
  ok "merge: one name per import, two records" "env_mem × 2"
else
  no "merge: one name per import, two records" "see module.mbt"
fi

if grep -q 'm0_moonlift_init()' "$pkg/all.mbt" &&
  grep -q 'm1_moonlift_init()' "$pkg/all.mbt"; then
  ok "merge: one instantiation entry point" "moonlift_init_all"
else
  no "merge: one instantiation entry point" "see all.mbt"
fi

cp script/smoke/merge_wbtest.mbt "$pkg/merge_wbtest.mbt"
if ( cd "$pkg" && moon test --target "${TARGET:-wasm-gc}" > "$tmp/test.log" 2>&1 ); then
  ok "merge: one memory, four properties" "$(grep -E '^Total tests' "$tmp/test.log" | head -1)"
else
  no "merge: one memory, four properties" "see $tmp/test.log"
fi

# --- the same questions for a shared function table ------------------------
tabpkg="$tmp/tabpkg"
if moon run cmd/main --target "${TARGET:-wasm-gc}" -- decompile \
  corpus/good/shared_tab_a.wasm corpus/good/shared_tab_b.wasm -o "$tabpkg" \
  > "$tmp/tab_decompile.log" 2>&1; then
  ok "table: two modules, one table" "$(grep -c 'prefix m' "$tmp/tab_decompile.log") prefixed"
else
  no "table: two modules, one table" "see $tmp/tab_decompile.log"
fi

if ( cd "$tabpkg" && moon check > "$tmp/tab_check.log" 2>&1 ); then
  ok "table: the merged package compiles cleanly" "moon check"
else
  no "table: the merged package compiles cleanly" "see $tmp/tab_check.log"
  tail -6 "$tmp/tab_check.log"
fi

# The mechanism, in one line of generated code: m1's dispatcher has an arm that
# calls m0's function, because the slot m0 filled may hold it.
if grep -q '^    0 => m0_f0()$' "$tabpkg/module.mbt" &&
  grep -q '^    2 => m1_f0()$' "$tabpkg/module.mbt"; then
  ok "table: one index space, both modules in it" "0 => m0_f0, 2 => m1_f0"
else
  no "table: one index space, both modules in it" "see module.mbt"
fi

cp script/smoke/merge_tab_wbtest.mbt "$tabpkg/merge_tab_wbtest.mbt"
if ( cd "$tabpkg" && moon test --target "${TARGET:-wasm-gc}" > "$tmp/tab_test.log" 2>&1 ); then
  ok "table: one table, three properties" "$(grep -E '^Total tests' "$tmp/tab_test.log" | head -1)"
else
  no "table: one table, three properties" "see $tmp/tab_test.log"
  tail -12 "$tmp/tab_test.log"
fi

printf 'merge: %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
