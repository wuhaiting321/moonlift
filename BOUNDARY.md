# BOUNDARY — what moonlift accepts, rejects, and does not promise

This file is normative. If the code and this document disagree, that is a bug in one of them.

Version: 0.1.0 (final, stages S0–S11 complete). Every section below describes shipped code,
not a plan; §3's deviations and §4's limitations are the complete lists. If a claim here and a
command in `script/` disagree, that is a bug in one of them.

---

## 1. Input subset

| Aspect | Accepted | Rejected | Code |
|---|---|---|---|
| Container | `\0asm` + version `1` | other magic / version | `E002`, `E003` |
| Sections | type(1), import(2), function(3), table(4), memory(5), global(6), export(7), start(8), element(9), code(10), data(11), datacount(12), custom(0) | unknown section id | `E005` |
| Section order | the spec order, including `datacount` between `element` and `code` | duplicated or out-of-order section | `E005` |
| Value types | `i32` `i64` `f32` `f64`, plus `v128` **recognised but never generated** | `funcref` / `externref` outside a table | `E101` |
| Function signatures | any arity, zero or **one** result | a signature with several results (`E112`, per function) | `E112` |
| Instructions | every opcode `0x00`–`0xC4` with a known operand length: control, parametric, variable, memory, the numeric block, sign extension, plus `0xFC` bulk memory and the eight saturating truncations | `0xD0`–`0xD2` (reference types), `0xFB`, `0x1C`, tail calls, exception opcodes | `E006`, `E007`, `E101`, `E104`, `E105` |
| Instructions with an unknown operand length | nothing — decoding **stops** at `0xFD`/`0xFE` and the body is marked partial | — | partial body, reported by `disasm` |
| Memories | exactly one, 32-bit | `memory64`, multi-memory, shared memory | `E106`, `E103` |
| Tables | at most one, `funcref` only — indexed by `call_indirect`, initialised by active `elem` segments | a second table, `externref` tables | `E106`, `E101` |
| Imports | all four kinds. A function import becomes a stub that traps; memory, table and global imports are **bound**: the host passes its instances to `moonlift_bind()`, the binding record is de-duplicated by `(module, name)` so repeated imports alias, and `moonlift_init()` lays the segments into the bound instances | — (nothing in 1.0) | — |
| Several modules, one instance | two modules in one package share a `Memory` (and its `grow`) **and one function table**, because the merge keeps one `runtime.mbt` (one `Memory` type, one `Table` type) and one function index space for table slots; `decompile a.wasm b.wasm -o pkg` | two *separate* packages sharing an instance — that needs a shared runtime package (D15) | D15 |
| Data / element segments | active, table/memory 0, offset is an `i32` constant **or** a `global.get` of an imported immutable `i32` global; the latter is laid down by `moonlift_init()` | passive segments, element expressions, a `global.get` of a mutable or module-defined global | `E109`, `E012` |
| Control flow | reducible CFGs — guaranteed by the decoder's label-depth check, not by luck; measured 0 irreducible in 78 bodies | a `br` / `br_if` / `br_table` depth beyond the enclosing labels; irreducible CFGs are unreachable from this subset (`E108` reserved, see §3 D3) | `E008`, `E108` |
| Typing | every body the spec validates: operand types, block results, branch payloads, function result | a body that does not type-check (only reachable from a hand-patched or non-conforming producer) | `E011` |
| Multi-value | recognised (type-index block types, signatures with several results) and reported by `info` | *generated*: a block typed by index, a call returning several values, or a function with several results | `E112` |

**Status.** Everything in the table is implemented and tested (S2 = container, S3 = instruction
decoder + `disasm`, S4 = control-flow graph, S5 = typed stack simulation and type checking, S6 =
structuring back to `while` / `if` / `match`, S7 = MoonBit code generation, S8 = differential
verification, S9 = a 41-module corpus, S10 = this document, S11 = the acceptance material). §3 lists
the deviations structuring and code generation introduce; they are the complete list, and each one
is a decision with a reason rather than an oversight.

