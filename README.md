# moonlift

**Decompile WebAssembly (MVP subset) binaries into compilable, readable MoonBit source.**

`moonlift` reads a `.wasm` file, recovers functions, control flow and expressions, and emits a
MoonBit package that `moon build` accepts and that behaves like the original module when run on
`wasm`, `wasm-gc` and `js`. Correctness is not asserted — it is measured: every decompiled module
is differentially tested against a reference engine (Node's `WebAssembly`) on random inputs.

> **Status: S6 (control-flow structuring).** The byte reader, the section decoder, the MVP
> instruction decoder, the type checker and the structurer are implemented: 131 white-box tests, 9
> fixtures decoded, 19 malformed fixtures rejected with a stable error code and a byte offset.
> `moonlift info` describes a module; `moonlift disasm` decodes every function body to `.wat`;
> `disasm --cfg` prints basic blocks, dominators, natural loops and a reducibility verdict;
> `disasm --stack` prints the recovered per-block expressions **and type-checks them**;
> `disasm --struct` lowers the block graph back to nested `while` / `if` / `match` with no `br` left
> in it. On the real 20 KB artifact, 72 of 79 bodies are structured — **395 of 395 reachable blocks
> emitted exactly once** (the structurer's own invariant, asserted as a test) — 6 are refused by
> name and 1 is skipped, with **nothing rejected as malformed**. The decoder is cross-checked
> against wabt, an independent implementation: **4,423 of 4,423 reachable instructions agree, 0
> mismatches**, with 62 instructions in one SIMD helper deliberately not attempted.
> `decompile` and `verify` are not implemented yet — see [Roadmap](#roadmap) and
> [BOUNDARY.md](BOUNDARY.md).

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
  - 2 signature(s) return more than one value (multi-value proposal); code generation must fall back to a boxed stack for those functions
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
nodes           1012
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
| `emit/` | MoonBit code generation + prelude | S7 |
| `cmd/main/` | CLI shell (no logic) | S0, S2 |
| `corpus/` | fixtures, malformed samples, provenance, regeneration and wabt cross-check | done |
| `script/` | one-command check / demo scripts | S0 |

## Roadmap

| Stage | Deliverable |
|---|---|
| S0 | scaffold, diagnostics, CLI skeleton, CI script |
| S1 | byte reader + LEB128 with offset-anchored errors |
| S2 | section decoding, `moonlift info` |
| S3 | 172 MVP instructions, `.wat`-style dump, wabt cross-check |
| S4 | CFG + dominators + natural loops + reducibility |
| S5 | typed stack simulation, type checking, reordering hazards |
| S6 | structuring: construct-tree walker, one-shot blocks, multi-level escapes ← **you are here** |
| S7 | MoonBit emitter, first end-to-end decompile |
| S8 | differential verification harness |
| S9 | corpus expansion: more real compiler output |
| S10 | `BOUNDARY.md`: support matrix, 8+ semantic deviations, known gaps |
| S11 | docs, metrics table, submission material |

## Verify

```bash
bash script/check.sh
```

Runs format check, `moon check` on `wasm-gc`/`js`/`wasm`, 131 unit tests on two targets, CLI smoke
tests, every corpus fixture through the real binary, the code-layer malformed samples (each must
report the error code written in its filename — including the one that decodes but does not
type-check), a cross-backend comparison requiring `info`, `disasm --ops`, `disasm --cfg`,
`disasm --stack` and `disasm --struct` output to be byte-identical on all three targets, the
control-flow graph on every fixture (no body may come out irreducible, and the `br_table` dispatch is
pinned to its exact successor line), the pinned recovery counts of the real artifact, both reordering
hazards on the fixture that isolates them, the structurer on every fixture (no raw branch statement
may survive, and the pinned `structured` / `nodes` / `blocks emitted` / `guards` / `max depth` counts
may not drift), and the decoder against wabt.

## License

Apache-2.0. Third-party attribution and corpus provenance: see [NOTICE](NOTICE) and
[corpus/PROVENANCE.md](corpus/PROVENANCE.md).
