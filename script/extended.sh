#!/usr/bin/env bash
# The extended corpus: 31 modules produced by MoonBit's own compiler.
#
#   bash script/extended.sh
#
# For each binary this checks three things, in increasing order of strength:
#   1. the SHA-256 recorded in corpus/extended/SHA256SUMS still matches,
#   2. `moonlift info` accepts it as a well-formed module,
#   3. `moonlift decompile` writes a package that `moon check` accepts with no
#      errors *and no warnings*.
#
# These modules are deliberately kept out of `corpus/good/`, whose fixtures are
# pinned down to exact instruction and node counts. Compiler output changes with
# every toolchain release; pinning its internals would make the gate fail on a
# compiler upgrade rather than on a bug in moonlift. What is pinned here is the
# *shape* of the claim: every real module decodes, and every generated package
# compiles cleanly. Nothing here is compared against a reference engine: these
# programs all import a host (`println`), so Node cannot run them standalone.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

cli() { moon run cmd/main --target "${TARGET:-wasm-gc}" -- "$@" 2>/dev/null; }

gen=/tmp/moonlift_extended
rm -rf "$gen"
mkdir -p "$gen"

fail=0
n=0
bodies=0
refs=0
skips=0

printf '%-20s %8s %7s %7s %7s\n' module bytes emitted refused skipped

for f in corpus/extended/*.wasm; do
  name=$(basename "$f" .wasm)
  want=$(grep "  $name.wasm\$" corpus/extended/SHA256SUMS | cut -d' ' -f1)
  got=$(sha256sum "$f" | cut -d' ' -f1)
  if [ "$want" != "$got" ] || [ -z "$want" ]; then
    printf 'FAIL %-20s checksum mismatch (or missing from SHA256SUMS)\n' "$name"
    fail=$((fail + 1))
    continue
  fi

  info=$(cli info "$f")
  if ! printf '%s' "$info" | grep -q 'WebAssembly binary, version 1'; then
    printf 'FAIL %-20s does not decode\n' "$name"
    fail=$((fail + 1))
    continue
  fi

  d="$gen/$name"
  out=$(cli decompile "$f" -o "$d")
  line=$(printf '%s' "$out" | sed -n '2p')
  emitted=$(printf '%s' "$line" | sed -E 's/^functions +([0-9]+) emitted.*/\1/')
  refused=$(printf '%s' "$line" | sed -E 's/.* ([0-9]+) refused.*/\1/')
  skip=$(printf '%s' "$line" | sed -E 's/.* ([0-9]+) skipped.*/\1/')

  if ! ( cd "$d" && moon check --target wasm-gc > "$gen/check.log" 2>&1 ); then
    printf 'FAIL %-20s generated package does not compile\n' "$name"
    grep -A4 'Error: \[' "$gen/check.log" | head -10
    fail=$((fail + 1))
    continue
  fi
  if grep -qi 'warning' "$gen/check.log"; then
    printf 'FAIL %-20s generated package compiles with warnings\n' "$name"
    grep -A3 'Warning' "$gen/check.log" | head -6
    fail=$((fail + 1))
    continue
  fi

  size=$(wc -c < "$f")
  printf '%-20s %8d %7d %7d %7d\n' "$name" "$size" "$emitted" "$refused" "$skip"
  n=$((n + 1))
  bodies=$((bodies + emitted))
  refs=$((refs + refused))
  skips=$((skips + skip))
done

printf '\n%d modules, %d function bodies emitted, %d refused, %d skipped\n' \
  "$n" "$bodies" "$refs" "$skips"

if [ "$n" -lt 30 ]; then
  echo "extended: expected at least 30 modules, got $n"
  fail=$((fail + 1))
fi
if [ "$fail" -ne 0 ]; then
  echo "extended: $fail module(s) FAILED"
  exit 1
fi
echo "extended: every real-compiler module decodes and decompiles into a clean package"