**Instruction-level rule: a wrong *length* stops, a wrong *value* is reported.** An opcode whose
operand size we do not know (`0xFD` SIMD, `0xFE` atomics) cannot be skipped, because guessing would
desynchronise the rest of the body and produce plausible-looking nonsense. Decoding stops there and
`DecodedBody.complete` becomes false; everything before it is still valid IR with valid offsets.
An opcode we fully understand but cannot generate (`0xFC` bulk memory) decodes
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
would otherwise pass every test while doing nothing. Both are checked on all ten good fixtures and on
the real artifact.

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
| E012 | malformed | a constant expression names a global it may not | only an imported immutable global of the right type |
| E101 | unsupported | GC / reference types | rebuild without reference types |
| E102 | unsupported | SIMD | disable auto-vectorisation |
| E103 | unsupported | threads/atomics | rebuild single-threaded |
| E104 | unsupported | exceptions | rebuild without EH |
| E105 | unsupported | tail calls | rebuild without sibling-call optimisation |
| E106 | unsupported | multi-memory / memory64 | single 32-bit memory |
| E108 | unsupported | irreducible CFG | see §3 |
| E109 | unsupported | bulk memory | no passive segments, no `memory.copy`/`fill` |
| E110 | unsupported | second table/memory named | one table, one memory |
| E112 | unsupported | multi-value block type, multi-result call, or a function with several results | rebuild without multi-value |

Rule: **reject, never silently degrade.** Emitting code that compiles but computes the wrong value is
the one failure mode this project refuses to have.

Every diagnostic carries the absolute byte offset of the field that failed, not of the section it is
in. `E004` on a section size points at the LEB128 byte, not at the section id.

## 3. Control-flow and code-generation deviations

Each entry states: deviation, reason, observable impact, and whether it is acceptable for the
declared subset. `E108` is reserved for the one case that is *not* acceptable and is refused rather
than approximated. D1–D11 came out of S6–S8; D12–D13 are the two corrections S9's real-compiler
corpus forced.

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

**Impact.** `brk` is dead weight in the emitted function body (S7 keeps it as a local, never as a
parameter) and it is the one piece of state a reader has to hold in their head. It is kept
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

### D6 · Multi-value bodies are refused per function — `E112`

**Deviation.** A body is emitted as a whole or refused as a whole. MoonBit functions return one
value, so 3 of 79 bodies in the real artifact are refused by name instead of approximated (one uses
`memory.copy`, two have several results). A function whose *signature* declares
two or more results is refused at the signature, before any instruction is simulated: the emitter
can only print `vs[0]`, and silently dropping the rest would be a wrong answer wearing a clean
compile (this is what S9 found in the compiler's `umul128` helper; the fix is pinned by a unit test
and by `script/extended.sh`).

**Reason.** A decompiler that produces a *compiling* function computing the wrong value is worse than
one that names the function it cannot translate. The same `E112` also covers a block typed by index
and a call returning several values, so the refusal is one rule with three entry points, not three
special cases.

**Impact.** Each refusal is reported with its function index, its name, the byte offset and the code
(`--struct-stats` lists all three). The remaining 75 bodies are complete; nothing is silently dropped —
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
body of `trap("f47 was not decompiled: E112 at byte 5431: ...")`. Its callers therefore still
compile, and the module runs everywhere except through that function.

**Reason.** The alternative — omitting the function — leaves every caller uncompilable. Measured: 4
stubs on the real artifact, one per refused or skipped function. A stub is also
strictly safer than the other alternative, inventing a body: it stops at the call rather than
returning a plausible wrong answer.

**Impact.** `funcs.mbt` for the real artifact holds 79 function definitions, 4 of which are stubs;
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

### D11 · The `start` section becomes a function the host calls

**Deviation.** A module with a `start` section gets `pub fn moonlift_init() -> Unit` in
`module.mbt`, and the host calls it once before using any export. A module without one gets the same
empty function, so the call site never has to ask.

**Reason.** Wasm runs the start function at instantiation, and a MoonBit package has no
instantiation step. Doing nothing would leave the module in a state the original never has — for
`globals.wasm` the difference is visible immediately, because its `start` sets the global that one of
its exports returns.

**Impact.** One extra call at startup, and one obligation on the host that wasm did not impose.
`globals.wasm` shows what it is for: its global `g4` starts at 0, its start function sets it to 1, and
its export `f4` returns it. Without the call the generated `f4()` answers 0 where the original answers
1 — which is why `script/verify.sh` calls `moonlift_init()` first, and why the fixture is in the
differential run rather than the smoke tests.

