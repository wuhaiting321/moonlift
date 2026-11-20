# BOUNDARY — what moonlift accepts, rejects, and does not promise

This file is normative. If the code and this document disagree, that is a bug in one of them.

Version: 0.1.0 (stage S7). Sections marked *(S10)* are filled in as the corresponding stage lands;
what is written below is already true of the shipped code.

---

## 1. Input subset

| Aspect | Accepted | Rejected | Code |
|---|---|---|---|
| Container | `\0asm` + version `1` | other magic / version | `E002`, `E003` |
| Sections | type(1), import(2), function(3), table(4), memory(5), global(6), export(7), start(8), element(9), code(10), data(11), datacount(12), custom(0) | unknown section id | `E005` |
| Section order | the spec order, including `datacount` between `element` and `code` | duplicated or out-of-order section | `E005` |
| Value types | `i32` `i64` `f32` `f64`, plus `v128` **recognised but never generated** | `funcref` / `externref` outside a table | `E101` |
| Function signatures | any arity, zero or more results | — (multi-value is parsed and flagged; codegen refuses those functions individually) | — |
| Instructions | every opcode `0x00`–`0xC4` with a known operand length: control, parametric, variable, memory, the numeric block, sign extension, plus `0xFC` bulk memory and the eight saturating truncations | `0xD0`–`0xD2` (reference types), `0xFB`, `0x1C`, tail calls, exception opcodes | `E006`, `E007`, `E101`, `E104`, `E105` |
| Instructions with an unknown operand length | nothing — decoding **stops** at `0xFD`/`0xFE` and the body is marked partial | — | partial body, reported by `disasm` |
| Memories | exactly one, 32-bit | `memory64`, multi-memory, shared memory | `E106`, `E103` |
| Tables | any number, `funcref` only | `externref` tables | `E101` |
| Imports | function imports only (S3 onward, surfaced as a `Host` trait whose default method traps) | memory/table/global imports | `E107` |
| Data / element segments | active, table/memory 0, i32 constant offset | passive segments, element expressions | `E109` |
| Control flow | reducible CFGs — guaranteed by the decoder's label-depth check, not by luck; measured 0 irreducible in 78 bodies | a `br` / `br_if` / `br_table` depth beyond the enclosing labels; irreducible CFGs are unreachable from this subset (`E108` reserved, see §3 D3) | `E008`, `E108` |
| Typing | every body the spec validates: operand types, block results, branch payloads, function result | a body that does not type-check (only reachable from a hand-patched or non-conforming producer) | `E011` |
| Multi-value | recognised (type-index block types, signatures with several results) and reported by `info` | *generated*: a block typed by index, or a call returning several values | `E112` |

**Status.** Everything in the table is implemented and tested (S2 = container, S3 = instruction
decoder + `disasm`, S4 = control-flow graph, S5 = typed stack simulation and type checking, S6 =
structuring back to `while` / `if` / `match`, S7 = MoonBit code generation). §3 lists the deviations
structuring and code generation introduce; they are the complete list, and each one is a decision
with a reason rather than an oversight.

**Instruction-level rule: a wrong *length* stops, a wrong *value* is reported.** An opcode whose
operand size we do not know (`0xFD` SIMD, `0xFE` atomics) cannot be skipped, because guessing would
desynchronise the rest of the body and produce plausible-looking nonsense. Decoding stops there and
`DecodedBody.complete` becomes false; everything before it is still valid IR with valid offsets.
An opcode we fully understand but cannot generate (`0xFC` bulk memory, `call_indirect`) decodes
normally and is refused later, at the point of generation. Measured effect: of 79 bodies in the
20 KB MoonBit artifact, 78 decode completely and 1 stops — the function whose name ends in `simd`.

**The function's own `end` is the body terminator, not an instruction.** It is validated (it must be
the last byte) and then dropped, so the instruction stream is `instr*` and the body exit is implicit.
wabt's text format does the same: it prints `end)` for the outermost block and nothing for the
function end, which is why the two decoders' per-body instruction counts agree exactly.

**The parse/generate split is deliberate.** `info` parses more than `decompile` will generate:
`v128` types, multi-value signatures, huge local counts and (later) unimplemented opcodes are all
*reported* by `info` and *refused per function* by the code generator. Refusing at the container
layer would hide which function is the problem; refusing silently would be worse.

