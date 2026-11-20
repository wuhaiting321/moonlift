# moonlift

**Decompile WebAssembly (MVP subset) binaries into compilable, readable MoonBit source.**

`moonlift` reads a `.wasm` file, recovers functions, control flow and expressions, and emits a
MoonBit package that `moon build` accepts and that behaves like the original module when run on
`wasm`, `wasm-gc` and `js`. Correctness is not asserted — it is measured: every decompiled module
is differentially tested against a reference engine (Node's `WebAssembly`) on random inputs.

> **Status: S2 (container layer).** The byte reader, the LEB128/fixed-width layer, the UTF-8
> validator and the full section decoder are implemented: 58 white-box tests, 8 fixtures decoded,
> 11 malformed fixtures rejected with a stable error code and a byte offset. `moonlift info` works
> on real compiler output, including MoonBit's own 20 KB wasm binary.
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
moon run cmd/main --target wasm-gc -- info  path/to/module.wasm
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

Exit codes: `0` success · `2` usage error · `3` input rejected (`E0xx`/`E1xx`) · `4` input
unreadable. MoonBit has no portable `exit()`, so the code is echoed as `moonlift: exit N`; scripts
grep for it.

## Repository layout

| Path | Role | Stage |
|---|---|---|
| `core/` | byte reader, LEB128, UTF-8, diagnostics, section decoder, module IR, report | done |
| `model/` | instruction IR (172 MVP opcodes) | S3 |
| `decode/` | instruction decoding | S3 |
| `analyze/` | CFG, dominators, reducibility, typed stack simulation | S4–S5 |
| `reloop/` | structuring of irreducible control flow | S6 |
| `emit/` | MoonBit code generation + prelude | S7 |
| `cmd/main/` | CLI shell (no logic) | S0, S2 |
| `corpus/` | fixtures + provenance + regeneration tooling | S2 |
| `script/` | one-command check / demo scripts | S0 |

## Roadmap

| Stage | Deliverable |
|---|---|
| S0 | scaffold, diagnostics, CLI skeleton, CI script |
| S1 | byte reader + LEB128 with offset-anchored errors |
| S2 | section decoding, `moonlift info` ← **you are here** |
| S3 | 172 MVP instructions, `.wat`-style dump for self-check |
| S4 | CFG + reducibility analysis |
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

Runs format check, `moon check` on `wasm-gc`/`js`/`wasm`, 58 unit tests on two targets, CLI smoke
tests, every corpus fixture through the real binary, and a cross-backend comparison that requires
`info` output to be byte-identical on all three targets.

## License

Apache-2.0. Third-party attribution and corpus provenance: see [NOTICE](NOTICE) and
[corpus/PROVENANCE.md](corpus/PROVENANCE.md).