### D12 · A branch's payload is written at the edge, from the branch statement

**Deviation.** Two records describe the same edge and they do not always agree. `SBr` / `SBrIf` /
`SBrTable` carry the values the branch transfers; a block's `exit_exprs` record what was left on its
stack. When a branch-terminated block ends, the simulator cuts the stack to the target's base and
pushes the payloads back, so the two are the same *values*. The structurer reads the **statement**,
because a type marker left on the exit stack is not a value, and writes the payload into the
destination's temp before issuing the `break` / `continue` / `return`. When the statement carries
*fewer* values than the destination needs — a branch to a `loop` transfers the loop's parameters,
which the MVP subset cannot express, so `wants` is empty while the loop body still re-enters with
the values it reads at its top — the longer exit stack wins.

**Reason.** Found by `corpus/good/nested.wasm`, the first fixture with a value on the stack *at* a
`br_table`: reading `exit_exprs` alone assigned an unbound temporary, while reading only the
statement lost the back-edge values of the real compiler's `radix::count32` loop. Neither record is
sufficient alone; the rule "use the statement, fall back to the longer exit stack" is the smallest
one that is correct on both.

**Impact.** One `NAssign` per edge value, emitted in the predecessor — the last point where the
expression that produced the value is still correct. The `nested` smoke test pins all three arms
(back edge, `+10` arm, `*3` arm) against the original module; `script/extended.sh` pins the loop
case across 31 real modules. A wrong choice here compiles cleanly and changes values, which is why
both a behavioural test and a generated-package `moon check` guard it.

### D13 · A bare integer literal cannot be a method receiver

**Deviation.** `63.to_int64()` is a parse error in MoonBit: the lexer reads `63.` as the start of a
float literal. Every method-call spelling in the emitter (`to_int64`, `to_double`, `reinterpret_as_int`,
`clz`, `ceil`, `sqrt`, …) parenthesises a receiver that starts with a digit or a minus sign, and
leaves identifiers and already-parenthesised expressions alone.

**Reason.** Real compiler output puts constants directly under conversions (`i64.extend_i32_u(63)`);
the ten hand-written fixtures never did, so ten clean `moon check` runs did not cover it. S9's
`arith_double`, `arith_float`, `conversions` and `arith_i64` all failed until this was fixed.

**Impact.** Cosmetic only — `((63).to_int64())` instead of an unparseable `63.to_int64()`. No
semantics change. Pinned by `script/extended.sh`, which requires every one of the 31 generated
packages to compile at zero warnings.

### D14 · Instantiation is an explicit call, not a linker

**Deviation.** In wasm, `instantiate(module, externvals)` is performed by the embedder and the module
never sees it. Here the same two steps are explicit calls the host makes: `moonlift_bind(externs)`
hands over the instances, `moonlift_init()` lays the segments into them and runs `start`. A host that
skips `moonlift_bind()` runs against *stand-ins* — instances of the declared size, zero-filled, one
per distinct `(module, name)` pair — which preserve aliasing but are not the host's state.

**What is no longer a deviation.** Earlier versions materialised each import entry into its own object
and asked the host to pre-fill it. That broke the one thing the spec is unambiguous about: two import
entries naming the same `(module, name)` are the *same* external value. Two `(import "env" "counter"
(global (mut i32)))` entries produced two `Ref`s, so a write through the first was invisible through
the second. The generated record now has one field per distinct pair, and segments are copied at init
into whatever instance is bound, so nothing has to be pre-filled. Pinned by `corpus/good/alias.wasm`
and `script/sharing.sh` (5 properties), plus 17 compared calls in `script/verify.sh`.

**Reason for the remaining deviation.** A MoonBit package has no instantiation hook: the language
runs top-level `let` initialisers and nothing else. The host must call something; making it a named
function is what lets the same object be shared across calls — and, later, across modules that are
decompiled into one package.

**Impact.** Two consequences worth naming. A package that is never bound runs on stand-ins, and its
own doc comment, `docs/SHARING.md` §5 and the `BOUNDARY` entry here all say so in the same words. And
`moonlift_init()` is once per instance rather than once per call, because re-copying segments over a
memory the module has since written is a wrong answer, not a harmless repeat.