**Control-flow graph contract.** A block is a half-open range of *real* instructions: `end` and
`else` close a range and are never blocks of their own, and `if` is a real instruction because it has
two successors. The function's own `end` is not in the stream (§ above), so a body of `n` instructions
ends at `n` and a fall-through off the end is an edge to a virtual `exit` block at index `n`, as are
`return` and a branch to the function's own label. Unreachable blocks — code after an unconditional
`br` — are **kept and marked**, not deleted: a decompiler that silently drops code cannot be audited,
and the marker is what makes the reason visible (`disasm --cfg` prints `(unreachable)`).

**Reducibility is a guard, and it is honest about never firing.** Structured wasm branches only to
labels of enclosing constructs, so every CFG it can express is reducible; the Hecht–Ullman test in
`core/cfg.mbt` therefore returns "reducible" for all 78 complete bodies of the real MoonBit artifact
and for every fixture. The analysis exists because the structurer must be able to *state* that
precondition (a `br` whose target is not an enclosing construct would mean the input is malformed,
and an unreducible graph is refused with `E108` rather than approximated), and because a false
positive would be a structuring bug that no test would otherwise catch. It is tested on hand-written
successor matrices, since a wasm fixture cannot produce the input.

**Structuring contract.** The structurer walks the input's own construct tree — wasm's `block` /
`loop` / `if` with their `end`s — instead of re-deriving nesting from the flat graph, because that
tree is information the format never lost. Two properties are asserted rather than assumed:
**every reachable block is emitted exactly once** (`blocks emitted N of N` in `--struct-stats`, and a
per-function `visited == reachable` test), and **no `br` / `br_if` / `br_table` / bare `if (...)`
statement survives into the output** — a structurer whose fallback is "leave the graph as it was"
would otherwise pass every test while doing nothing. Both are checked on all nine fixtures and on the
real artifact.

