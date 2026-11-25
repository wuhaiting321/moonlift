# Corpus provenance

Every `.wasm` under `corpus/` is listed here. A file without an entry here is not
allowed to stay in the repository — that is the rule from `NOTICE`.

Every fixture is either hand-written for this project or produced by MoonBit's
own compiler, so nothing here carries a third-party licence. Binaries are
committed: `bash script/check.sh` never needs the network or a toolchain.

## `corpus/good/` — inputs that must decode

| File | Source | Size | Why it exists |
|---|---|---|---|
| `arith.wasm` | `src/arith.wat` (hand-written) | 639 B | Complete MVP numeric opcode range, signed and unsigned variants |
| `control.wasm` | `src/control.wat` (hand-written) | 256 B | `block`/`loop`/`if`/`br`/`br_if`/`br_table`/`return`/`unreachable`/`select` |
| `fib.wasm` | `src/fib.wat` (hand-written) | 219 B | Small complete program: recursion, loop, memory traffic; carries a `name` section |
| `globals.wasm` | `src/globals.wat` (hand-written) | 180 B | Mutable and immutable globals, one initialiser of each value type, plus `start` |
| `imports.wasm` | `src/imports.wat` (hand-written) | 221 B | Function imports shift the whole index space; export names that need sanitising |
| `memory.wasm` | `src/memory.wat` (hand-written) | 319 B | Every load/store width, alignment hints, non-UTF-8 data segment |
| `nested.wasm` | `src/nested.wat` (hand-written) | 171 B | A `br_table` inside a `loop` inside a `block`, with a value carried across the dispatch — the case where the branch's payload, not the block's exit stack, has to be written at the edge |
| `stack.wasm` | `src/stack.wat` (hand-written) | 210 B | The three reordering hazards (local / memory / global) and the three shapes that must *not* spill (`local.tee`, a call consumed by `drop`, a value crossing a block boundary) |
| `table.wasm` | `src/table.wat` (hand-written) | 246 B | `call_indirect` with a type immediate and an element segment |
| `indirect.wasm` | `src/indirect.wat` (hand-written) | 604 B | Three signatures in one table, empty slots, a virtual-table layout read from memory, dispatch inside a loop |
| `imported.wasm` | `src/imported.wat` (hand-written) | 273 B | All four import kinds at once: an imported memory, table and two globals, a constant data segment, a segment placed at `global.get`, and a call into an imported function |
| `alias.wasm` | `src/alias.wat` (hand-written) | 145 B | One mutable global imported twice under the same `(module, name)`: writing `$a` must be visible through `$b`. The case that decides whether imports are bound or copied |
| `shared_a.wasm` | `src/shared_a.wat` (hand-written) | 91 B | Half of a pair that imports the *same* memory: owns `memory.grow` and a data segment. Merged with `shared_b` into one package by `script/merge.sh`, it is what makes "A grows, B sees the size" testable |
| `shared_b.wasm` | `src/shared_b.wat` (hand-written) | 74 B | The observing half: `memory.size` and a byte load, nothing else. Alone it proves nothing; next to `shared_a` in one package it proves the memory is shared |
| `moonbit_fib.wasm` | MoonBit compiler `0.1.20261020`, `moon build --target wasm` | 20,312 B | Real compiler output: 79 functions, 1 import, `datacount`, name section, 736 bytes of static data |

SHA-256 for every one of these fourteen hand-written binaries and for `moonbit_fib.wasm` is in
`corpus/good/SHA256SUMS`.

Command for the hand-written fixtures:

```sh
cd corpus/tools && npm install && node build.js
```

`wabt` (npm, pure JS/WASM) is a build-time convenience only. It is not a
dependency of `moonlift`, and the binaries are committed, so the check script
works offline.

`moonbit_fib.wasm` was built from:

```moonbit
fn fib(n : Int) -> Int {
  if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}

fn main {
  println("fib(20)=\{fib(20)}")
}
```

Its section layout, as reported by `moonlift info`:

```
sections  13
     1  type               8        89
     2  import            99        35
     3  function         136        80
     4  table            218         5
     5  memory           225         3
     6  global           230        18
     7  export           250        20
     9  element          272        18
    12  datacount        292         1
    10  code             295      7657
    11  data            7955       745
     0  custom          8703     11535
     0  custom         20241        69
```

Two facts from this file drive design decisions elsewhere:

1. **`datacount` (id 12) sits between `element` (9) and `code` (10)**, not after
   `data`. Section order is therefore a rank, not the numeric id — see
   `section_rank` in `core/section.mbt`.
2. **Two signatures return multiple values**, and one function declares a `v128`
   local (its memcpy helper). Both are parsed and reported by `info`, and both
   are refused per function at code-generation time rather than per module.

## `corpus/extended/` — 31 modules from the real compiler

These are the breadth layer. Each one is a complete, self-contained MoonBit
program in `corpus/tools/sources/<name>.mbt`, compiled with the same toolchain as
`moonbit_fib.wasm`:

```sh
moon 0.1.20261020
moon build --target wasm
```

`python corpus/tools/gen_corpus.py` reproduces the whole set: for each source it
creates a throwaway module, builds it, and copies
`_build/wasm/debug/build/main/main.wasm` to `corpus/extended/<name>.wasm`. Every
program prints its result, so the compiler cannot discard the computation. The
sources cover integer/float/i64 arithmetic, conversions, shifts, comparisons,
loops (while / for / nested / break+continue), recursion, pattern matching on
integers, options, results and enums, structs, arrays, strings, tuples, closures,
generics, traits, dispatch tables and a mutable global.

| | |
|---|---|
| Modules | 31, listed individually in `corpus/extended/SHA256SUMS` |
| Total corpus | 41 `.wasm` modules (`corpus/good/` 10 + `corpus/extended/` 31) |
| Checksums | `corpus/extended/SHA256SUMS`, verified by `script/extended.sh` |
| Gate | `bash script/extended.sh`: checksum → decode → decompile → `moon check` with zero warnings, for all 31 |

The extended modules are deliberately **not** in `corpus/good/`. The good
fixtures are pinned to exact instruction, node and block counts, which is the
right way to catch a change in moonlift. Compiler output changes with every
toolchain release; pinning its internals would make the gate fail on an upgrade
rather than on a bug. What is pinned here is the shape of the claim instead:
every real module decodes, and every generated package compiles cleanly. These
modules all import a host for `println`, so they are not run against Node — the
differential harness (`script/verify.sh`) covers the self-contained fixtures in
`corpus/good/`.

Building this layer found three bugs that the hand-written fixtures missed,
all of them in code that compiled but was wrong or uncompilable on real output:
a `63.to_int64()` parse error (a bare integer literal before a method call),
an assigned-but-never-read local whose declaration was underscored (`_l9`)
while the assignment still said `l9`,
and a function with two results whose second value was silently dropped. All
three are fixed and covered by `script/extended.sh` or a unit test.

## `corpus/badcode/` — valid container, broken instruction stream

Generated by the same script. These exist to prove the layers are independent:
`moonlift info` accepts every one of them (the container is well-formed) and the
body is rejected with the code written in its **filename**, which `script/check.sh`
reads, so the expectation cannot drift away from the sample. That check runs
`disasm --stack`, the strongest analyser, because since S5 a body can also fail
*type checking* rather than decoding — and one sample does.

| File | Code | Why it is broken |
|---|---|---|
| `unknown_opcode_e006.wasm` | `E006` | `0x06` is not in the MVP set |
| `bad_label_e008.wasm` | `E008` | `br 1` at the top level: only label 0 is in scope |
| `bad_local_index_e008.wasm` | `E008` | `local.get 5` in a function with no locals |
| `else_without_if_e006.wasm` | `E006` | `else` with no enclosing `if` |
| `over_aligned_e007.wasm` | `E007` | `i32.load` with an alignment hint of 2^3 |
| `trailing_after_end_e005.wasm` | `E005` | the body ends a byte early |
| `truncated_instr_e001.wasm` | `E001` | `i32.const` with no operand left |
| `type_mismatch_e011.wasm` | `E011` | every instruction is valid and the body is well structured, but it leaves an `f32` where the signature promises an `i32`; plain `disasm` still lists it, which is why the type checker is a separate pass |

## `corpus/bad/` — inputs that must be rejected

Generated by `python corpus/tools/make_bad.py`. Each file breaks exactly one rule,
so the reported error code identifies one specific check:

| File | Expected | What is wrong |
|---|---|---|
| `bad_magic.wasm` | `E002` | not a wasm binary |
| `bad_version.wasm` | `E003` | binary version 2 |
| `bad_truncated.wasm` | `E001` | section declares 10 bytes, file has 3 |
| `bad_order.wasm` | `E005` | export section before type section |
| `bad_leb.wasm` | `E004` | section size in an overflowing LEB128 |
| `bad_ref_type.wasm` | `E101` | `externref` parameter |
| `bad_multimem.wasm` | `E106` | two memories |
| `bad_data_flag.wasm` | `E109` | passive data segment |
| `bad_body_end.wasm` | `E005` | function body not terminated by `end` |
| `bad_import_kind.wasm` | `E005` | import kind 4 — 1.0 defines only 0–3, and a memory import is legal since the 11-23 revision |
| `bad_const_expr.wasm` | `E006` | `local.get` inside a constant expression |

## Known non-fixture: MoonBit output that uses `@fs`

A MoonBit program that uses `moonbitlang/x/fs` on the wasm target imports
`__moonbit_fs_unstable` functions taking `externref`. Those modules are rejected
with `E101` by design: a reference parameter has no MoonBit representation, so no
correct body could be generated. `moonbit_fib.wasm` is the same kind of program
without the `@fs` dependency, which is why it decodes.