### D15 · Sharing one instance across modules needs one package

**Deviation.** In wasm, two modules that import the same `Memory` are given the same externval, and
`memory.grow` in one is visible through `memory.size` in the other. Here each generated package copies
`runtime.mbt`, so `pkg_a.Memory` and `pkg_b.Memory` are different types and no host can hand one value
to both. The measured consequence is not a compile error but a wrong answer: each module grows a
private memory and the second module's `size` never moves.

**How it is resolved.** `moonlift decompile a.wasm b.wasm -o pkg` puts both modules in one package:
one `runtime.mbt`, therefore one `Memory` type; one namespace, therefore a `m0_` / `m1_` prefix on
every top-level name (`M0_` / `M1_` for the one type, because MoonBit type names start upper-case);
one binding record per module, so the host fills `env_mem` in both with the same object; and one
`moonlift_init_all()` that instantiates them in input order. Merging is the whole mechanism — nothing
about the instance type changed.

**Tables need one more thing.** A memory is shared by binding one object to both modules, and that is
all. A table is shared the same way, but the *contents* have to mean the same thing to both: a slot
holds a function index, and every module's functions start at `0`. So a merged package gets one
function index space — module `i`'s first function sits at the sum of the previous modules' function
counts, the element segments write `base + f`, and every `call_indirect` dispatcher carries arms for
the *whole* package (`0 => m0_f0()`, `2 => m1_f0()`), not just for its own module. Without that, B
calling a slot A filled would reach B's own function 0 — a wrong answer, not a trap. A single-module
decompile has `base = 0` and no siblings, so its output is unchanged. Table values are also a type,
not an `Array[Int]`: `Table` lives in `runtime.mbt`, so two separate packages cannot be handed one
table even by mistake.

**What is still not supported.** Sharing between two *separate* packages — for a memory or a table —
which would need a shared runtime package and therefore a dependency the generated package does not
currently have. (The type system, not this paragraph, is what stops it: `pkg_a.Table` and `pkg_b.Table`
are different types.) Function imports stay traps. And `start` ordering across merged modules is the
command line's order, not a topological sort.

**Impact.** `docs/MERGE.md` §4 is the memory before/after table and §5 the table one; `script/merge.sh`
is the nine assertions; `corpus/good/shared_a.wasm` / `shared_b.wasm` and `shared_tab_a.wasm` /
`shared_tab_b.wasm` are the pairs. Pinned by the gate rather than promised.

## 4. Known limitations at 0.1.0

1. **The differential run covers exports, not bodies.** `script/verify.sh` compares 522 calls across
   16 fixtures, and every one matches; a further 244 calls where the original traps or returns NaN
   are skipped and counted separately. A module that imports memory, table or global *is* covered:
   the plan carries the shape of every non-function import, so Node can build the host object and
   the comparison runs on both sides (`imported` contributes 7 compared calls, and the
   two `imports` exports that never reach an imported function contribute 2 more). What it does *not*
   do: reach a function that is not exported (nothing can call it, but nothing proves it either),
   compare an export that goes through a *function* import (neither side has an implementation, so
   both trap — `imports` and `moonbit_fib` are in this group), or invent argument combinations — the
   plan is a fixed diagonal and four anchored rows over a fixed value pool. A random-input mode is
   possible and was deliberately not built: a failure has to be reproducible from the report alone.
   The 31 extended-corpus modules are also not compared: they all import a host function for
   `println`, so the only exports they have are those that do not reach it; what is checked for them
   is decode and a clean generated package instead.
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
   `info` parses the first three (they are structural). Across the 10 good fixtures the decoder is
   cross-checked against wabt: **4,485 instructions agree, 0 mismatch**, and the 62 instructions
   after the SIMD prefix in `..._blit__from__string__simd` are deliberately not attempted.
   `moonbit_fib.wasm` in `corpus/good/` is the evidence, and `moonlift disasm --stats` prints the
   one partial body.
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
16. **A refused multi-result function has a trapping stub, not a one-value approximation.** The
    generated package is still buildable and its other functions still work, but calling that stub
    aborts. This is the observable cost of `E112` at the signature (§3 D6).