**Typed stack contract.** Each block is simulated once, in block-index order, which is a topological
order of the forward edges (a loop's back edge points at a lower index). A block's entry is the exit
shape of its first resolved predecessor; every other predecessor must agree *exactly*, and a
disagreement is a validation error rather than a merge. The stack shapes at a block's edges are
therefore a property of the input, not a choice made here — which is what lets S7 assign them to
variables without consulting anything else.

Three reorderings are forbidden, and each is enforced by materialising the pending value into a
temporary *before* the instruction that would invalidate it:

| Hazard | Why it is wrong | Cost |
|---|---|---|
| a pending `local.get i` across `local.set i` | the read would observe the new value | one temp per occurrence |
| a pending `i32.load` across a store, a call, or `memory.grow` | the read would observe the new memory (or trap differently) | one temp per occurrence |
| a pending `global.get i` across `global.set i` or any call | a call may write any global | one temp per occurrence |

A fourth is not a hazard but a requirement: a **call** must execute where it appears, so its result
is always materialised immediately. Those temporaries are counted separately (`forced`) from the
hazard ones, because only the latter are decompiler mistakes waiting to happen. Measured on the real
artifact: 110 forced, 1 hazard across 72 analysed bodies — which is the shape the design predicts,
and the reason the distinction is worth keeping.

**What is *not* deferred at all.** A block's exit expressions are evaluated after its last statement,
so anything that could change between the push and the end of the block is sunk. Nothing else is
carried across a block: a value arriving from a predecessor is named `in0`, `in1`, i.e. it is treated
as the block parameter it becomes in the generated code.

## 2. Error codes

Frozen. Never renumbered; new codes are appended. `core/all_codes()` is the single source of truth
and a test asserts that the tags stay unique and that the count matches.

| Tag | Class | Meaning | Remedy |
|---|---|---|---|
| E001 | malformed | truncated input | file shorter than declared sizes |
| E002 | malformed | missing `\0asm` | not a wasm file |
| E003 | malformed | version != 1 | only binary format 1 |
| E004 | malformed | bad LEB128 | corrupt length/index |
| E005 | malformed | bad section | size, order, count or flag inconsistent |
| E006 | malformed | bad opcode | outside the MVP set, or illegal in this position |
| E007 | malformed | bad value type | outside i32/i64/f32/f64/v128 |
| E008 | malformed | index out of range | func/local/global/type/label |
| E009 | malformed | bad UTF-8 | name or import string |
| E010 | malformed | segment out of bounds | data/element range |
| E011 | malformed | operand stack does not type-check | see §5; `disasm --stack` names the byte |
| E101 | unsupported | GC / reference types | rebuild without reference types |
| E102 | unsupported | SIMD | disable auto-vectorisation |
| E103 | unsupported | threads/atomics | rebuild single-threaded |
| E104 | unsupported | exceptions | rebuild without EH |
| E105 | unsupported | tail calls | rebuild without sibling-call optimisation |
| E106 | unsupported | multi-memory / memory64 | single 32-bit memory |
| E107 | unsupported | non-function import | link memory/table/global statically |
| E108 | unsupported | irreducible CFG | see §3 |
| E109 | unsupported | bulk memory | no passive segments, no `memory.copy`/`fill` |
| E110 | unsupported | second table/memory named | one table, one memory |
| E111 | unsupported | indirect call through a table | inline the call |
| E112 | unsupported | multi-value block type or multi-result call | rebuild without multi-value |

Rule: **reject, never silently degrade.** Emitting code that compiles but computes the wrong value is
the one failure mode this project refuses to have.

Every diagnostic carries the absolute byte offset of the field that failed, not of the section it is
in. `E004` on a section size points at the LEB128 byte, not at the section id.

## 3. Control-flow deviations *(S10)*

Populated during S6/S7. Each entry states: deviation, reason, observable impact, and whether it is
acceptable for the declared subset. `E108` is reserved for the one case that is *not* acceptable and
is refused rather than approximated.

### D1 · Every `block` becomes a one-shot `while true`, not a labelled scope

**Deviation.** wasm's `block` is a scope with a label; MoonBit has no labelled blocks and no labelled
`break`. A `block` is therefore emitted as `while true { ...; break }` — a loop that runs at most
once — so that a jump to its `end` has a `break` to land on.

**Reason.** Measured, not assumed: a labelled loop is a lexing error in MoonBit
(`'outer : while true {...}` → `unrecognized character "'"`, U+0027), and `break` closes the
*innermost* loop only. There is no other way to express "jump to the end of this scope".

**Impact.** One extra level of nesting per `block`, and `continue` is legal where the original had no
loop — a construct that must not use it (`cont_of` in `core/struct.mbt` returns `-1` for a `block`,
so the renderer never emits `continue` there). Cost measured on the real artifact: 32 guard
constructs, maximum nesting depth 7.

### D2 · A branch that leaves several constructs needs one variable, `brk`

**Deviation.** A `br 3` that leaves four nested constructs cannot be one `break`. The output carries a
single `int` — `brk` — holding the construct being escaped (`-1` for none). The branch writes
`brk = n; break`, and each guard on the way out either clears it, passes it one level further out, or
turns it into a `continue` if it names the enclosing loop.

**Reason.** Without it, the only alternative is a per-function state machine with a dispatch loop and
one block per case, which is what an unconditional Relooper produces and which makes even a plain
`if` unreadable.

**Impact.** `brk` is dead weight in the emitted function signature (S7 will keep it as a local,
never as a parameter) and it is the one piece of state a reader has to hold in their head. It is kept
to the minimum: a direct `br 0` out of a `loop` is still a plain `continue`, a `br_if` to the
innermost `block` is still a plain `break` (verified by a test that asserts `brk = 1` is *absent* from
that function's output), and `switches 0` in `--struct-stats` shows the real artifact needed no
`match` at all.

### D3 · There is no Relooper, and no graph dispatcher either

**Deviation.** This build has no Relooper. The structurer never sees an arbitrary graph: it walks the
construct tree the input already carries (`block` / `loop` / `if` with their `end`s). `E108` exists in
the taxonomy and the Hecht–Ullman test exists in `core/cfg.mbt`, but the test's only job is to state a
precondition — no code path returns `E108`.

**Reason.** Irreducibility is impossible for this input, and the guarantee comes from the *decoder*,
not from luck: `check_label` rejects a `br` / `br_if` / `br_table` depth that exceeds the enclosing
label stack (`E008`), so every branch names a construct it is nested inside — which is the definition
of a reducible graph. Measured: 78 of 78 complete bodies in the real artifact are reducible, 0
irreducible, and the same holds for every fixture. A dispatcher would therefore be code that no
producer in the subset can reach and no test can exercise; shipping it would be worse for a reviewer
than saying plainly that it is absent.

**Impact.** If a producer is ever found that violates this — which would require it to emit a binary
this decoder rejects — the failure is a rejection at decode time, not a structurer emitting a body
that computes something else. The claim is guarded in `script/check.sh` (`no body may come out
irreducible`) and the reducibility analysis itself is tested on hand-written successor matrices,
including the classic Hecht–Ullman two-entries-into-a-cycle example.

### D4 · A `br` that leaves the function is printed as `return`

**Deviation.** `br` to the outermost label and `return` are the same instruction at run time; the
first is emitted as a `return`, not as a branch to a nonexistent label.

**Reason.** There is no enclosing label to jump to once the outermost construct is left.

**Impact.** None observable — the two are byte-for-byte equivalent at run time. They stay distinct in
the IR (`SReturn` vs `SBr`) so the loss of information is visible rather than silent, and every leaf
is labelled with the block index it came from (`;; b7`), so a `return` printed at the end of a leaf
stays attributable to the block that produced it.

### D5 · An `if` arm gets a one-shot loop only when something branches to that `if`

**Deviation.** A `br` that targets an `if` must skip the rest of the arm, and the arm has no loop of
its own. Arms are therefore wrapped in `while true { ... }` **per arm**, and only when a branch
inside that arm actually targets this `if`.

**Reason.** Wrapping unconditionally would put `while true` around every arm of every `if`, which is
the noise that makes Relooper output unreadable. The condition is decidable from the construct tree,
so it is decided exactly.

**Impact.** None on semantics; strictly less noise. `corpus/good/control.wasm` exercises both cases
(`$guard` has no wrap, `$find_limit` wraps one arm).

### D6 · Multi-value and `call_indirect` bodies are refused per function — `E111`, `E112`

**Deviation.** A body is emitted as a whole or refused as a whole. MoonBit functions return one
value, and there is no way to reproduce a table dispatch from recovered source, so 6 of 79 bodies in
the real artifact are refused by name instead of approximated.

**Reason.** A decompiler that produces a *compiling* function computing the wrong value is worse than
one that names the function it cannot translate.

**Impact.** Each refusal is reported with its function index, its name, the byte offset and the code
(`--struct-stats` lists all six). The remaining 72 bodies are complete; nothing is silently dropped —
`structured + skipped + refused` is asserted to equal the function count in `script/check.sh`.

### D7 · The emitter drops an unreachable tail; the structurer still produces it

**Deviation.** The structurer places a guard after a construct whose body ends in `return`,
`continue`, `break` or an unwind. The emitter stops printing at such a node, so the tail is absent
from `funcs.mbt` while `disasm --struct` still shows it. The pruning rule is deliberately narrow: a
sequence stops after a node that cannot fall through, and a `while true` counts as one only when its
body ends in a terminal transfer *and* nothing inside it breaks or unwinds — the only case where no
exit exists at all.

**Reason.** Kept in the tree because it is a true statement about the graph, dropped from the text
because an unreachable statement is a warning in every build of the generated package, and the output
has to compile cleanly to be usable.

**Impact.** Cosmetically the two views differ, which §5's gate tolerates by construction: every
declaration analysis (`mark_locals`, `assigned_locals`, `scan_reads`, `uses_brk`) walks the tree
through the *same* pruning, so no declaration refers to something that was dropped, and no dropped
statement can introduce a name. What is dropped is unreachable by construction, so nothing observable
changes. Verified on the fixtures whose loops exit by `br_if` (`control.wasm`, `moonbit_fib.wasm`).

### D8 · A body that cannot be translated becomes a trapping stub, not a missing function

**Deviation.** A refused or skipped function is written as a function with its real signature and a
body of `trap("f47 was not decompiled: E111 at byte 5431: ...")`. Its callers therefore still
compile, and the module runs everywhere except through that function.

**Reason.** The alternative — omitting the function — leaves every caller uncompilable. Measured: 7
errors on the real artifact, one per refused function that something still calls. A stub is also
strictly safer than the other alternative, inventing a body: it stops at the call rather than
returning a plausible wrong answer.

**Impact.** `funcs.mbt` for the real artifact holds 79 function definitions, 7 of which are stubs;
the count is asserted in `script/check.sh` so a stub cannot quietly disappear. Each stub carries the
diagnostic in its doc comment and in its `trap` message.

### D9 · Names are generated, and unused ones are underscored

**Deviation.** Parameters are `p0`, locals `l0`, temporaries `t0`, functions `f0`, globals `g0` — the
original names are gone unless the module's custom `name` section supplied them (which
`moonbit_fib.wasm` does, and those names appear in comments). A parameter the body never reads and
never writes is `_p0`; a local that nothing reads is `_l3`; a temporary that is only written is `_t2`;
`mut` appears only where something is stored. Exports keep their published name unless it is a
MoonBit keyword or not a legal identifier, in which case `e_` is prefixed (`guard` → `e_guard`) and a
leading digit is prefixed with `e_` too.

**Reason.** The generated package must compile with zero warnings, and MoonBit signals every one of
these as a warning. The underscore is MoonBit's own spelling for "deliberately unused", so the output
says what it means; stripping meaning out of names would instead hide it.

**Impact.** The output is not a byte-for-byte reverse of the input source, and it is not claimed to
be: it is a program with the same behaviour and the same block structure, with block provenance kept
in `// b3` comments that match `disasm --struct`. Renamed exports are listed by `decompile` on
request (the sanitised name is in `exports.mbt`, one line per export).

### D10 · Floats are emitted as bit patterns, not decimal literals

**Deviation.** `f32` constants are written as `Float::reinterpret_from_int(2143289345)` and `f64`
constants as `Int64::reinterpret_as_double(…L)`. No decimal literal appears in the output.

**Reason.** A decimal literal has to survive a printer on the way out and a parser on the way back in,
and the two things it must not lose are a NaN payload and the sign of a zero. `-0.0` printed as
`0.0`, or a signalling NaN quietened by a formatter, would be a silent semantic change in a
decompiler.

**Impact.** Less readable, exactly equal. The same reasoning applies to `min` / `max` / `abs` /
`copysign` / `nearest`, which are runtime helpers rather than operators: their wasm semantics (NaN
propagation, `min(0, -0) = -0`, ties-to-even) are not the host language's, and every one of them was
measured before being written into `runtime/runtime.mbt`.

## 4. Known limitations at 0.1.0

1. **`verify` is not implemented yet.** `decompile` works end to end and is gated (all 9 fixtures
   compile at zero warnings; 2 of them are executed against values the original produces under Node),
   but the differential harness that would run *every* decompiled function on generated inputs is S8.
   Until it exists, "behaves like the original" is a claim about the 23 pinned calls in
   `script/smoke/`, not about the module as a whole.
2. **native backend unverified.** This machine has no MSVC and `--target llvm` requires a nightly
   toolchain (`missing prelude.mi`). Verification therefore runs on `wasm`, `wasm-gc` and `js`.
   Installing VS Build Tools makes native available; it does not change any correctness criterion,
   because correctness is judged against a reference engine, not against a native build.
3. **No portable exit code.** MoonBit exposes no `exit()`; the CLI echoes `moonlift: exit N` and the
   scripts parse it. When a portable API appears, this note goes away.
4. **First build needs the network** to fetch `moonbitlang/x@0.5.6` (file IO). The local registry
   index currently caps at 0.5.6; `moon update` times out on this network, so the pin is deliberate.
5. **Nullary enum variants cannot be constructed across packages** in toolchain 0.1.20261020
   (`error 4036: cannot create values of the read-only type`). Matching them works, constructing
   them does not. Consequences: (a) taxonomy tests live in `core/*_wbtest.mbt`; (b) all formatting
   that needs to *build* an enum value lives in `core/` (`report.mbt`), not in the CLI.
6. **`argv` layout differs per backend**, measured not assumed: `wasm-gc` and `wasm` pass
   `[program, subcommand, ...]`, `js` passes `[node, main.js, subcommand, ...]`. The CLI therefore
   locates the first known subcommand instead of dropping a fixed number of tokens. Found by the
   cross-backend check in `script/check.sh`, which now compares full output, not just exit status.
7. **`Bytes::to_unchecked_string` is not a UTF-8 decoder.** It reinterprets bytes as UTF-16LE, so
   `b"\x03abc"` decodes to `"扡"`. `core/utf8.mbt` contains a real decoder; do not "simplify" it away.
8. **MoonBit's own wasm output is not in the MVP subset.** It emits a `datacount` section,
   multi-value signatures, `v128` locals in its memcpy helper, and bulk-memory/SIMD instructions.
   `info` parses the first three (they are structural); the instruction decoder reads 4,423 of its
   4,485 instructions and stops at the SIMD prefix in `..._blit__from__string__simd`.
   `moonbit_fib.wasm` in `corpus/good/` is the evidence, and `moonlift disasm --stats` prints it.
9. **Alignment hints are validated, not ignored.** An `align=` exponent larger than the natural
   alignment of the access is a spec violation; it is rejected with `E007` rather than carried into
   generated code, where it would produce a misaligned read.
10. **Type checking is block-local, not global.** The stack simulation validates every block and
    every edge, which catches everything a whole-module validator would catch *except* one class:
    unreachable code is not type-checked at all. After `unreachable`, `br`, `br_table` or `return`,
    the spec gives the stack a polymorphic type, and the blocks that follow have no reachable
    predecessor; they are marked dead and skipped (see §4.12). This is a deliberate trade: dead code
    cannot affect the generated program, and simulating it would require inventing a stack shape for
    code that by definition has none. A module that is invalid *only* inside dead code is therefore
    accepted here and rejected by a full validator.
11. **Loops are identified at block granularity.** When two nested loops share a header block (their
    first instruction is the same, which happens when the inner loop opens immediately), the analysis
   reports one loop, not two: a block is the smallest unit, and both headers *are* that block. This
   does not affect correctness of the emitted code — the structurer works on constructs, which are
   per-instruction, not on blocks — but it means "loops: 20" is a count of distinct block headers,
   not of `loop` keywords in the source. The alternative (per-instruction loop identity) would add a
   second, finer graph that nothing consumes.
12. **Dead code is analysed, not executed.** A block reachable only through a branch that no path
    takes is still walked by the dominator and loop passes; what marks it is the DFS from the entry,
    not a separate liveness analysis. Blocks after `unreachable` are the common case.
13. **A partial body has no graph.** `disasm --cfg` prints `skipped: stopped at byte N ...` for the
    one SIMD helper instead of inventing blocks from half a function. The instruction listing still
    shows everything it decoded; only the graph refuses.
14. **`if` conditions and block results are not folded into the outgoing edges.** The condition of an
    `if` is a statement (`SIf`) on the block that ends with it, and the values a block hands on are
    its `exit` expressions; the edge itself carries only types. This keeps a block's analysis local.
    The cost is that the structurer has to materialise edge values into variables — done in S6 at the
    predecessor, which is the last point where those expressions are still correct — so the generated
    code carries one assignment per edge value rather than a redesign of the analysis.
15. **A `br` that leaves the function is emitted as `return`.** `br` to the outermost label and
    `return` are the same instruction at run time; printing the first as a `br` would produce a label
    with no enclosing label, which is not expressible in structured code. The two are distinguished
    in the IR (`SReturn` vs `SBr`) so the loss of information is visible rather than silent.

## 5. Reproduce every claim

```bash
bash script/check.sh
```

Every number quoted in the README or in the submission form must be reproducible by a command in
`script/`; otherwise it does not belong in the document. The script currently verifies: formatting,
three-target `moon check`, 150 unit tests on two targets, CLI usage paths, 9 fixtures decoded,
19 malformed fixtures rejected with code + offset (8 of them at the instruction layer, each
reporting the code written in its filename — including one that decodes but does not type-check),
byte-identical `info`, `disasm --ops`, `disasm --cfg`, `disasm --stack` **and** `disasm --struct`
output across `wasm-gc`, `js` and `wasm`, a graph for every fixture with no body coming out
irreducible, the pinned recovery counts of the real artifact (72 of 79 analysed, 6 refused, 1
skipped, 0 rejected, 111 spills of which 1 is a reordering hazard), both reordering hazards on the
fixture that isolates them, the structurer on every fixture (no raw `br` / `br_if` / `br_table` /
`if (...)` may survive; `blocks emitted 395 of 395`; `nodes 1115`, `guards 32`, `switches 0`, `max
depth 7`; and `structured + skipped + refused` must equal the function count), a cross-check of
every decoded mnemonic against wabt (`4,423 matched, 0 mismatched, 62 not attempted`), **the pinned
`decompile` summary of all 9 fixtures and `moon check` of every generated package at zero warnings**,
and **execution of the generated `control` and `fib` packages against values taken from the original
module under Node**.

Two of those deserve their own sentence because they are the ones that would otherwise let a broken
emitter pass:

- `moon check` at **zero warnings**, not merely zero errors: the naming and pruning rules of D7 and
  D9 exist only to satisfy this, and a regression shows up as a warning.
- the smoke tests run the *generated* code and compare with the *original* module in Node
  (`corpus/tools/oracle.js`). Both bugs found in the emitter — a `br_if` to the end of the body
  emitted as an unconditional `return`, and a block entry value printed as `in0` with nothing binding
  it — compile cleanly and pass every structural check. Only running the code found them.
