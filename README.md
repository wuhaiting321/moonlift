# moonlift

**Decompile WebAssembly (MVP subset) binaries into compilable, readable MoonBit source.**

`moonlift` reads a `.wasm` file, recovers functions, control flow and expressions, and emits a
MoonBit package that `moon build` accepts and that behaves like the original module when run on
`wasm`, `wasm-gc` and `js`. Correctness is not asserted — it is measured: every decompiled module
is differentially tested against a reference engine (Node's `WebAssembly`) on random inputs.

> **Status: S0 (scaffold).** The CLI skeleton, the error taxonomy and the test harness layout exist.
> Decoding starts at S1. Nothing in this repository claims to decompile anything yet — see
> [Roadmap](#roadmap) and [BOUNDARY.md](BOUNDARY.md).

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

Exit codes: `0` success · `2` usage error · `3` input rejected (`E0xx`/`E1xx`) · `1` internal error.
MoonBit has no portable `exit()`, so the code is echoed as `moonlift: exit N`; scripts grep for it.

## Repository layout

| Path | Role | Stage |
|---|---|---|
| `core/` | byte reader, LEB128, diagnostics, error taxonomy | S0–S1 |
| `model/` | module IR + the 172 MVP instructions | S2–S3 |
| `decode/` | section and instruction decoding | S2–S3 |
| `analyze/` | CFG, dominators, reducibility, typed stack simulation | S4–S5 |
| `reloop/` | structuring of irreducible control flow | S6 |
| `emit/` | MoonBit code generation + prelude | S7 |
| `fixture/` | programmatic `.wasm` builders used by tests | S9 |
| `cmd/main/` | CLI shell (no logic) | S0 |
| `corpus/` | test modules with recorded provenance and SHA-256 | S9 |
| `script/` | one-command check / demo scripts | S0 |

## Roadmap

| Stage | Deliverable |
|---|---|
| S0 | scaffold, diagnostics, CLI skeleton, CI script ← **you are here** |
| S1 | byte reader + LEB128 with offset-anchored errors |
| S2 | section decoding, `moonlift info` |
| S3 | 172 MVP instructions, `.wat`-style dump for self-check |
| S4 | CFG + reducibility analysis |
| S5 | typed stack simulation (expression recovery + fallback) |
| S6 | Relooper for irreducible flow |
| S7 | MoonBit emitter, first end-to-end decompile |
| S8 | differential verification harness |
| S9 | corpus: MoonBit MVP outputs + hand-written `.wat` + optional public artifacts |
| S10 | `BOUNDARY.md`: support matrix, 8+ semantic deviations, known gaps |
| S11 | docs, metrics table, submission material |

## Verify the scaffold

```bash
bash script/check.sh          # moon check + moon test + CLI smoke on 3 targets
```

## License

Apache-2.0. Third-party attribution: see [NOTICE](NOTICE).