17. **The extended corpus is checked for shape, not behaviour.** All 31 real-compiler modules decode
    and every generated package compiles at zero warnings, but their bodies are never executed: they
    import a host for `println`. `script/extended.sh` says so at the top; the differential claim in
    §5 applies to `corpus/good/` only.
18. **The full gate takes about three and a half minutes.** `script/check.sh` runs `moon check` on
    31 generated packages in addition to the three-target build, 152 unit tests on two targets, the
    wabt cross-check and the differential run. It needs no network and no C toolchain; on a machine
    with `native` available the same commands work unchanged.
19. **Traps and NaNs are skipped, not compared.** The original plan (`PLAN.md` §7) counted a trap
    as a comparable observation and allowed ≤1 ULP for floats. The shipped harness does neither:
    `trap(...)` in MoonBit is an abort, not a raisable error — trying to `catch` it produces warning
    `unused_try` — so a generated test cannot observe its own trap without killing the test process.
    Calls where the original traps or returns a NaN are therefore recorded as **skipped**, in their
    own column, and never counted as passes: 384 compared / 384 matched / 164 skipped. Floats are
    compared as exact signed bit patterns, with no ULP tolerance, because the point of comparing
    bits is precisely that a printer round trip must not change a NaN payload or the sign of a zero.
    Linear-memory hashes after a call are also not compared; the differential claim is about
    exported return values. These are three deliberate reductions of the original M3 contract and
    are listed here rather than hidden behind a single "100% pass" number.

## 5. Reproduce every claim

```bash
bash script/check.sh
```

Every number quoted in the README or in the submission form must be reproducible by a command in
`script/`; otherwise it does not belong in the document. The script currently verifies: formatting,
three-target `moon check`, 152 unit tests on two targets, CLI usage paths, 10 good fixtures decoded,
19 malformed fixtures rejected with code + offset (8 of them at the instruction layer, each
reporting the code written in its filename — including one that decodes but does not type-check),
byte-identical `info`, `disasm --ops`, `disasm --cfg`, `disasm --stack` **and** `disasm --struct`
output across `wasm-gc`, `js` and `wasm`, a graph for every fixture with no body coming out
irreducible, the pinned recovery counts of the real artifact (72 of 79 analysed, 6 refused, 1
skipped, 0 rejected, 111 spills of which 1 is a reordering hazard), both reordering hazards on the
fixture that isolates them, the structurer on every fixture (no raw `br` / `br_if` / `br_table` /
`if (...)` may survive; `blocks emitted 395 of 395`; `nodes 1115`, `guards 32`, `switches 0`, `max
depth 7`; and `structured + skipped + refused` must equal the function count), a cross-check of
every decoded mnemonic against wabt (`4,485 matched, 0 mismatched, 62 not attempted`), **the pinned
`decompile` summary of all 10 good fixtures and `moon check` of every generated package at zero
warnings**, **execution of the generated `control`, `fib` and `nested` packages against values taken
from the original module under Node**, the full differential run, and `script/extended.sh` — checksum,
decode, decompile and a zero-warning `moon check` for all **31 real-compiler modules**.

Three of those deserve their own sentence because they are the ones that would otherwise let a broken
emitter pass:

- `moon check` at **zero warnings**, not merely zero errors: the naming and pruning rules of D7 and
  D9 exist only to satisfy this, and a regression shows up as a warning.
- the smoke tests run the *generated* code and compare with the *original* module in Node
  (`corpus/tools/oracle.js`). Three bugs found in the emitter — a `br_if` to the end of the body
  emitted as an unconditional `return`, a block entry value printed as `in0` with nothing binding
  it, and a `br_table` payload read from a temporary nobody stored — compile cleanly or pass every
  structural check. Only running the code found them.
- the differential run (`script/verify.sh`) goes further: 384 planned calls on 8 fixtures, every one
  compared against the original, then `moon test` inside the generated package. Both counts are
  pinned, so a loss of coverage fails the gate even when everything that *was* compared passed.

`verify` itself is a plan, not a comparison: `moonlift verify` cannot run a wasm module (it is
written in MoonBit and runs on `wasm-gc`/`js`), and comparing against a second implementation of
ours would prove nothing. The split — plan in MoonBit, comparison in Node, orchestration in bash — is
the smallest arrangement in which the two sides are genuinely independent.
