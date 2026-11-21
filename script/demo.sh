#!/usr/bin/env bash
# Three-minute demo: info -> disasm -> decompile -> verify, then the metric table.
#
#   bash script/demo.sh
#
# This is the short path a reviewer runs first. The full gate (`bash script/check.sh`)
# checks every pinned number; this script *measures* the cheap ones live and prints
# the rest with the command that reproduces them, so nothing here is a stale copy
# of a number someone typed by hand. No network, no C toolchain.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

cli() { moon run cmd/main --target "${TARGET:-wasm-gc}" -- "$@" 2>/dev/null; }
demo=/tmp/moonlift_demo
rm -rf "$demo"
mkdir -p "$demo"

printf '== 1/5  info — the real 20 KB compiler artifact\n'
cli info corpus/good/moonbit_fib.wasm | sed -n '1,8p'

printf '\n== 2/5  disasm --struct-stats — structuring coverage\n'
cli disasm corpus/good/moonbit_fib.wasm --struct-stats

printf '\n== 3/5  decompile — generate a MoonBit package and compile it\n'
cli decompile corpus/good/control.wasm -o "$demo/pkg" | sed -n '1,9p'
if ( cd "$demo/pkg" && moon check --target wasm-gc > "$demo/check.log" 2>&1 ); then
  printf 'moon check: %s error(s), %s warning(s)\n' \
    "$(grep -c 'Error: \[' "$demo/check.log")" \
    "$(grep -ci 'warning' "$demo/check.log")"
else
  printf 'moon check FAILED\n'; tail -8 "$demo/check.log"
fi

printf '\n== 4/5  verify — the generated code vs the original module in Node\n'
bash script/verify.sh corpus/good/control.wasm 2>&1 | tail -6

printf '\n== 5/5  metrics (measured now unless marked *)\n'
lines=$(find core runtime cmd -name '*.mbt' | xargs wc -l | tail -1 | awk '{print $1}')
good=$(ls corpus/good/*.wasm | wc -l | tr -d ' ')
ext=$(ls corpus/extended/*.wasm | wc -l | tr -d ' ')
bad=$(ls corpus/bad/*.wasm corpus/badcode/*.wasm | wc -l | tr -d ' ')
wabt=$(node corpus/tools/verify_decode.js 2>/dev/null | grep -E '^matched' | tr -s ' ')
printf '%-42s %s\n' 'MoonBit source lines' "$lines"
printf '%-42s %s\n' 'corpus modules (good + extended)' "$good + $ext = $((good + ext))"
printf '%-42s %s\n' 'malformed fixtures' "$bad"
printf '%-42s %s\n' 'decoder vs wabt' "$wabt"
printf '%-42s %s\n' 'white-box tests' "$(moon test --target wasm-gc 2>/dev/null | grep '^Total tests' | tail -1)"
printf '%-42s %s\n' 'generated packages compiling cleanly *' '41 / 41 (script/check.sh + script/extended.sh)'
printf '%-42s %s\n' 'differential calls *' '384 compared, 384 matched, 0 failed (script/verify.sh)'
printf '%-42s %s\n' 'cross-target identity *' 'wasm-gc / js / wasm identical (script/check.sh)'
printf '\n* full-gate numbers; run `bash script/check.sh` to re-verify (about 3.5 min).\n'
printf 'Full documentation: README.md (含申报书), BOUNDARY.md, docs/ACCEPTANCE.md\n'
