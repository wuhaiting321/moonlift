///|
/// The instruction IR of the MVP subset.
///
/// Design decision worth stating up front, because it shapes every later stage:
/// **this is not a one-variant-per-opcode enum.** The 172 MVP opcodes collapse
/// into roughly forty distinct *shapes*, and the binary format groups them by
/// shape: `0x46..0x4F` are the ten i32 comparisons in a fixed order, `0x6A..0x78`
/// the fifteen i32 arithmetic operators, and so on. Two consequences:
///
/// 1. Decoding is range arithmetic against that layout, not a 172-entry table —
///    and a test asserts the ranges tile the opcode space exactly.
/// 2. The type rules become trivial and provable per shape: `Bin(ty, _)` pops
///    `ty, ty` and pushes `ty`; the only exception is a comparison, which pushes
///    `i32`, and that is a property of the *kind*, not of 76 separate cases.
///
/// The alternative — one variant per opcode — would put 76 near-identical arms
/// in the type checker, which is exactly where an unnoticed typo would produce
/// code that compiles and computes the wrong thing.

///|
/// A constant operand. Kept separate from `ConstExpr` (which also admits
/// `global.get`) so that "the value of this instruction" is always literally a
/// value: the type checker must never have to consult the globals table to know
/// what `i32.const` pushes.
pub enum ConstVal {
  I32V(Int32)
  I64V(Int64)
  F32V(UInt32)
  F64V(UInt64)
}

///|
pub fn ConstVal::ty(self : ConstVal) -> ValType {
  match self {
    I32V(_) => I32
    I64V(_) => I64
    F32V(_) => F32
    F64V(_) => F64
  }
}

///|
pub fn ConstVal::mnemonic(self : ConstVal) -> String {
  match self {
    I32V(_) => "i32.const"
    I64V(_) => "i64.const"
    F32V(_) => "f32.const"
    F64V(_) => "f64.const"
  }
}

///|
/// The operand as written in `.wat`.
///
/// Floats are printed as raw bit patterns, not as decimals. Two reasons: the
/// decompiler must reproduce the exact bits (`0.1` as f32 is not `0.1`), and
/// decimal formatting of NaN payloads is not round-trippable at all.
pub fn ConstVal::operand(self : ConstVal) -> String {
  match self {
    I32V(v) => "\{v}"
    I64V(v) => "\{v}"
    F32V(bits) => "0x\{hex_fixed(bits.to_uint64(), 8)}"
    F64V(bits) => "0x\{hex_fixed(bits, 16)}"
  }
}

///|
/// Convert a constant expression, if it is one. `global.get` is not a constant
/// value and yields `None`.
pub fn ConstExpr::as_const(self : ConstExpr) -> ConstVal? {
  match self {
    I32Const(v) => Some(I32V(v))
    I64Const(v) => Some(I64V(v))
    F32Const(bits) => Some(F32V(bits))
    F64Const(bits) => Some(F64V(bits))
    GlobalGet(_) => None
  }
}

///|
/// The result type of a block, loop or `if`.
///
/// `TypeIdx` carries a positive s33 type index, which is how the multi-value
/// proposal encodes "this block returns three values". Decoded but never
/// generated — see `BOUNDARY.md`.
pub enum BlockType {
  Empty
  Value(ValType)
  TypeIdx(Int32)
}

///|
/// `""`, `" (result i32)"`, `" (type 3)"`.
pub fn BlockType::render(self : BlockType) -> String {
  match self {
    Empty => ""
    Value(t) => " (result \{t.name()})"
    TypeIdx(i) => " (type \{i})"
  }
}

///|
/// The canary for "the code generator cannot reproduce this block": multi-value
/// blocks exist precisely to return more than MoonBit's `if`/`while` can.
pub fn BlockType::is_generatable(self : BlockType) -> Bool {
  match self {
    TypeIdx(_) => false
    _ => true
  }
}

