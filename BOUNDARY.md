# BOUNDARY — what moonlift accepts, rejects, and does not promise

This file is normative. If the code and this document disagree, that is a bug in one of them.

Version: 0.1.0 (stage S0). Sections marked *(S10)* are filled in as the corresponding stage lands;
what is written below is already true of the shipped code.

---

## 1. Input subset

| Aspect | Accepted | Rejected | Code |
|---|---|---|---|
| Container | `\0asm` + version `1` | other magic / version | `E002`, `E003` |
| Sections | type(1), import(2), function(3), table(4), memory(5), global(6), export(7), start(8), element(9), code(10), data(11), datacount(12), custom(0, `name` only) | unknown section id | `E005` |
| Value types | `i32` `i64` `f32` `f64` | `v128`, `funcref`/`externref` outside tables | `E007` |
| Instructions | the 172 MVP opcodes + sign-extension (`0xFC 0x00–0x07`, switchable) | `0xFB`, `0xFD`, `0xFE`, exception opcodes, tail calls | `E006`, `E101`–`E105` |
| Memories | exactly one, 32-bit | `memory64`, multi-memory | `E106` |
| Imports | function imports only, surfaced as a `Host` trait whose default method traps | memory/table/global imports | `E107` |
| Control flow | reducible CFGs (covers what C/Rust compilers emit) | irreducible CFGs | `E108` |

**Status.** Only the container row is implemented today (S0 = taxonomy + CLI). Rows are the
contract for S3–S7, not a description of current capability.

## 2. Error codes

Frozen. Never renumbered; new codes are appended. `core/all_codes()` is the single source of truth
and a test asserts that the tags stay unique.

| Tag | Class | Meaning | Remedy |
|---|---|---|---|
| E001 | malformed | truncated input | file shorter than declared sizes |
| E002 | malformed | missing `\0asm` | not a wasm file |
| E003 | malformed | version != 1 | only binary format 1 |
| E004 | malformed | bad LEB128 | corrupt length/index |
| E005 | malformed | bad section | size or order inconsistent |
| E006 | malformed | bad opcode | outside the MVP set |
| E007 | malformed | bad value type | outside i32/i64/f32/f64 |
| E008 | malformed | index out of range | func/local/global/type/label |
| E009 | malformed | bad UTF-8 | name or import string |
| E010 | malformed | segment out of bounds | data/element range |
| E101 | unsupported | GC proposal | rebuild without reference types |
| E102 | unsupported | SIMD | disable auto-vectorisation |
| E103 | unsupported | threads/atomics | rebuild single-threaded |
| E104 | unsupported | exceptions | rebuild without EH |
| E105 | unsupported | tail calls | rebuild without sibling-call optimisation |
| E106 | unsupported | multi-memory / memory64 | single 32-bit memory |
| E107 | unsupported | non-function import | link memory/table/global statically |
| E108 | unsupported | irreducible CFG | see §4 |

Rule: **reject, never silently degrade.** Emitting code that compiles but computes the wrong value is
the one failure mode this project refuses to have.

## 3. Semantic deviations *(S10)*

Populated during S7. Each entry will state: deviation, reason, observable impact, and whether it is
acceptable for the declared subset. Expected first entries include `f32.nearest` rounding at exact
halves, `memory.grow` failure versus host limit, `select` on reference types, NaN payload
propagation, and the order of traps versus side effects.

## 4. Known limitations at 0.1.0

1. **No decompilation yet.** `info`, `decompile` and `verify` print "not implemented" and exit 2.
2. **native backend unverified.** This machine has no MSVC and `--target llvm` requires a nightly
   toolchain (`missing prelude.mi`). Verification therefore runs on `wasm`, `wasm-gc` and `js`.
   Installing VS Build Tools makes native available; it does not change any correctness criterion,
   because correctness is judged against a reference engine, not against a native build.
3. **No portable exit code.** MoonBit exposes no `exit()`; the CLI echoes `moonlift: exit N` and the
   scripts parse it. When a portable API appears, this note goes away.
4. **Nullary enum variants cannot be constructed across packages** in toolchain 0.1.20261020
   (`error 4036: cannot create values of the read-only type`). Tests for the taxonomy therefore live
   in `core/*_wbtest.mbt`. If the limitation is lifted, they can move to black-box tests.

## 5. Reproduce every claim

```bash
bash script/check.sh
```

Every number quoted in the README or in the submission form must be reproducible by a command in
`script/`; otherwise it does not belong in the document.
