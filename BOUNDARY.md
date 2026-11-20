# BOUNDARY — what moonlift accepts, rejects, and does not promise

This file is normative. If the code and this document disagree, that is a bug in one of them.

Version: 0.1.0 (stage S4). Sections marked *(S10)* are filled in as the corresponding stage lands;
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
| Control flow | reducible CFGs — and every CFG structured wasm can express is reducible; measured 0 irreducible in 78 bodies | irreducible CFGs (reachable only through a hand-built graph, not through wasm) | `E108` |

**Status.** Everything down to "instructions with an unknown operand length" is implemented and
tested (S2 = container, S3 = instruction decoder + `disasm`, S4 = control-flow graph). Control-flow
*structuring* and code generation are contracts for S6–S7.

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
and for every fixture. The analysis exists because the Relooper needs to *know* that, and because a
false positive would be a structuring bug that no test would otherwise catch. It is tested on
hand-written successor matrices, since a wasm fixture cannot produce the input.

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

Rule: **reject, never silently degrade.** Emitting code that compiles but computes the wrong value is
the one failure mode this project refuses to have.

Every diagnostic carries the absolute byte offset of the field that failed, not of the section it is
in. `E004` on a section size points at the LEB128 byte, not at the section id.

## 3. Control-flow deviations *(S10)*

Populated during S6/S7. Each entry will state: deviation, reason, observable impact, and whether it
is acceptable for the declared subset. `E108` is reserved for the one case that is *not* acceptable
and is refused rather than approximated.

## 4. Known limitations at 0.1.0

1. **No decompilation yet.** `decompile` and `verify` print "not implemented" and exit 2. `info` and
   `disasm` are fully implemented.
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
   `info` parses the first three (they are structural); the instruction decoder reads 3,878 of its
   3,940 instructions and stops at the SIMD prefix in `..._blit__from__string__simd`.
   `moonbit_fib.wasm` in `corpus/good/` is the evidence, and `moonlift disasm --stats` prints it.
9. **Alignment hints are validated, not ignored.** An `align=` exponent larger than the natural
   alignment of the access is a spec violation; it is rejected with `E007` rather than carried into
   generated code, where it would produce a misaligned read.
10. **No type checking yet.** The decoder validates *structure* (label depth, `else` placement,
    function-final `end`, index bounds, memarg alignment) but not *types*: `i32.add` on two `f32`
    operands decodes without complaint. The typed stack simulation of S5 is what makes that an
    error, and until it lands this is a real gap, stated here rather than implied.
11. **Loops are identified at block granularity.** When two nested loops share a header block (their
    first instruction is the same, which happens when the inner loop opens immediately), the analysis
    reports one loop, not two: a block is the smallest unit, and both headers *are* that block. This
    does not affect correctness of the emitted code — the Relooper works on blocks — but it means
    "loops: 20" is a count of distinct block headers, not of `loop` keywords in the source. The
    alternative (per-instruction loop identity) would add a second, finer graph that nothing consumes.
12. **Dead code is analysed, not executed.** A block reachable only through a branch that no path
    takes is still walked by the dominator and loop passes; what marks it is the DFS from the entry,
    not a separate liveness analysis. Blocks after `unreachable` are the common case.
13. **A partial body has no graph.** `disasm --cfg` prints `skipped: stopped at byte N ...` for the
    one SIMD helper instead of inventing blocks from half a function. The instruction listing still
    shows everything it decoded; only the graph refuses.

## 5. Reproduce every claim

```bash
bash script/check.sh
```

Every number quoted in the README or in the submission form must be reproducible by a command in
`script/`; otherwise it does not belong in the document. The script currently verifies: formatting,
three-target `moon check`, 95 unit tests on two targets, CLI usage paths, 8 fixtures decoded,
18 malformed fixtures rejected with code + offset (7 of them at the instruction layer, each
reporting the code written in its filename), byte-identical `info`, `disasm --ops` **and**
`disasm --cfg` output across `wasm-gc`, `js` and `wasm`, a graph for every fixture with no body
coming out irreducible, and a cross-check of every decoded mnemonic against wabt
(`4,386 matched, 0 mismatched, 62 not attempted`).
