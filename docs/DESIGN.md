# DESIGN — architecture and the decisions behind it

> This document explains *why* moonlift is built the way it is. For what it accepts and refuses,
> see [BOUNDARY.md](../BOUNDARY.md); for the commands that verify every claim, see
> [ACCEPTANCE.md](ACCEPTANCE.md).

## 1. The pipeline

```
.wasm bytes
   │
   ├─ core/reader.mbt        LEB128 u32/u64/s32/s64, f32/f64 bits, absolute offsets
   ├─ core/section.mbt       12 sections → Module IR (order is a rank, not the id)
   ├─ core/decode_instr.mbt  172 MVP opcodes → 29 instruction shapes
   │        └─ core/disasm.mbt   .wat listing / --ops / --stats / --cfg / --stack
   ├─ core/cfg.mbt           basic blocks, dominators, natural loops, reducibility
   ├─ core/stack.mbt         typed operand stack → expressions, spill hazards, type checks
   ├─ core/struct.mbt        construct tree → nested Node tree (while / if / match)
   ├─ core/emit.mbt          Node tree → MoonBit text (six files)
   │        └─ runtime/runtime.mbt   support library, copied into every package
   └─ core/verify.mbt        a *plan* of calls to compare, written as calls.tsv
              │
              ├─ corpus/tools/oracle.js   Node runs the ORIGINAL module  (independent answer)
              ├─ script/verify.sh         writes inspect(...) tests into the generated package
              └─ moon test                runs the GENERATED code and compares values
```

The split at the bottom is the most important architectural decision in the project and is
explained in §4.

Each layer is a separate file with its own white-box tests. `script/check.sh` compares the *text
output* of each layer across `wasm-gc`, `js` and `wasm`, so a backend-specific difference in
integer arithmetic, float bit patterns, UTF-8 decoding or `argv` layout shows up as a failing diff
rather than a subtle wrong answer.

## 2. What each layer adds

| Layer | Input → output | The invariant it asserts |
|---|---|---|
| reader | bytes → typed values | every failure carries the absolute byte offset of the field, not of its section |
| section | bytes → `Module` | section order is a **rank** (`datacount` sits between `element` and `code`), unknown ids are `E005` |
| decode_instr | code bytes → `Instr` | a wrong *length* stops decoding (`0xFD` SIMD) and marks the body partial; a wrong *value* is a diagnostic. Guessing an operand length would desynchronise the rest of the body and produce plausible nonsense |
| cfg | `Instr` → blocks/edges | `end`/`else` close a range but are never blocks; `if` is a real instruction with two successors; unreachable blocks are kept and marked |
| stack | blocks → typed `Expr` | each block is simulated once in block-index order; entry shape = the first resolved predecessor's exit shape, and any disagreement is `E011`, not a merge |
| struct | construct tree → `Node` | every reachable block is emitted **exactly once** (`visited == reachable`), and no raw `br`/`br_if`/`br_table`/bare `if (...)` survives |
| emit | `Node` → MoonBit text | every declaration analysis walks the tree through the **same** pruning the printer uses, so no declaration refers to dropped code and no dropped statement introduces a name |
| runtime | — | wasm semantics measured to disagree with MoonBit's are named helpers; operators are used only where measured to agree |

## 3. Key decisions, with the alternatives that were rejected

### 3.1 Wide parse, narrow generate

`info` parses `v128` types, multi-result signatures, `datacount`, name sections and huge local
counts. `decompile` refuses those functions individually with a diagnostic and emits a trapping
stub. **Rejected:** refusing at the container layer (hides which function is the problem) and
silently approximating (produces a compiling function that computes the wrong value). The refusal
is visible in `--struct-stats` with a function name and a byte offset.

### 3.2 Structuring walks wasm's own construct tree, not a relooper

Structured wasm can only branch to enclosing labels, so every CFG it can express is reducible —
measured 78/78 complete bodies on the real 20 KB artifact. Re-deriving nesting from the flat graph
throws away information the binary already carries. **Rejected:** an unconditional Relooper (turns
even a plain `if` into a state machine, unreadable) and a "fall back to a graph dispatcher when
the tree misses" path (unreachable in this subset — the decoder's label-depth check rejects it —
so it would be dead code no test can exercise). `E108` is kept in the taxonomy and the
Hecht–Ullman test is kept in `core/cfg.mbt`, but §3 D3 of BOUNDARY states plainly that no code
path returns it.

