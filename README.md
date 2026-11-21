# moonlift

**Decompile WebAssembly (MVP subset) binaries into compilable, readable MoonBit source.**

`moonlift` reads a `.wasm` file, recovers functions, control flow and expressions, and emits a
MoonBit package that `moon build` accepts and that behaves like the original module when run on
`wasm`, `wasm-gc` and `js`. Correctness is not asserted — it is measured: the expected values are
taken from the **original** module running under Node's `WebAssembly`, and the generated package has
to reproduce them.

> **Status: complete (S0–S11).** The pipeline runs end to end: bytes → sections →
> instructions → basic blocks → typed expressions → nested `while` / `if` / `match` → **MoonBit
> source that compiles and behaves like the original**. 152 white-box tests, 41 `.wasm` modules in
> the corpus, 19 malformed fixtures rejected with a stable error code and a byte offset.
>
> `moonlift info` describes a module; `disasm` decodes every body to `.wat`; `--cfg` prints blocks,
> dominators, natural loops and a reducibility verdict; `--stack` prints the recovered per-block
> expressions **and type-checks them**; `--struct` lowers the graph to nested `while` / `if` /
> `match` with no `br` left in it; `decompile` writes a MoonBit package; `verify` plans a
> differential run. On the real 20 KB artifact, 72 of 79 bodies are structured — **395 of 395
> reachable blocks emitted exactly once** — 6 are refused by name and 1 is skipped, with **nothing
> rejected as malformed**. All 10 good fixtures and all 31 real-compiler modules decompile into
> packages that `moon check` accepts **with zero errors and zero warnings**. The decoder is
> cross-checked against wabt, an independent implementation: **4,485 of 4,485 reachable
> instructions agree, 0 mismatches**, with 62 instructions in one SIMD helper deliberately not
> attempted. `script/verify.sh` compares **384 calls, 384 matched, 0 failed** against the original
> modules running in Node, and three generated packages are executed against values the originals
> produce. Everything is reproducible with one command: `bash script/check.sh` → `ALL GREEN`.
> See [Metrics](#metrics), [Roadmap](#roadmap), [BOUNDARY.md](BOUNDARY.md) and the
> [acceptance table](docs/ACCEPTANCE.md).

---

## Why this exists

MoonBit targets `wasm`, `wasm-gc`, `js` and `native`. The `wasm-gc` and `js` backends cannot link
against C FFI, so a large part of the existing C/Rust ecosystem is unreachable from them. A
decompiler is the only path that turns an existing `.wasm` artifact into MoonBit source that runs
on all backends — it is not "another library", it is a migration channel.

Ecosystem check (2026-11-20, full registry dump of mooncakes.io, **3,882 modules**):

| Query | Hits |
|---|---|
| `decompiler` / `wasm2mbt` / `wasm2c` in name, description or keywords | **0** |
| GitHub `moonbit+decompiler` (`total_count`) | **0** |
| Closest neighbours (`wasm` parsers, `wasm` emitters) | parsers only, no code recovery |

That is a statement about *searchable surface*, not a claim that nobody on earth has ever tried.

## Usage

```bash
moon build --target wasm-gc          # build the CLI
moon run cmd/main --target wasm-gc -- help
moon run cmd/main --target wasm-gc -- info   path/to/module.wasm
moon run cmd/main --target wasm-gc -- disasm path/to/module.wasm [--ops|--stats|--cfg|--stack|--struct]
moon run cmd/main --target wasm-gc -- decompile path/to/module.wasm -o out/
moon run cmd/main --target wasm-gc -- verify path/to/module.wasm -n 200

bash script/demo.sh        # 3-minute end-to-end demo + measured metrics
bash script/check.sh       # full gate (~3.5 min): ALL GREEN
bash script/verify.sh      # differential run against the originals in Node
bash script/extended.sh    # 31 real-compiler modules, end to end
```

`info` on a real compiler artifact:

```
$ moon run cmd/main --target wasm-gc -- info corpus/good/moonbit_fib.wasm
file      corpus/good/moonbit_fib.wasm (20312 bytes)
format    WebAssembly binary, version 1 (MVP subset)

sections  13
    id  name          offset      size
     1  type               8        89
     2  import            99        35
     ...
    12  datacount        292         1
    10  code             295      7657
    11  data            7955       745
     0  custom          8703     11535

types     14
imports   1 (all func; other import kinds are rejected)
functions 79 defined, 1 imported
...
functions
     #  name                        signature                         locals   bytes
     1  tlsf/searchBlock            (i32, i32) -> i32                      1     168
     ...

notes
  - 2 signature(s) return more than one value (multi-value proposal); code generation refuses those functions with E112 and emits a trapping stub
  - 1 function(s) declare v128 locals (typical of compiler memcpy helpers); code generation refuses them individually
```

`disasm` decodes bodies; `--stats` prints the numbers used to verify the decoder, `--ops` prints one
instruction per line for the wabt comparison, `--cfg` prints the control-flow graph, and `--stack`
prints the recovered expressions:

```
$ moon run cmd/main --target wasm-gc -- disasm corpus/good/moonbit_fib.wasm --stats
bodies          79
instructions    3878
max nesting     6
partial bodies  1
  f59 $_M0MPC15array10FixedArray32unsafe__blit__from__string__simd: stopped at byte 6298: 0xfd/0x00 (simd)
blocks          439
edges           583
loops           20
loop depth      1
reducible       78 of 79 bodies
irreducible     0
skipped         1
analysed        72 of 79 bodies
statements      870
temps           111
spill-free      33
spills          111 (110 forced, 1 hazard)
skipped         1
refused         6
  f25 moonbit.unsafe_make_string: refused — E109 at byte 2492: bulk-memory operations copy passive segments, ...
  f47 _M0IP016_24default__implPB4Show6outputGiE: refused — E111 at byte 5431: call_indirect dispatches through a table, ...
  f50 _M0IP016_24default__implPB6Logger16write__substringGRPB13StringBuilderE: refused — E112 at byte 5481: call returns 3 values; ...
  f51 _M0MPC16string6String21clamped__view_2einner: refused — E112 at byte 5812: \'if\' has a type index as its block type, ...
  f52 _M0IP016_24default__implPB6Logger5writeGRPB13StringBuilderE: refused — E111 at byte 5880: call_indirect ...
  f53 _M0IP016_24default__implPB6Logger28write__string__interpolationGRPB13StringBuilderE: refused — E111 at byte 5920: ...
  f59 $_M0MPC15array10FixedArray32unsafe__blit__from__string__simd: skipped — stopped at byte 6298: 0xfd/0x00 (simd)
```

`--stack` recovers expressions, and the same pass is a type checker. `tlsf/searchBlock` from the real
artifact — eight blocks, a loop-free search through a two-level bitmap, every statement an
expression tree:

```
$ moon run cmd/main --target wasm-gc -- disasm corpus/good/moonbit_fib.wasm --stack
func 1 tlsf/searchBlock (param i32 i32) (result i32)
  b0  in []  out [i32] = (local 0)
    if (i32.lt_u(local 1, i32.const 256))
  b1  in [i32]  out [i32, i32] = (in0, i32.const 0)
    local 1 = i32.shr_u(local 1, i32.const 4)
  b2  in [i32]  out [i32] = (in0)
    if (i32.lt_u(local 1, i32.const 536870910))
  b3  in [i32]  out [i32] = (in0)
    local 1 = i32.sub(i32.add(local 1, i32.shl(i32.const 1, i32.sub(i32.const 27, i32.clz(local 1)))), i32.const 1)
  ...
  b6  in []  out [i32] = (i32.load[offset=96 align=1](i32.add(local 0, i32.shl(i32.add(i32.ctz(local 1), i32.shl(local 2, i32.const 4)), i32.const 2))))
```

`in` / `out` are the operand-stack *shapes* at a block's edges; a value that arrives from a
predecessor is named `in0`, `in1`, because that is literally what it is — the block's parameter.
Statements are in program order and `out` is evaluated after the last one.

And the fixture that isolates the one thing a decompiler gets wrong quietly, a read that stays live
across a write:

```
$ moon run cmd/main --target wasm-gc -- disasm corpus/good/stack.wasm --stack
func 1 $f1 (param i32) (result i32)
  b0  in []  out [i32] = (i32.add(t0, local 0))
    t0 = local 0
    local 0 = i32.const 7
func 2 $f2 (param i32) (result i32)
  b0  in []  out [i32] = (t0)
    t0 = i32.load[offset=0 align=4](local 0)
    i32.store[offset=0 align=4](local 0, i32.const 99)
```

Without the first `t0 = local 0`, the function would compute `7 + 7` instead of `x + 7`; without the
second, it would return `99`. Both hazards are counted separately from the temporaries a call
forces (`110 forced, 1 hazard` above), because the forced ones are the source's own ordering and the
hazard ones are the decompiler's mistakes waiting to happen.

`--struct` is the step that turns the graph back into the shapes MoonBit has. It is not a graph
algorithm on blocks: wasm already carries its own nesting tree (`block` / `loop` / `if`, each with
an `end`), so the structurer walks that tree and only the escape depths — which a `br` encodes as a
number — have to be re-derived. Each `block` becomes a one-shot `while true { ... }` so that a
`break` exists to jump to its `end`; a `loop` becomes a real `while true`; and a branch that leaves
several constructs at once first writes down how far it is going, then unwinds one construct per
guard on the way out.

The four-way dispatch of `control.wasm` leaves the block nest at four different depths — a `switch`
over four arms, three of which jump past constructs they are nested inside:

```
$ moon run cmd/main --target wasm-gc -- disasm corpus/good/control.wasm --struct
func 0 $f0 (param i32) (result i32)
  ;; brk: 1 = c1, 2 = c2, 3 = c3, 4 = c4
  while true {   ;; c1, one-shot
    while true {   ;; c2, one-shot
      while true {   ;; c3, one-shot
        while true {   ;; c4, one-shot
          match (local 0) {
            0 => break
            1 => brk = 3; break   ;; leave c3
            2 => brk = 2; break   ;; leave c2
            _ => brk = 1; break   ;; leave c1
          }
          break
        }
        if (brk >= 0) {
          if (brk == 4) { brk = -1 }
          else { break }
        }
        break
      }
      ...
```

`brk` is the one piece of state the output needs: which construct a pending branch is leaving, or
`-1` for none. `break` inside the `match` lands on the innermost `while` — for `0` that is exactly
what `br $one` means, so it is emitted bare. For the other three the branch has further to go, so
`brk` records the destination and each guard on the way out either clears it (`brk == 4` means the
branch only left `c4`, so execution continues in `c3`) or passes it one level further out. Nothing
here is a state machine per block: the direct `br 0` case stays a plain `break`, and a `loop`'s back
edge stays a plain `continue`.

The loop fixture, where the exit condition arrives as a `br_if` out of a loop and lands on the
`block` that wraps it — the shape `break` in a `for` compiles to:

```
func 1 $f1 (param i32) (result i32)
  ;; brk: 1 = c1, 2 = c2
  while true {   ;; c1, one-shot
    while true {   ;; c2, loop
      if (i32.ge_s(local 2, local 0)) {
        brk = 1; break   ;; leave c1
      }
      local 1 = i32.add(local 1, local 2)
      local 2 = i32.add(local 2, i32.const 1)
      continue
      if (brk != 2) { break }
      brk = -1
    }
    if (brk >= 0) {
      if (brk == 2) { brk = -1 }
      else { break }
    }
    break
  }
```

`--struct-stats` reports the work and, more importantly, the invariant behind it:

```
structured      72 of 79 bodies
nodes           1115
blocks emitted  395 of 395
guards          32
switches        0
max depth       7
skipped         1
refused         6
```

`blocks emitted N of N` is a property, not a statistic: a structurer that drops a block or emits one
twice produces output that still parses and still looks right. Every function is therefore checked
against `visited == reachable`, and the whole suite against a second property — **no `br`, `br_if`,
`br_table` or bare `if (...)` statement may survive into the output**, because a fallback that
returns the graph unchanged would otherwise pass silently.

`--cfg` on the four-way dispatch fixture, which is the shape a `switch` compiles to — one `br_table`
leaving three different block nests, so block 0 has three successors:

```
$ moon run cmd/main --target wasm-gc -- disasm corpus/good/control.wasm --cfg
func 0 $f0 (param i32) (result i32)
  blocks 4  edges 6  loops 0  reducible yes
  b0   ops 0..2       succ b1 b2 b3
  b1   ops 2..4       succ exit
  b2   ops 4..6       succ exit
  b3   ops 6..7       succ exit
  idom b1<-b0  b2<-b0  b3<-b0
```

Exit codes: `0` success · `2` usage error · `3` input rejected (`E0xx`/`E1xx`) · `4` input
unreadable. MoonBit has no portable `exit()`, so the code is echoed as `moonlift: exit N`; scripts
grep for it.

## decompile

```bash
$ moon run cmd/main --target wasm-gc -- decompile corpus/good/control.wasm -o /tmp/out
corpus/good/control.wasm -> /tmp/out/
functions  6 emitted, 0 refused, 0 skipped
exports    6
memory     0 page(s), 0 data byte(s)
globals    0
imports    0
files      moon.mod moon.pkg module.mbt funcs.mbt exports.mbt runtime.mbt
```

Six files, and the package they form depends on nothing outside its own directory:

| File | Contents |
|---|---|
| `moon.mod`, `moon.pkg` | a module with no dependencies and no `prelude` beyond the standard one |
| `runtime.mbt` | the support library: indexed loads and stores, `div`/`rem` trapping, rotations, `trunc`, `min`/`max`, unsigned compares, `Memory`. Copied in, so the output builds anywhere |
| `module.mbt` | the linear memory with its data segments already copied in, the globals as `Ref`s, and a trapping stub per host import |
| `funcs.mbt` | one `pub fn f<n>` per function, in index order |
| `exports.mbt` | one wrapper per export, under the name the original published (sanitised when the name is a MoonBit keyword: `guard` becomes `e_guard`) |

`find_limit` from `control.wasm` — a loop with a `br_if` exit and a `return` inside it — comes back
as:

```moonbit
pub fn f4(p0 : Int) -> Int {
  let mut l1 : Int = 0
  let mut brk : Int = -1
  while true {
    while true {
      if (l1 >= p0) {
        brk = 1 // leave c1
        break
      }
      if (l1 == 7) {
        return l1
      }
      // b3
      l1 = (l1 + 1)
      continue
    }
    if brk >= 0 {
      if brk == 2 { brk = -1 }
      else { break }
    }
    break
  }
  brk = -1
  return -1
}
```

It is not pretty, and it is not meant to be: it is a *witness*. `brk` is a variable only where a
branch has to carry a destination two or more constructs out, and only the loops that need
`break`-with-destination get one. The comment `// b3` names the block in `disasm --struct` that the
statement came from, so the two can be read side by side.

**A refused body still becomes a function.** Its signature is real and its body is
`trap("f47 was not decompiled: E111 at byte 5431: ...")`. Dropping it instead — the first thing the
emitter did — leaves every caller uncompilable: 7 errors on the real artifact, each one "the value
identifier `f47` is unbound", one per refused function that something still calls. A stub keeps the
module buildable and stops loudly at exactly the call that would otherwise return a wrong value.

**Compiling is not behaving.** `script/check.sh` decompiles all 10 good fixtures, runs `moon check`
in each, and requires **0 errors and 0 warnings**; then it copies the test files from
`script/smoke/` into the generated packages for `control.wasm`, `fib.wasm` and `nested.wasm` and
runs them. A second step (`script/extended.sh`) does the same — checksum, decode, decompile, zero-
warning `moon check` — for 31 modules produced by MoonBit's own compiler. The expected values in
the smoke files came from the *original* module under Node (`corpus/tools/oracle.js`), so the
comparison is between two implementations.

Three bugs were found this way and are now pinned by tests:

- a `br_if` whose target is the end of the body was emitted as an unconditional `return`, which
  turns "return if the buffer is empty" into "return" — the difference between a loop and a body
  that quits on its first iteration;
- a block's entry value was printed as `in0` with nothing binding it. Every block was still emitted
  exactly once, so the coverage invariant passed while the code was unbuildable;
- a `br_table` with a value on the stack read that value from a temporary nobody had written —
  `nested.wasm` is the fixture, and all three of its dispatch arms are compared against the
  original. The fix is documented as D12 in `BOUNDARY.md`.

A fourth class only showed up as compiler output, not as wrong values: unused parameters, locals
that nothing reads, a `mut` nothing stores to, and an integer literal used as a method receiver
(`63.to_int64()` is lexed as a float). The emitter now names the first three `_p0` / `_l3` / `_t2`,
declares `mut` only where something is written, and parenthesises literal receivers — which is why
all 41 generated packages are warning-free rather than merely error-free. A fifth was a real
semantic omission: a function returning two values had its second result silently dropped; it is
now refused with `E112` and emitted as a trapping stub.

## verify

```bash
$ bash script/verify.sh
fixture            calls matched skipped  note
arith                 76      76     130  -
control               85      85       1  -
fib                   21      21       0  -
globals               17      17       0  -
imports                3       -       -  the original needs a host: ...
memory                49      49      24  -
moonbit_fib            0       -       -  no exported function to call
nested                30      30       0  -
stack                 92      92       6  -
table                 14      14       0  -

TOTAL                384     384     164
calls compared: 384, matched: 384, skipped (trap/NaN): 164, failed: 0
verify: every compared call matched the original
```

`moonlift verify foo.wasm -o out/` writes the same package as `decompile` plus `calls.tsv`, the list
of calls to make; `script/verify.sh` asks Node to run each of them on the **original** module
(`corpus/tools/oracle.js`), writes the answers into a test file inside the generated package, and
runs `moon test` on it. The comparison is between two implementations, not one implementation
against itself.

**How a value is compared.** Integers as decimal text. Floats as their **bit patterns**, because a
decimal float literal has to survive a printer on both sides and the things that must not change are
the sign of a zero and a NaN payload. A call whose original traps, or returns a NaN, is *skipped* and
counted in its own column: a trap has no value to compare, and a NaN produced by arithmetic may
legitimately differ in payload between V8 and a MoonBit runtime. 164 of 548 calls are in that
bucket, almost all of them `arith`'s `$i32_bin`, which runs every binary operator in sequence and
therefore divides by zero for any argument pair containing one.

**Two fixtures are excluded, and the report says so.** `imports` and `moonbit_fib` call into a host
(`env.fd_write` and friends); neither side has one, so the original cannot even be instantiated.
Their generated packages still compile, which the previous step proves, and their imports are
trapping stubs.

**One fixture gets a smaller argument pool** (`fib`). Recursive Fibonacci does not return for
`fib(255)`, and waiting for it would say nothing about the decompiler. `--small` cuts the pool to
five values, and the timeout in the harness reports a call the original never finished rather than
silently dropping it.

**What it found.** The first full run failed on `memory`, in `Memory::grow`: `pages + delta` was
computed in 32 bits, so `memory.grow(2147483647)` wrapped negative, passed the limit check, and died
inside an allocation the size of a small country. The original answers `-1`. That is a bug in the
runtime library, not in the code generator, and no amount of `moon check` would have found it —
`runtime/runtime_wbtest.mbt` now pins it. The same 32-bit assumption sat in `Memory::check`, which
added the access width to the address — a load at `0x7FFFFFFE` would have wrapped into range instead
of trapping; that one was found by reading the neighbouring function while fixing the first, and is
fixed the same way, in 64 bits.

## Metrics

Every number below is printed by a command in `script/` or by the one-liner in the last column.
`bash script/check.sh` re-checks all of them and exits non-zero if any drifts.

| Metric | Value | Reproduce |
|---|---|---|
| MoonBit source lines (project code) | **14,383** | `find core runtime cmd -name '*.mbt' \| xargs wc -l` |
| White-box tests | **152**, 152 pass on `wasm-gc` and `js` | `moon test --target wasm-gc` |
| Corpus modules | **41** (10 good + 31 real compiler output) | `ls corpus/good/*.wasm corpus/extended/*.wasm \| wc -l` |
| Malformed fixtures rejected with code + byte offset | **19 / 19** | `bash script/check.sh` → "19 malformed fixtures rejected" |
| Decoder vs wabt (independent implementation) | **4,485 matched, 0 mismatched**, 62 SIMD not attempted | `node corpus/tools/verify_decode.js` |
| Real 20 KB artifact | 79 functions: **72 structured**, 6 refused, 1 skipped, 0 malformed | `moon run cmd/main -- disasm corpus/good/moonbit_fib.wasm --struct-stats` |
| Structuring coverage | **395 / 395** reachable blocks, `nodes 1115`, `max depth 7` | same command |
| Generated packages compiling cleanly | **41 / 41**, zero errors **and zero warnings** | `bash script/check.sh`, `bash script/extended.sh` |
| Function definitions on the real artifact | **79** (72 bodies + 7 trapping stubs) | `grep -c '^pub fn f' /tmp/moonlift_gen/moonbit_fib/funcs.mbt` |
| Behavioural smoke tests | **11** (control 6, fib 3, nested 2) | `bash script/check.sh` → smoke step |
| Differential calls vs the original in Node | **384 compared, 384 matched, 0 failed**, 164 skipped (trap/NaN) | `bash script/verify.sh` |
| Real-compiler modules end-to-end | **31 / 31**, 1,538 function bodies emitted | `bash script/extended.sh` |
| Cross-target identity (`wasm-gc` / `js` / `wasm`) | `info`, `--ops`, `--cfg`, `--stack`, `--struct`, `calls.tsv` all byte-identical | `bash script/check.sh` → cross-target steps |
| Gate | `ALL GREEN`, ~3.5 min, no network, no C toolchain | `bash script/check.sh` |

Two deliberately excluded rows: `imports.wasm` and `moonbit_fib.wasm` need a host, so Node cannot
instantiate the original; and `native` is unavailable on this machine (no MSVC). Both are written
down in `BOUNDARY.md` §4 rather than quietly omitted.

## Repository layout

| Path | Role | Stage |
|---|---|---|
| `core/` | byte reader, LEB128, UTF-8, diagnostics, module IR, section decoder, report | done |
| `core/instr.mbt` | instruction IR: 29 shapes covering the 172 MVP opcodes | done |
| `core/decode_instr.mbt` | instruction decoder with structure and index validation | done |
| `core/disasm.mbt` | `.wat`-style listing, machine listing, decode statistics | done |
| `core/cfg.mbt` | basic blocks, dominators, natural loops, reducibility | done |
| `core/stack.mbt` | typed stack simulation, expression recovery, reordering hazards | done |
| `core/struct.mbt` | construct-tree walker: blocks/loops/ifs, multi-level escapes, `match` for `br_table` | done |
| `core/emit.mbt` | MoonBit code generation: names, expression printing, dead-tail pruning | done |
| `core/verify.mbt` | the call plan: which exports to compare, with which arguments | done |
| `runtime/` | support library copied into every generated package | done |
| `cmd/main/` | CLI shell (no logic) | S0, S2 |
| `corpus/good/` | 10 pinned fixtures: 9 hand-written `.wat` + one 20 KB real compiler artifact, with SHA-256 | done |
| `corpus/extended/` | 31 real-compiler modules, sources in `corpus/tools/sources/`, SHA-256 in `SHA256SUMS` | done |
| `corpus/bad/`, `corpus/badcode/` | 19 malformed samples, each named after the error it must produce | done |
| `corpus/tools/` | `.wat` assembler, wabt cross-check, Node oracle, corpus generator | done |
| `script/check.sh` | one-command gate (format, 3 targets, tests, corpus, decompile, verify, extended) | done |
| `script/verify.sh` | differential harness: MoonBit plan → Node answers → generated tests | done |
| `script/extended.sh` | 31 real modules: checksum → decode → decompile → zero-warning `moon check` | done |
| `docs/` | [DESIGN](docs/DESIGN.md), [ACCEPTANCE](docs/ACCEPTANCE.md), [AI_USAGE](docs/AI_USAGE.md), [申报书](docs/申报书.md) | done |

## Roadmap

| Stage | Deliverable | Status |
|---|---|---|
| S0 | scaffold, diagnostics, CLI skeleton, CI script | done |
| S1 | byte reader + LEB128 with offset-anchored errors | done |
| S2 | section decoding, `moonlift info` | done |
| S3 | 172 MVP instructions, `.wat`-style dump, wabt cross-check | done |
| S4 | CFG + dominators + natural loops + reducibility | done |
| S5 | typed stack simulation, type checking, reordering hazards | done |
| S6 | structuring: construct-tree walker, one-shot blocks, multi-level escapes | done |
| S7 | MoonBit emitter, first end-to-end decompile | done |
| S8 | differential verification harness | done: 384/384 |
| S9 | corpus expansion: 41 modules, 31 from the real compiler | done |
| S10 | `BOUNDARY.md`: support matrix, 13 semantic deviations, 19 known gaps | done |
| S11 | README, DESIGN, ACCEPTANCE table, metrics, one-page submission form | done |

## Verify

```bash
bash script/check.sh
```

Runs format check, `moon check` on `wasm-gc`/`js`/`wasm`, 152 unit tests on two targets, CLI smoke
tests, all 10 good fixtures through the real binary, the code-layer malformed samples (each must
report the error code written in its filename — including the one that decodes but does not
type-check), a cross-backend comparison requiring `info`, `disasm --ops`, `disasm --cfg`,
`disasm --stack` and `disasm --struct` output to be byte-identical on all three targets, the
control-flow graph on every fixture (no body may come out irreducible, and the `br_table` dispatch is
pinned to its exact successor line), the pinned recovery counts of the real artifact, both reordering
hazards on the fixture that isolates them, the structurer on every fixture (no raw branch statement
may survive, and the pinned `structured` / `nodes` / `blocks emitted` / `guards` / `max depth` counts
may not drift), the decoder against wabt, **every fixture decompiled and the generated package
compiled with `moon check` at zero warnings**, **the generated packages for `control`, `fib` and
`nested` executed against the values the originals produce under Node**, the full differential run
(**384 calls compared, 384 matched**), and **31 real-compiler modules through checksum → decode →
decompile → zero-warning `moon check`**.

For a short end-to-end demo that prints the metric table instead of the full gate:

```bash
bash script/demo.sh
```

The last two checks are the ones that matter. A code generator that emits something a compiler rejects
is obviously broken, but one that emits code that compiles and computes the wrong answer looks
exactly like a working decompiler until someone runs it.

## License

Apache-2.0. Third-party attribution and corpus provenance: see [NOTICE](NOTICE) and
[corpus/PROVENANCE.md](corpus/PROVENANCE.md).
