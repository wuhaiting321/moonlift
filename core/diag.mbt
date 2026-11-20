///|
/// Stable error taxonomy. The numeric tag is what users see and what
/// `BOUNDARY.md` references, so these values are **frozen**: never renumber,
/// only append.
///
/// - `E0xx` — the input binary is malformed or unreadable.
/// - `E1xx` — the input is valid WebAssembly but outside the supported subset.
pub enum ErrorCode {
  E001Truncated // ran out of bytes while reading
  E002BadMagic // "\0asm" missing
  E003BadVersion // version field != 1
  E004BadLeb128 // LEB128 too long / non-canonical
  E005BadSection // section size or ordering invalid
  E006BadOpcode // opcode not in the MVP set
  E007BadType // value type / block type not supported
  E008BadIndex // index out of range (func / local / global / type / label)
  E009BadUtf8 // name section or import string is not valid UTF-8
  E010BadData // data / element segment out of bounds
  E101Gc // gc / struct / array proposal (0xFB)
  E102Simd // fixed-width SIMD (0xFD)
  E103Threads // atomics / shared memory (0xFE)
  E104Exceptions // exception handling opcodes
  E105TailCall // return_call / return_call_indirect
  E106MultiMemory // more than one memory, or memory64 flag
  E107NonFuncImport // memory / table / global import
  E108Irreducible // CFG cannot be structured
  E109BulkMemory // bulk-memory / passive segment constructs
  E110MultiTable // call_indirect / memory.size naming a second table or memory
  E111IndirectCall // indirect call through a table
}

///|
/// Every code in the taxonomy, in declaration order.
///
/// Exists for three reasons: `BOUNDARY.md` is generated from it, the
/// stability test walks it, and constructing each variant keeps the
/// `unused_constructor` lint honest instead of silenced.
pub fn all_codes() -> Array[ErrorCode] {
  [
    E001Truncated,
    E002BadMagic,
    E003BadVersion,
    E004BadLeb128,
    E005BadSection,
    E006BadOpcode,
    E007BadType,
    E008BadIndex,
    E009BadUtf8,
    E010BadData,
    E101Gc,
    E102Simd,
    E103Threads,
    E104Exceptions,
    E105TailCall,
    E106MultiMemory,
    E107NonFuncImport,
    E108Irreducible,
    E109BulkMemory,
    E110MultiTable,
    E111IndirectCall,
  ]
}

///|
/// The stable textual tag of an error code, e.g. `E101`.
pub fn ErrorCode::tag(self : ErrorCode) -> String {
  match self {
    E001Truncated => "E001"
    E002BadMagic => "E002"
    E003BadVersion => "E003"
    E004BadLeb128 => "E004"
    E005BadSection => "E005"
    E006BadOpcode => "E006"
    E007BadType => "E007"
    E008BadIndex => "E008"
    E009BadUtf8 => "E009"
    E010BadData => "E010"
    E101Gc => "E101"
    E102Simd => "E102"
    E103Threads => "E103"
    E104Exceptions => "E104"
    E105TailCall => "E105"
    E106MultiMemory => "E106"
    E107NonFuncImport => "E107"
    E108Irreducible => "E108"
    E109BulkMemory => "E109"
    E110MultiTable => "E110"
    E111IndirectCall => "E111"
  }
}

///|
/// Short human-readable class for an error code. The CLI prints this next to
/// the tag so a user can tell "your file is broken" from "your file is fine
/// but we refuse it".
pub fn ErrorCode::kind(self : ErrorCode) -> String {
  match self {
    E001Truncated
    | E002BadMagic
    | E003BadVersion
    | E004BadLeb128
    | E005BadSection
    | E006BadOpcode
    | E007BadType
    | E008BadIndex
    | E009BadUtf8
    | E010BadData => "malformed input"
    _ => "unsupported construct"
  }
}

///|
/// One-line remedy hint, printed by `moonlift info` on rejection.
pub fn ErrorCode::hint(self : ErrorCode) -> String {
  match self {
    E001Truncated => "file is shorter than its declared section sizes"
    E002BadMagic => "not a wasm file (missing \\0asm)"
    E003BadVersion => "only binary format version 1 is supported"
    E004BadLeb128 => "corrupt length or index encoding"
    E005BadSection => "section size or order is inconsistent"
    E006BadOpcode => "opcode outside the MVP instruction set"
    E007BadType => "value type outside i32/i64/f32/f64"
    E008BadIndex => "index points past the end of its table"
    E009BadUtf8 => "name or import string is not valid UTF-8"
    E010BadData => "segment range exceeds memory or table bounds"
    E101Gc =>
      "rebuild without the GC proposal (use -mno-reference-types style flags)"
    E102Simd => "rebuild without SIMD (disable auto-vectorisation)"
    E103Threads => "rebuild single-threaded (no shared memory, no atomics)"
    E104Exceptions => "rebuild without exception handling"
    E105TailCall => "rebuild without tail calls (-fno-optimize-sibling-calls)"
    E106MultiMemory => "rebuild with a single memory and 32-bit pointers"
    E107NonFuncImport =>
      "only function imports are supported; link memory/table/global statically"
    E108Irreducible => "structural jump into a loop body; see BOUNDARY.md"
    E109BulkMemory =>
      "rebuild without bulk-memory (passive segments, memory.copy/fill)"
    E110MultiTable => "only one table and one memory are supported"
    E111IndirectCall =>
      "a decompiled body cannot dispatch through a table; inline the call"
  }
}

///|
/// A diagnostic is always anchored to a byte offset in the input. Diagnostics
/// never carry a "line" because wasm binaries have no lines.
pub struct Diag {
  code : ErrorCode
  offset : Int32
  message : String
}

///|
pub fn Diag::new(code : ErrorCode, offset : Int32, message : String) -> Diag {
  { code, offset, message, }
}

///|
/// Canonical single-line form: `E004 at byte 137: ...`.
/// Stable enough to be asserted by snapshot tests.
pub fn Diag::render(self : Diag) -> String {
  "\{self.code.tag()} at byte \{self.offset}: \{self.message}"
}

///|
/// Full form used by the CLI: what, where, and what to do about it.
pub fn Diag::render_verbose(self : Diag) -> String {
  "\{self.render()}\n  hint: \{self.code.hint()}"
}

///|
/// Result type used by every decoder entry point.
pub type DecodeResult[T] = Result[T, Diag]