### 3.3 MoonBit has no labelled break, so `block` becomes a one-shot loop

`'outer : while true` is a lexing error, and `break` closes only the innermost loop. A wasm
`block` therefore becomes `while true { ...; break }`, and a branch that escapes several constructs
is carried by one `Int` variable `brk` that each guard on the way out clears, forwards, or turns
into a `continue`. **Rejected:** a per-function state machine; and, for plain `br 0` to the
innermost block, any use of `brk` at all — there is a test asserting `brk = 1` is *absent* from
that output.

### 3.4 Values cross an edge at the predecessor, not at the use site

An edge value is written into a per-block temp by the *predecessor*, the last point where the
expression that produced it is still correct. The structurer takes the payload from the branch
statement (`SBr` / `SBrIf` / `SBrTable`), not from a type marker on the block's exit stack; when
the statement carries fewer values than the destination needs (a branch to a `loop`, whose
parameters the MVP subset cannot express), the longer exit stack wins. **Rejected:** reading
`EParam(0)` placeholders off the exit stack — that was the `t2 is unbound` bug found by
`nested.wasm`; and using only the statement — that lost the back-edge values of a real compiler
loop. Both are documented as BOUNDARY D12.

### 3.5 The simulator writes down reordering hazards before they happen

A pending `local.get i` across `local.set i`, a pending load across a store/call/`memory.grow`,
and a pending `global.get i` across `global.set i`/any call are each materialised into a temporary
*before* the invalidating instruction. Calls always materialise their result immediately because
they must execute where they appear. The `forced` count (110 on the real artifact) is kept separate
from `hazard` (1), because only the latter are decompiler mistakes waiting to happen.

### 3.6 Operators where measured to agree, helpers where measured not to

MoonBit's `Int` wraps like wasm `i32`, so `+`, `-`, `*` and bit operators are emitted directly.
Division, remainder, shifts on the boundary, unsigned comparisons, float `min`/`max`/`abs`/
`copysign`/`nearest`, rotations and `trunc` are named functions in `runtime/runtime.mbt`, because
their wasm semantics (`MIN / -1` traps, `min(0, -0) = -0`, NaN payload propagation, ties-to-even)
were measured not to be the host language's. Float constants are emitted as **bit patterns** via
`reinterpret`, never as decimal literals: a printer/parser round trip can lose a NaN payload or
the sign of a zero.

### 3.7 A refused function still gets a real signature

A body that cannot be translated becomes `trap("f47 was not decompiled: ...")` with the original
signature. **Rejected:** omitting it — the first version of the emitter produced 155 `f25 is
unbound` errors on the real artifact, because callers still reference it. The generated package
therefore always compiles, and the failure is loud and local at the call site. Pinned: 79
definitions, 7 stubs.

### 3.8 Warnings are errors for generated code

MoonBit's parameters are immutable, `let mut` that is never stored is warning 0015, and unused
names are warning 0002. The emitter therefore splits locals into read/write × parameter/local,
uses `_p0` / `_l3` / `_t2` for deliberately unused names, declares `mut` only where something is
stored, and drops the unreachable tail the structurer still reports. All of that exists to satisfy
one gate: `moon check` on the generated package at **zero warnings**, not merely zero errors.

### 3.9 `start` becomes an explicit `moonlift_init()`

Wasm runs the start function at instantiation; a MoonBit package has no instantiation. Every
generated package therefore exposes `pub fn moonlift_init()`, and the harness calls it. Without
it, `globals.wasm`'s `f4()` returns 0 where the original returns 1 — a bug that compiles perfectly.

### 3.10 Floats and traps are compared as observations, not as values

Integers compare as decimal text, floats as **signed bit patterns**. A call whose original traps,
or returns a NaN, is *skipped* and counted in its own column — a skipped call is not a pass. This
is why the report prints 522 compared / 522 matched / 244 skipped rather than a single percentage.

### 3.11 Sharing an instance means sharing a package

Two modules that import one `Memory` must see each other's `grow`. Generated packages each copy
`runtime.mbt`, so `pkg_a.Memory` and `pkg_b.Memory` are different types and no host can hand one value
to both — the failure is a wrong answer (each module grows a private memory), not a compile error.