///|
/// One `load` or `store`, fully describing the opcode.
///
/// `width` is the access width in bytes (1, 2, 4 or 8) and is *not* the same as
/// `ty.byte_size()`: `i32.load8_s` accesses one byte and pushes an i32. Keeping
/// all six fields means the mnemonic, the stack effect and the emitted MoonBit
/// expression are all computed from one record instead of being re-derived in
/// three places.
pub struct MemOp {
  /// Value type loaded or stored.
  ty : ValType
  /// Access width in bytes.
  width : Int32
  /// Extension applied by a narrow load. Always false for stores.
  signed : Bool
  /// True for `store`, false for `load`.
  store : Bool
  /// Alignment exponent exactly as encoded (0 means byte-aligned).
  align : Int32
  /// Static offset added to the dynamic address.
  offset : UInt32
}

///|
pub fn MemOp::new(
  ty : ValType,
  width : Int32,
  signed : Bool,
  store : Bool,
  align : Int32,
  offset : UInt32,
) -> MemOp {
  { ty, width, signed, store, align, offset, }
}

///|
/// `i32.load`, `i64.load32_s`, `i32.store8`, `f64.store`.
///
/// Generated from the fields rather than stored, so that the 23 memory opcodes
/// cannot drift from their mnemonics: a test round-trips all 23.
pub fn MemOp::mnemonic(self : MemOp) -> String {
  let base = self.ty.name()
  let full = self.ty.byte_size()
  if self.store {
    if self.width == full {
      "\{base}.store"
    } else {
      "\{base}.store\{self.width * 8}"
    }
  } else if self.width == full {
    "\{base}.load"
  } else {
    let sign = if self.signed { "_s" } else { "_u" }
    "\{base}.load\{self.width * 8}\{sign}"
  }
}

///|
/// Natural alignment exponent of this access: the value a producer is allowed to
/// use without an explicit `align=` hint.
pub fn MemOp::natural_align(self : MemOp) -> Int32 {
  match self.width {
    1 => 0
    2 => 1
    4 => 2
    _ => 3
  }
}

///|
/// Fully-rendered memory operand: `offset=16 align=1`, matching wabt's spelling
/// so that a diff against `wasm2wat` output is readable.
pub fn MemOp::operands(self : MemOp) -> String {
  let a = 1 << self.align
  "offset=\{self.offset} align=\{a}"
}

///|
/// Unary numeric operators.
///
/// `Eqz` is here rather than among the comparisons because it takes one operand
/// and returns i32 — the same shape as `clz`, not the same shape as `eq`.
/// The sign-extension trio is unary on a fixed width (`i32.extend8_s` maps
/// i32 to i32), so it needs no separate shape either.
pub enum UnKind {
  Eqz
  Clz
  Ctz
  Popcnt
  Abs
  Neg
  Ceil
  Floor
  Trunc
  Nearest
  Sqrt
  Extend8S
  Extend16S
  Extend32S
}

///|
pub fn UnKind::suffix(self : UnKind) -> String {
  match self {
    Eqz => "eqz"
    Clz => "clz"
    Ctz => "ctz"
    Popcnt => "popcnt"
    Abs => "abs"
    Neg => "neg"
    Ceil => "ceil"
    Floor => "floor"
    Trunc => "trunc"
    Nearest => "nearest"
    Sqrt => "sqrt"
    Extend8S => "extend8_s"
    Extend16S => "extend16_s"
    Extend32S => "extend32_s"
  }
}

///|
/// Binary numeric operators.
///
/// `LtS`/`LtU` carry signedness; for the float types only the ordered variants
/// exist, and the mnemonic drops the suffix (`f32.lt`, not `f32.lt_s`). That is
/// a rendering rule, not a semantic one — see `BinKind::render`.
pub enum BinKind {
  Eq
  Ne
  LtS
  LtU
  GtS
  GtU
  LeS
  LeU
  GeS
  GeU
  Add
  Sub
  Mul
  DivS
  DivU
  RemS
  RemU
  And
  Or
  Xor
  Shl
  ShrS
  ShrU
  Rotl
  Rotr
  Min
  Max
  Copysign
}

