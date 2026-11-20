# moonlift

**Decompile WebAssembly (MVP subset) binaries into compilable, readable MoonBit source.**

`moonlift` reads a `.wasm` file, recovers functions, control flow and expressions, and emits a
MoonBit package that `moon build` accepts and that behaves like the original module when run on
`wasm`, `wasm-gc` and `js`. Correctness is not asserted — it is measured: every decompiled module
is differentially tested against a reference engine (Node's `WebAssembly`) on random inputs.

> **Status: S4 (control-flow analysis).** The byte reader, the section decoder, the MVP instruction
> decoder and the control-flow graph are implemented: 95 white-box tests, 8 fixtures decoded,
> 18 malformed fixtures rejected with a stable error code and a byte offset. `moonlift info`
> describes a module; `moonlift disasm` decodes every function body to `.wat`; `disasm --cfg` prints
> basic blocks, dominators, natural loops and a reducibility verdict. The decoder is cross-checked
> against wabt, an independent implementation: **4,386 of 4,386 reachable instructions agree, 0
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
moon run cmd/main --target wasm-gc -- disasm path/to/module.wasm [--ops|--stats|--cfg]
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
instruction per line for the wabt comparison, and `--cfg` prints the control-flow graph:

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
```

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
| `analyze/` | typed stack simulation | S5 |
| `reloop/` | structuring of irreducible control flow | S6 |
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
| S4 | CFG + dominators + natural loops + reducibility ← **you are here** |
| S5 | typed stack simulation (expression recovery + fallback) |
| S6 | Relooper for irreducible flow |
| S7 | MoonBit emitter, first end-to-end decompile |
| S8 | differential verification harness |
| S9 | corpus expansion: more real compiler output |
| S10 | `BOUNDARY.md`: support matrix, 8+ semantic deviations, known gaps |
| S11 | docs, metrics table, submission material |

## Verify

```bash
bash script/check.sh
```

Runs format check, `moon check` on `wasm-gc`/`js`/`wasm`, 95 unit tests on two targets, CLI smoke
tests, every corpus fixture through the real binary, the code-layer malformed samples (each must
report the error code written in its filename), a cross-backend comparison requiring `info`,
`disasm --ops` and `disasm --cfg` output to be byte-identical on all three targets, the control-flow
graph on every fixture (no body may come out irreducible, and the `br_table` dispatch is pinned to
its exact successor line), and the decoder against wabt.

## License

Apache-2.0. Third-party attribution and corpus provenance: see [NOTICE](NOTICE) and
[corpus/PROVENANCE.md](corpus/PROVENANCE.md).