The fix is not a new instance type but a different packaging: `moonlift decompile a.wasm b.wasm -o pkg`
emits both modules into one package. One `runtime.mbt` means one `Memory`; one namespace forces a
`m0_` / `m1_` prefix on every top-level name (and `M0_` / `M1_` on the one type, because MoonBit type
names start upper-case); one `moonlift_bind()` per module keeps the records separate, so the host
decides which instances are shared; one `moonlift_init_all()` instantiates them in the order given.
The rejected alternative was a shared `moonlift_runtime` package, which would make every generated
package non-zero-dependency — and "the output depends on nothing" is a property this project tests.

### 3.12 A shared table needs one function index space, not just one type

A table is an externval too, so two modules can import one table and a slot filled by A's element
segment must be callable from B — and must reach *A's* function. Sharing the type is not enough: a
slot holds a function index, and every module numbers its functions from `0`. Emitting per-module
indices gives the worst possible failure: B calls slot 0, which now means B's own `f0` — it compiles
and returns a plausible wrong number.

So a merged package has one function index space: module `i`'s base is the sum of the previous
modules' function counts, element segments write `base + f`, and every `call_indirect` dispatcher
carries arms for the whole package (`0 => m0_f0()`, `2 => m1_f0()`), not only for its own module.
A single-module decompile has `base = 0` and no siblings, which is why its output is unchanged.

The table is also a type (`Table` in `runtime.mbt`), not an `Array[Int]`, for the same reason `Memory`
is: two separate packages must not be able to pass one table to each other by accident, because the
numbers in it would mean different functions on each side. The type makes that a compile error. Fixtures
`shared_tab_a/b.wasm`, assertions in `script/merge.sh`, before/after table in `docs/MERGE.md` §5.

## 4. Why verification is split three ways

`moonlift verify` is a MoonBit program running on `wasm-gc`/`js`; it cannot instantiate a wasm
module, and comparing against a second implementation written by the same project would prove
nothing. The smallest genuinely independent arrangement is:

| Side | Language | Responsibility |
|---|---|---|
| `core/verify.mbt` | MoonBit | decide **which** calls to make (fixed diagonal series + four anchored rows over a fixed value pool) and write `calls.tsv` |
| `corpus/tools/oracle.js` | Node / `WebAssembly` | run the **original** module and print `ok / trap / nan / error` + value |
| `script/verify.sh` | bash | paste the two, generate `inspect(...)` tests inside the **generated** package, run `moon test` |

A deterministic plan rather than random inputs is deliberate: a failure must be reproducible from
the report alone. `fib` gets a bounded argument pool and a `timeout` around the oracle, because the
original `fib(255)` never returns — that is a property of the fixture, not of the decompiler, and
the report says so.

## 5. What was deliberately not built

- **No Relooper / graph dispatcher** — unreachable in this subset (§3.2).
- ~~No `call_indirect` recovery~~ — **built in the 11-23 revision.** The first version refused it as
  `E111`, arguing a decompiled body could not reproduce a table dispatch. That argument was wrong:
  the target is unknown only at *compile* time, which is what a dispatcher is for. The generated
  module now keeps the table as function indices and gets one dispatcher per signature; the three
  wasm traps are reproduced and compared against the original (`docs/INDIRECT_CALL.md`).
- **No imported memory content** — an imported memory is materialised at its declared minimum and
  zero-filled, because the host's bytes are not in the binary (`BOUNDARY.md` D14, `docs/IMPORTS.md`).
- **No multi-value results** — `E112` at the signature, a trapping stub. The first version
  silently printed `vs[0]`; S9's real-compiler corpus exposed it.
- **No native backend** — this machine has no MSVC and `--target llvm` needs a nightly with
  `prelude.mi`. Correctness is judged against a reference engine, not against a native build, so
  this does not weaken any claim. Written down in BOUNDARY §4.2 rather than omitted.
- **No random-input fuzzing** — reproducibility beats coverage here.
- **No pretty output** — the generated code is a *witness*: `brk` variables, `// b3` provenance
  comments, one-shot loops. Readability is served by attributability, not by terseness.

## 6. Corpus as a design tool

Ten hand-written fixtures pin exact instruction, node and block counts. Thirty-one modules built by
MoonBit's own compiler (`corpus/extended/`, sources in `corpus/tools/sources/`) check the *shape*
of the claim instead: checksum → decode → decompile → zero-warning `moon check`. Compiler output
changes with every toolchain release, so pinning its internals would fail the gate on an upgrade
rather than on a bug. That layer found three bugs the hand-written fixtures could not: an integer
literal used as a method receiver, an underscored declaration versus a non-underscored assignment,
and a silently dropped second return value. All three are fixed, and the layer is now part of the
gate.