///|
/// `lt_s` for the integer types, `lt` for the float types — hence the `ty`
/// parameter on `bin_mnemonic` below. The suppression is only sound because the
/// decoder never produces `LtU` for a float: there is no `f32.lt_u` opcode to
/// produce it from.
pub fn BinKind::suffix(self : BinKind) -> String {
  match self {
    Eq => "eq"
    Ne => "ne"
    LtS => "lt_s"
    LtU => "lt_u"
    GtS => "gt_s"
    GtU => "gt_u"
    LeS => "le_s"
    LeU => "le_u"
    GeS => "ge_s"
    GeU => "ge_u"
    Add => "add"
    Sub => "sub"
    Mul => "mul"
    DivS => "div_s"
    DivU => "div_u"
    RemS => "rem_s"
    RemU => "rem_u"
    And => "and"
    Or => "or"
    Xor => "xor"
    Shl => "shl"
    ShrS => "shr_s"
    ShrU => "shr_u"
    Rotl => "rotl"
    Rotr => "rotr"
    Min => "min"
    Max => "max"
    Copysign => "copysign"
  }
}

///|
/// True when the operator is a comparison: it pops two operands of `ty` and
/// pushes an i32. This single predicate replaces ten `i32.*` and six `f32.*`
/// special cases in the type checker.
pub fn BinKind::is_comparison(self : BinKind) -> Bool {
  match self {
    Eq | Ne | LtS | LtU | GtS | GtU | LeS | LeU | GeS | GeU => true
    _ => false
  }
}

///|
/// How a value is converted from one type to another.
///
/// `TruncSatS` / `TruncSatU` are the non-trapping saturating variants
/// (`0xFC 0..7`), which is the only reason bulk-memory's prefix carries numeric
/// instructions at all.
pub enum ConvMode {
  Wrap
  TruncS
  TruncU
  TruncSatS
  TruncSatU
  ExtendS
  ExtendU
  ConvertS
  ConvertU
  Demote
  Promote
  Reinterpret
}

///|
/// The `<op>_<from>` tail of a conversion mnemonic, e.g. `trunc_f64_s`.
pub fn ConvMode::suffix(self : ConvMode, from : ValType) -> String {
  let f = from.name()
  match self {
    Wrap => "wrap_i64"
    TruncS => "trunc_\{f}_s"
    TruncU => "trunc_\{f}_u"
    TruncSatS => "trunc_sat_\{f}_s"
    TruncSatU => "trunc_sat_\{f}_u"
    ExtendS => "extend_\{f}_s"
    ExtendU => "extend_\{f}_u"
    ConvertS => "convert_\{f}_s"
    ConvertU => "convert_\{f}_u"
    Demote => "demote_f64"
    Promote => "promote_f32"
    Reinterpret => "reinterpret_\{f}"
  }
}

///|
/// Bulk-memory instructions reached through the `0xFC` prefix.
///
/// Decoded because they are one LEB away from being understandable, refused by
/// the code generator because a decompiled function cannot reproduce a passive
/// segment copy. The distinction matters: `info` and `disasm` stay useful on a
/// module that `decompile` will reject with `E109`.
pub enum MiscOp {
  MemoryInit(Int32)
  DataDrop(Int32)
  MemoryCopy
  MemoryFill
}

///|
pub fn MiscOp::render(self : MiscOp) -> String {
  match self {
    MemoryInit(x) => "memory.init \{x}"
    DataDrop(x) => "data.drop \{x}"
    MemoryCopy => "memory.copy"
    MemoryFill => "memory.fill"
  }
}

///|
/// The full mnemonic of a binary operator: `i32.lt_s` but `f32.lt`, `i32.div_s`
/// but `f32.div`.
///
/// Four comparison kinds and `DivS` are exactly the set that carries a
/// signedness suffix in the integer spelling and none in the float spelling,
/// because the float types have no unsigned form at all. `fbin_kind` produces
/// `DivS` for `f32.div` — one binary operator shared by both families — so the
/// suppression has to live here, once, rather than in the decoder or in every
/// emitter.
pub fn bin_mnemonic(ty : ValType, k : BinKind) -> String {
  match ty {
    F32 | F64 =>
      match k {
        LtS => "\{ty.name()}.lt"
        GtS => "\{ty.name()}.gt"
        LeS => "\{ty.name()}.le"
        GeS => "\{ty.name()}.ge"
        DivS => "\{ty.name()}.div"
        _ => "\{ty.name()}.\{k.suffix()}"
      }
    _ => "\{ty.name()}.\{k.suffix()}"
  }
}

