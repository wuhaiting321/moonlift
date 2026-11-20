///|
/// The four MVP numeric value types, plus `v128`.
///
/// `v128` is *recognised but never generated*. It is here because MoonBit's own
/// wasm backend emits it inside its memcpy/memset helpers, and a structure dump
/// that refuses a 20 KB module outright is less useful than one that says
/// "these three signatures use v128, code generation will refuse them".
///
/// Reference types (`funcref` / `externref`) are still rejected at decode time
/// with `E101`: unlike `v128`, they change what a *call* means (a reference has
/// no MoonBit representation at all), so accepting them would mislead.
///
/// The design rule this encodes: **parse broadly, generate narrowly, reject at
/// the point of generation.** Refusals belong where the information loss
/// happens, not at the container layer.
pub enum ValType {
  I32
  I64
  F32
  F64
  V128
}

///|
/// Binary name, identical to the spec spelling and to the MoonBit-free surface
/// syntax used in `info` output and in diagnostics.
pub fn ValType::name(self : ValType) -> String {
  match self {
    I32 => "i32"
    I64 => "i64"
    F32 => "f32"
    F64 => "f64"
    V128 => "v128"
  }
}

///|
/// Width of one value of this type when stored in linear memory. Drives the
/// natural alignment of `load` / `store` in later stages.
pub fn ValType::byte_size(self : ValType) -> Int32 {
  match self {
    I32 | F32 => 4
    I64 | F64 => 8
    V128 => 16
  }
}

///|
/// The MoonBit type a value of this wasm type maps to.
///
/// This mapping is the reason the project is possible at all: on every backend
/// we target, MoonBit's `Int` *is* a 32-bit integer with wrapping arithmetic,
/// `Float` is f32 and `Double` is f64. No emulation layer, no boxing.
pub fn ValType::moonbit_type(self : ValType) -> String {
  match self {
    I32 => "Int"
    I64 => "Int64"
    F32 => "Float"
    F64 => "Double"
    // No MoonBit type corresponds to v128, and none is needed: a function with
    // a v128 parameter is refused before this mapping is ever consulted.
    V128 => "v128"
  }
}

///|
/// True for types the code generator cannot express. `info` reports the count so
/// a user knows before running `decompile` which functions will be refused.
pub fn ValType::is_generatable(self : ValType) -> Bool {
  match self {
    V128 => false
    _ => true
  }
}

///|
/// A function signature: a parameter list and a result list.
///
/// `results` is an array rather than an `Option` because the binary format
/// allows several results, and MoonBit's own wasm backend emits them. Decoding
/// them costs nothing here; refusing them is a *code generation* decision, and
/// it is made where it can be reported per function instead of per module.
pub struct FuncType {
  params : Array[ValType]
  results : Array[ValType]
}

///|
pub fn FuncType::new(
  params : Array[ValType],
  results : Array[ValType],
) -> FuncType {
  { params, results, }
}

///|
pub fn FuncType::param_count(self : FuncType) -> Int32 {
  self.params.length()
}

///|
pub fn FuncType::result_count(self : FuncType) -> Int32 {
  self.results.length()
}

///|
/// True when the signature needs the multi-value proposal (more than one
/// result). MVP alone allows zero or one.
pub fn FuncType::is_multi_value(self : FuncType) -> Bool {
  self.results.length() > 1
}

///|
/// True when any parameter or result is a type the code generator cannot emit.
pub fn FuncType::has_unsupported_type(self : FuncType) -> Bool {
  let mut bad = false
  for t in self.params {
    if !t.is_generatable() {
      bad = true
    }
  }
  for t in self.results {
    if !t.is_generatable() {
      bad = true
    }
  }
  bad
}

///|
/// `(i32, i32) -> i32`, `() -> ()`, `(f64) -> (i32, i32)`.
pub fn FuncType::signature(self : FuncType) -> String {
  let b = StringBuilder()
  b.write_string("(")
  let mut i = 0
  while i < self.params.length() {
    if i > 0 {
      b.write_string(", ")
    }
    b.write_string(self.params[i].name())
    i = i + 1
  }
  b.write_string(") -> ")
  if self.results.length() == 0 {
    b.write_string("()")
  } else if self.results.length() == 1 {
    b.write_string(self.results[0].name())
  } else {
    b.write_string("(")
    let mut j = 0
    while j < self.results.length() {
      if j > 0 {
        b.write_string(", ")
      }
      b.write_string(self.results[j].name())
      j = j + 1
    }
    b.write_string(")")
  }
  b.to_string()
}