///|
/// One decoded instruction.
///
/// `Const` carries a value, not an index; `Mem` carries the whole access
/// description; `Call` carries a function index resolved later against the
/// module's index space. Nothing here refers to the byte stream — that is the
/// point of having an IR at all.
pub enum Instr {
  Unreachable
  Nop
  Block(BlockType)
  Loop(BlockType)
  If(BlockType)
  Else
  End
  Br(Int32)
  BrIf(Int32)
  BrTable(Array[Int32], Int32)
  Return
  Call(Int32)
  CallIndirect(Int32)
  Drop
  Select
  LocalGet(Int32)
  LocalSet(Int32)
  LocalTee(Int32)
  GlobalGet(Int32)
  GlobalSet(Int32)
  Mem(MemOp)
  MemorySize
  MemoryGrow
  Const(ConstVal)
  Un(ValType, UnKind)
  Bin(ValType, BinKind)
  Conv(ValType, ValType, ConvMode)
  Misc(MiscOp)
}

///|
/// The `.wat` mnemonic, without operands.
pub fn Instr::mnemonic(self : Instr) -> String {
  match self {
    Unreachable => "unreachable"
    Nop => "nop"
    Block(_) => "block"
    Loop(_) => "loop"
    If(_) => "if"
    Else => "else"
    End => "end"
    Br(_) => "br"
    BrIf(_) => "br_if"
    BrTable(_, _) => "br_table"
    Return => "return"
    Call(_) => "call"
    CallIndirect(_) => "call_indirect"
    Drop => "drop"
    Select => "select"
    LocalGet(_) => "local.get"
    LocalSet(_) => "local.set"
    LocalTee(_) => "local.tee"
    GlobalGet(_) => "global.get"
    GlobalSet(_) => "global.set"
    Mem(op) => op.mnemonic()
    MemorySize => "memory.size"
    MemoryGrow => "memory.grow"
    Const(c) => c.mnemonic()
    Un(ty, k) => "\{ty.name()}.\{k.suffix()}"
    Bin(ty, k) => bin_mnemonic(ty, k)
    Conv(to, from, mode) => "\{to.name()}.\{mode.suffix(from)}"
    Misc(m) => m.render()
  }
}

///|
/// Mnemonic plus operands, one line, exactly as `.wat` would spell it.
pub fn Instr::render(self : Instr) -> String {
  let m = self.mnemonic()
  match self {
    Block(bt) | Loop(bt) | If(bt) => m + bt.render()
    Br(n) | BrIf(n) | Call(n) => "\{m} \{n}"
    CallIndirect(t) => "\{m} (type \{t})"
    BrTable(labels, default) => {
      let b = StringBuilder()
      b.write_string(m)
      for l in labels {
        b.write_string(" \{l}")
      }
      b.write_string(" \{default}")
      b.to_string()
    }
    LocalGet(i) | LocalSet(i) | LocalTee(i) => "\{m} \{i}"
    GlobalGet(i) | GlobalSet(i) => "\{m} \{i}"
    Mem(op) => "\{m} \{op.operands()}"
    Const(c) => "\{m} \{c.operand()}"
    _ => m
  }
}

///|
/// One instruction plus the byte offset it started at. Offsets are absolute in
/// the input file, which is what makes a decoder bug reproducible: "i32.add at
/// byte 4711" can be found in a hex dump, "instruction 63" cannot.
pub struct InstrRef {
  offset : Int32
  instr : Instr
}

///|
pub fn InstrRef::new(offset : Int32, instr : Instr) -> InstrRef {
  { offset, instr, }
}