///|
/// `FuncType::signature` from a nullable type index, for call sites that may
/// point at a function whose type was never resolved. Never panics.
pub fn signature_of(t : FuncType?) -> String {
  match t {
    Some(ft) => ft.signature()
    None => "(?) -> (?)"
  }
}

///|
/// Sort of an import or export. The wasm external kinds, numbered as in the
/// binary format: 0 func, 1 table, 2 memory, 3 global.
pub enum ExternalKind {
  FuncKind
  TableKind
  MemoryKind
  GlobalKind
}

///|
pub fn ExternalKind::name(self : ExternalKind) -> String {
  match self {
    FuncKind => "func"
    TableKind => "table"
    MemoryKind => "memory"
    GlobalKind => "global"
  }
}

///|
/// Index in `Array[ExternalKind]` form for `info` summaries: one slot per kind.
/// Avoids a hash map for four entries.
pub fn ExternalKind::slot(self : ExternalKind) -> Int32 {
  match self {
    FuncKind => 0
    TableKind => 1
    MemoryKind => 2
    GlobalKind => 3
  }
}

///|
/// A compiled-in constant expression, as allowed in global initialisers,
/// element/memory offsets and (later) `ref` constructs.
///
/// Floats are kept as raw bits: a constant is a bit pattern, and round-tripping
/// `NaN` or a subnormal through decimal text loses information that the
/// generated MoonBit source would then carry forever.
pub enum ConstExpr {
  I32Const(Int32)
  I64Const(Int64)
  F32Const(UInt32)
  F64Const(UInt64)
  GlobalGet(Int32)
}

///|
/// One byte as two hex digits, for diagnostics that name a tag or opcode.
///
/// Decimal would be actively misleading here: `opcode 0x32` is how a reader says
/// "0x32", and printing 50 as `0x32` is both wrong and confusing. Every byte
/// value in a diagnostic goes through this.
fn hex_u8(v : UInt32) -> String {
  hex_fixed(v.to_uint64(), 2)
}

///|
/// Uppercase-free hex with a fixed width, zero padded.
///
/// Written by hand because core has no `to_hex`, and because the width is the
/// point: a float constant is only meaningful when its bit pattern is printed
/// at full width (`0x3f800000`, not `0x3f8`).
fn hex_fixed(v : UInt64, digits : Int32) -> String {
  let s = v.to_string(radix=16)
  if s.length() >= digits {
    s
  } else {
    "0".repeat(digits - s.length()) + s
  }
}

///|
/// Source-like rendering of a constant, used by `info` and later by the code
/// generator when materialising initialisers.
pub fn ConstExpr::render(self : ConstExpr) -> String {
  match self {
    I32Const(v) => "i32.const \{v}"
    I64Const(v) => "i64.const \{v}"
    F32Const(bits) => "f32.const 0x\{hex_fixed(bits.to_uint64(), 8)}"
    F64Const(bits) => "f64.const 0x\{hex_fixed(bits, 16)}"
    GlobalGet(i) => "global.get \{i}"
  }
}

///|
/// True when the expression yields an i32 at run time. Only `global.get` is
/// uncertain, and only because the global's own type lives elsewhere — callers
/// that care check the global table themselves.
pub fn ConstExpr::is_known_i32(self : ConstExpr) -> Bool {
  match self {
    I32Const(_) => true
    GlobalGet(_) => true
    _ => false
  }
}

///|
/// Resizable limits, shared by table and memory declarations.
///
/// `has_max` is a separate flag instead of `Option[UInt32]` so that the common
/// "no maximum" case needs no allocation and prints without a `match`.
pub struct Limits {
  min : UInt32
  max : UInt32
  has_max : Bool
}

///|
pub fn Limits::new(min : UInt32, max : UInt32, has_max : Bool) -> Limits {
  { min, max, has_max, }
}

///|
/// `min=1`, or `min=1, max=7`.
pub fn Limits::render(self : Limits) -> String {
  if self.has_max {
    "min=\{self.min}, max=\{self.max}"
  } else {
    "min=\{self.min}, no max"
  }
}
