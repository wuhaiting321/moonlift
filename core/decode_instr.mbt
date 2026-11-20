///|
/// Instruction decoding: bytes in, IR out.
///
/// This is the stage where the byte stream stops being opaque. Three properties
/// are maintained throughout, and they are the reason the later stages can be
/// written without defensive re-checking:
///
/// 1. **Every instruction carries its own byte offset.** Not the offset of the
///    function, not the index in the array — the offset of the opcode byte. A
///    decompiler that cannot say "this `i32.div_s` is at byte 4711" cannot be
///    debugged on real input.
///
/// 2. **Structure is validated while decoding, not afterwards.** Label depth,
///    `else` placement, the function-final `end`, and index bounds against the
///    module's tables are all checked here, because this is the only place that
///    knows the byte offset of the offending token.
///
/// 3. **Unknown *lengths* stop the decode; unknown *values* do not.** An opcode
///    whose operand size we do not know (`0xFD` SIMD, `0xFE` atomics) cannot be
///    skipped, so decoding stops and the body is marked partial. An opcode we
///    fully understand but cannot generate (bulk memory, indirect calls) is
///    decoded normally and refused later, at the point of generation.

///|
/// The module-level tables an instruction body is checked against.
///
/// Passed explicitly instead of taking a `Module`, so that the decoder can be
/// unit-tested on four bytes without fabricating a whole module, and so that the
/// list of things it depends on is visible in the signature rather than implied.
pub struct BodyCtx {
  /// Parameters plus declared locals: the size of the local index space.
  locals : Int32
  /// Number of globals, including any imported ones.
  globals : Int32
  /// Number of functions in the unified index space (imports first).
  funcs : Int32
  /// Number of entries in the type table.
  types : Int32
}

///|
pub fn BodyCtx::new(
  locals : Int32,
  globals : Int32,
  funcs : Int32,
  types : Int32,
) -> BodyCtx {
  { locals, globals, funcs, types, }
}

///|
/// A decoded function body.
///
/// `complete` is false when decoding stopped at an opcode whose operand length
/// is unknown. In that case `stop_op` / `stop_sub` / `stop_offset` describe the
/// exact byte where understanding ended — the difference between "we gave up
/// here" and "the file is broken", which a user needs in order to act.
pub struct DecodedBody {
  instrs : Array[InstrRef]
  complete : Bool
  stop_offset : Int32
  stop_op : Int32
  stop_sub : Int32
}

///|
pub fn DecodedBody::len(self : DecodedBody) -> Int32 {
  self.instrs.length()
}

///|
/// True when the body decoded completely. Bodies that are not complete are
/// refused by the code generator with the offset recorded here.
pub fn DecodedBody::is_complete(self : DecodedBody) -> Bool {
  self.complete
}

///|
/// `stopped at byte 4711: 0xfd/0x0b (simd)`, or `""` when nothing was skipped.
pub fn DecodedBody::stop_note(self : DecodedBody) -> String {
  if self.complete {
    return ""
  }
  let family = match self.stop_op {
    0xFD => "simd"
    0xFE => "atomics"
    _ => "unknown prefix"
  }
  let op = hex_fixed(self.stop_op.reinterpret_as_uint().to_uint64(), 2)
  let sub = hex_fixed(self.stop_sub.reinterpret_as_uint().to_uint64(), 2)
  "stopped at byte \{self.stop_offset}: 0x\{op}/0x\{sub} (\{family})"
}

// --- small lookup tables -------------------------------------------------
//
// Written as matches on a small index rather than as module-level arrays: a
// `match` on `0..14` compiles to a jump table with no allocation, and it keeps
// the enumeration in one screen where a missing case is obvious. The opcode
// layout these mirror is fixed by the spec and asserted in the tests.

///|
fn cmp_kind(i : Int32) -> BinKind {
  match i {
    0 => Eq
    1 => Ne
    2 => LtS
    3 => LtU
    4 => GtS
    5 => GtU
    6 => LeS
    7 => LeU
    8 => GeS
    _ => GeU
  }
}

///|
/// The six ordered float comparisons. There is no `_u` form because NaN is
/// unordered rather than unsigned.
fn fcmp_kind(i : Int32) -> BinKind {
  match i {
    0 => Eq
    1 => Ne
    2 => LtS
    3 => GtS
    4 => LeS
    _ => GeS
  }
}

///|
fn arith_kind(i : Int32) -> BinKind {
  match i {
    0 => Add
    1 => Sub
    2 => Mul
    3 => DivS
    4 => DivU
    5 => RemS
    6 => RemU
    7 => And
    8 => Or
    9 => Xor
    10 => Shl
    11 => ShrS
    12 => ShrU
    13 => Rotl
    _ => Rotr
  }
}

///|
fn fbin_kind(i : Int32) -> BinKind {
  match i {
    0 => Add
    1 => Sub
    2 => Mul
    3 => DivS
    4 => Min
    5 => Max
    _ => Copysign
  }
}

///|
fn i32_un_kind(i : Int32) -> UnKind {
  match i {
    0 => Clz
    1 => Ctz
    _ => Popcnt
  }
}

///|
fn f_un_kind(i : Int32) -> UnKind {
  match i {
    0 => Abs
    1 => Neg
    2 => Ceil
    3 => Floor
    4 => Trunc
    5 => Nearest
    _ => Sqrt
  }
}

///|
/// `0xA7..0xBF`, the 25 conversion opcodes, in one table.
///
/// The return is `(to, from, mode)` in that order because every consumer reads
/// it that way: the result type first (it determines the stack effect), then the
/// operand type, then how to compute it.
fn conv_of(op : UInt32) -> (ValType, ValType, ConvMode) {
  match op {
    0xA7U => (I32, I64, Wrap)
    0xA8U => (I32, F32, TruncS)
    0xA9U => (I32, F32, TruncU)
    0xAAU => (I32, F64, TruncS)
    0xABU => (I32, F64, TruncU)
    0xACU => (I64, I32, ExtendS)
    0xADU => (I64, I32, ExtendU)
    0xAEU => (I64, F32, TruncS)
    0xAFU => (I64, F32, TruncU)
    0xB0U => (I64, F64, TruncS)
    0xB1U => (I64, F64, TruncU)
    0xB2U => (F32, I32, ConvertS)
    0xB3U => (F32, I32, ConvertU)
    0xB4U => (F32, I64, ConvertS)
    0xB5U => (F32, I64, ConvertU)
    0xB6U => (F32, F64, Demote)
    0xB7U => (F64, I32, ConvertS)
    0xB8U => (F64, I32, ConvertU)
    0xB9U => (F64, I64, ConvertS)
    0xBAU => (F64, I64, ConvertU)
    0xBBU => (F64, F32, Promote)
    0xBCU => (I32, F32, Reinterpret)
    0xBDU => (I64, F64, Reinterpret)
    0xBEU => (F32, I32, Reinterpret)
    // 0xBF
    _ => (F64, I64, Reinterpret)
  }
}

///|
/// One `0xFC` sub-opcode as a conversion: the eight saturating truncations.
///
/// `sub` is 0..7 here. `sub % 4 < 2` selects f32 (sub 0,1,4,5) versus f64
/// (2,3,6,7); `sub < 4` selects an i32 result; odd `sub` is the unsigned form.
/// Derived rather than tabulated because a table of eight would be eight chances
/// to mistype the same pattern.
fn trunc_sat_of(sub : Int32) -> (ValType, ValType, ConvMode) {
  let to = if sub < 4 { I32 } else { I64 }
  let from = if sub % 4 < 2 { F32 } else { F64 }
  let mode = if sub % 2 == 0 { TruncSatS } else { TruncSatU }
  (to, from, mode)
}

// --- operand readers -----------------------------------------------------

///|
/// A block type: the single byte `0x40` (no result), a value type byte, or a
/// positive s33 type index.
///
/// The ambiguity is only apparent. `0x7B` read as an s33 is -5, and -5 *is* the
/// v128 type code; a positive type index 123 cannot be encoded as the single byte
/// `0x7B` because that byte's bit 6 is set, which makes it negative. So looking
/// at the first byte alone is sound — and it avoids a lookahead-LEB dance that
/// would be easy to get subtly wrong.
fn read_block_type(r : Reader, base : Int32) -> BlockType raise ReadFail {
  let at = base + r.position()
  match r.peek_u8() {
    None => fail_at(at, E001Truncated, "function body ends before a block type")
    Some(b) => {
      let u = b.to_uint()
      if u == 0x40U {
        r.skip(1)
        Empty
      } else if u == 0x7FU {
        r.skip(1)
        Value(I32)
      } else if u == 0x7EU {
        r.skip(1)
        Value(I64)
      } else if u == 0x7DU {
        r.skip(1)
        Value(F32)
      } else if u == 0x7CU {
        r.skip(1)
        Value(F64)
      } else if u == 0x7BU {
        r.skip(1)
        Value(V128)
      } else {
        let v = r.s32_leb()
        if v < 0 {
          fail_at(
            at,
            E007BadType,
            "block type \{v} is neither a value type nor a type index",
          )
        }
        TypeIdx(v)
      }
    }
  }
}

///|
/// A `memarg`: alignment exponent then static offset, both LEB128.
///
/// The alignment is validated against the natural alignment of the access.
/// Over-alignment is a spec violation that some producers emit as a *hint*, and
/// accepting it would mean the generated code silently reads misaligned words;
/// rejecting it with both numbers quoted is the honest option.
fn read_memop(
  r : Reader,
  base : Int32,
  ty : ValType,
  width : Int32,
  signed : Bool,
  store : Bool,
) -> MemOp raise ReadFail {
  let at = base + r.position()
  let align = r.u32_leb()
  let offset = r.u32_leb()
  let op = MemOp::new(
    ty,
    width,
    signed,
    store,
    align.reinterpret_as_int(),
    offset,
  )
  if op.align < 0 || op.align > op.natural_align() {
    fail_at(
      at,
      E007BadType,
      "\{op.mnemonic()} alignment hint 2^\{op.align} exceeds the natural 2^\{op.natural_align()}",
    )
  }
  op
}

// --- the decoder ---------------------------------------------------------

///|
/// Decode a function body into IR.
///
/// The body bytes exclude local declarations (S2 stripped them) and include the
/// final `end`, which is also the last instruction.
pub fn decode_body(code : Code, ctx : BodyCtx) -> DecodedBody raise ReadFail {
  let base = code.body_offset
  let r = Reader::new(code.body)
  let instrs : Array[InstrRef] = []
  // One label for the implicit function block, plus one per open block. A `br`
  // is valid when its depth is strictly less than this.
  let mut labels : Int32 = 1
  // Kind of each open block: 0 block, 1 loop, 2 if, 3 if-with-else. The bottom
  // entry is the function body itself, which behaves like a block.
  let kinds : Array[Int32] = [0]
  let mut complete = true
  let mut stop_offset : Int32 = 0
  let mut stop_op : Int32 = 0
  let mut stop_sub : Int32 = 0
  let mut running = true
  while running {
    if r.at_end() {
      fail_at(
        base + r.position(),
        E001Truncated,
        "function body ends without the closing 'end'",
      )
    }
    let at = base + r.position()
    let op = r.u8().to_uint()
    let instr = if op == 0x20U {
      let i = r.u32_leb().reinterpret_as_int()
      check_index(at, i, ctx.locals, "local")
      LocalGet(i)
    } else if op == 0x21U {
      let i = r.u32_leb().reinterpret_as_int()
      check_index(at, i, ctx.locals, "local")
      LocalSet(i)
    } else if op == 0x22U {
      let i = r.u32_leb().reinterpret_as_int()
      check_index(at, i, ctx.locals, "local")
      LocalTee(i)
    } else if op >= 0x45U && op <= 0xC4U {
      decode_numeric(op)
    } else {
      match op {
        0x00U => Unreachable
        0x01U => Nop
        0x02U => {
          let bt = read_block_type(r, base)
          labels = labels + 1
          kinds.push(0)
          Block(bt)
        }
        0x03U => {
          let bt = read_block_type(r, base)
          labels = labels + 1
          kinds.push(1)
          Loop(bt)
        }
        0x04U => {
          let bt = read_block_type(r, base)
          labels = labels + 1
          kinds.push(2)
          If(bt)
        }
        0x05U => {
          let k = kinds[kinds.length() - 1]
          if k != 2 {
            fail_at(at, E006BadOpcode, "'else' outside an 'if' block")
          }
          kinds[kinds.length() - 1] = 3
          Else
        }
        0x0BU => {
          labels = labels - 1
          if labels == 0 {
            // The function's own `end`. Anything after it is unreachable and,
            // more importantly, means the body length disagrees with its
            // contents — a class of corruption worth naming precisely.
            if !r.at_end() {
              fail_at(
                base + r.position(),
                E005BadSection,
                "\{r.remaining()} byte(s) after the function's closing 'end'",
              )
            }
            running = false
          } else {
            let _ = kinds.pop()
          }
          End
        }
        0x0CU => {
          let n = r.u32_leb().reinterpret_as_int()
          check_label(at, n, labels)
          Br(n)
        }
        0x0DU => {
          let n = r.u32_leb().reinterpret_as_int()
          check_label(at, n, labels)
          BrIf(n)
        }
        0x0EU => {
          let count = vec_count(r, 1, "br_table label")
          let ls : Array[Int32] = []
          let mut i = 0
          while i < count {
            let n = r.u32_leb().reinterpret_as_int()
            check_label(at, n, labels)
            ls.push(n)
            i = i + 1
          }
          let d = r.u32_leb().reinterpret_as_int()
          check_label(at, d, labels)
          BrTable(ls, d)
        }
        0x0FU => Return
        0x10U => {
          let f = r.u32_leb().reinterpret_as_int()
          check_index(at, f, ctx.funcs, "function")
          Call(f)
        }
        0x11U => {
          let t = r.u32_leb().reinterpret_as_int()
          check_index(at, t, ctx.types, "type")
          let table = r.u32_leb()
          if table != 0U {
            fail_at(
              at,
              E110MultiTable,
              "call_indirect names table \{table}; only a single table is supported",
            )
          }
          CallIndirect(t)
        }
        0x1AU => Drop
        0x1BU => Select
        0x1CU =>
          fail_at(
            at,
            E007BadType,
            "typed 'select' needs the reference-types proposal",
          )
        0x23U => {
          let i = r.u32_leb().reinterpret_as_int()
          check_index(at, i, ctx.globals, "global")
          GlobalGet(i)
        }
        0x24U => {
          let i = r.u32_leb().reinterpret_as_int()
          check_index(at, i, ctx.globals, "global")
          GlobalSet(i)
        }
        0x28U => Mem(read_memop(r, base, I32, 4, false, false))
        0x29U => Mem(read_memop(r, base, I64, 8, false, false))
        0x2AU => Mem(read_memop(r, base, F32, 4, false, false))
        0x2BU => Mem(read_memop(r, base, F64, 8, false, false))
        0x2CU => Mem(read_memop(r, base, I32, 1, true, false))
        0x2DU => Mem(read_memop(r, base, I32, 1, false, false))
        0x2EU => Mem(read_memop(r, base, I32, 2, true, false))
        0x2FU => Mem(read_memop(r, base, I32, 2, false, false))
        0x30U => Mem(read_memop(r, base, I64, 1, true, false))
        0x31U => Mem(read_memop(r, base, I64, 1, false, false))
        0x32U => Mem(read_memop(r, base, I64, 2, true, false))
        0x33U => Mem(read_memop(r, base, I64, 2, false, false))
        0x34U => Mem(read_memop(r, base, I64, 4, true, false))
        0x35U => Mem(read_memop(r, base, I64, 4, false, false))
        0x36U => Mem(read_memop(r, base, I32, 4, false, true))
        0x37U => Mem(read_memop(r, base, I64, 8, false, true))
        0x38U => Mem(read_memop(r, base, F32, 4, false, true))
        0x39U => Mem(read_memop(r, base, F64, 8, false, true))
        0x3AU => Mem(read_memop(r, base, I32, 1, false, true))
        0x3BU => Mem(read_memop(r, base, I32, 2, false, true))
        0x3CU => Mem(read_memop(r, base, I64, 1, false, true))
        0x3DU => Mem(read_memop(r, base, I64, 2, false, true))
        0x3EU => Mem(read_memop(r, base, I64, 4, false, true))
        0x3FU => {
          check_reserved(r, base, "memory.size")
          MemorySize
        }
        0x40U => {
          check_reserved(r, base, "memory.grow")
          MemoryGrow
        }
        0x41U => Const(I32V(r.s32_leb()))
        0x42U => Const(I64V(r.s64_leb()))
        0x43U => Const(F32V(r.u32_le()))
        0x44U => Const(F64V(r.u64_le()))
        0xD0U | 0xD1U | 0xD2U =>
          fail_at(
            at,
            E101Gc,
            "reference-type instruction needs the reference-types proposal",
          )
        0xFCU => decode_misc(r, base, at)
        0xFBU =>
          fail_at(
            at,
            E101Gc,
            "opcode prefix 0xfb is the GC proposal; decode stops here",
          )
        0xFDU | 0xFEU => {
          // Unknown operand width. Record where understanding ended and stop;
          // everything decoded so far is still valid IR with valid offsets.
          let sub = r.u32_leb().reinterpret_as_int()
          stop_offset = at
          stop_op = op.reinterpret_as_int()
          stop_sub = sub
          complete = false
          running = false
          Nop
        }
        _ => {
          let at_txt = "\{hex_fixed(op.to_uint64(), 2)}"
          fail_at(at, E006BadOpcode, "opcode 0x\{at_txt} is not in the MVP set")
        }
      }
    }
    if running {
      instrs.push(InstrRef::new(at, instr))
    }
  }
  { instrs, complete, stop_offset, stop_op, stop_sub, }
}

///|
/// The numeric block `0x45..0xC4`, which is contiguous: every opcode in that
/// range is a comparison, an arithmetic operator, or a conversion. Splitting it
/// out keeps the dispatch above readable and makes the contiguity assertion in
/// the tests meaningful.
fn decode_numeric(op : UInt32) -> Instr {
  if op == 0x45U {
    return Un(I32, Eqz)
  }
  if op <= 0x4FU {
    return Bin(I32, cmp_kind((op - 0x46U).reinterpret_as_int()))
  }
  if op == 0x50U {
    return Un(I64, Eqz)
  }
  if op <= 0x5AU {
    return Bin(I64, cmp_kind((op - 0x51U).reinterpret_as_int()))
  }
  if op <= 0x60U {
    return Bin(F32, fcmp_kind((op - 0x5BU).reinterpret_as_int()))
  }
  if op <= 0x66U {
    return Bin(F64, fcmp_kind((op - 0x61U).reinterpret_as_int()))
  }
  if op <= 0x69U {
    return Un(I32, i32_un_kind((op - 0x67U).reinterpret_as_int()))
  }
  if op <= 0x78U {
    return Bin(I32, arith_kind((op - 0x6AU).reinterpret_as_int()))
  }
  if op <= 0x7BU {
    return Un(I64, i32_un_kind((op - 0x79U).reinterpret_as_int()))
  }
  if op <= 0x8AU {
    return Bin(I64, arith_kind((op - 0x7CU).reinterpret_as_int()))
  }
  if op <= 0x91U {
    return Un(F32, f_un_kind((op - 0x8BU).reinterpret_as_int()))
  }
  if op <= 0x98U {
    return Bin(F32, fbin_kind((op - 0x92U).reinterpret_as_int()))
  }
  if op <= 0x9FU {
    return Un(F64, f_un_kind((op - 0x99U).reinterpret_as_int()))
  }
  if op <= 0xA6U {
    return Bin(F64, fbin_kind((op - 0xA0U).reinterpret_as_int()))
  }
  if op <= 0xBFU {
    let (to, from, mode) = conv_of(op)
    return Conv(to, from, mode)
  }
  // 0xC0..0xC4: the sign-extension operators.
  if op == 0xC0U {
    return Un(I32, Extend8S)
  }
  if op == 0xC1U {
    return Un(I32, Extend16S)
  }
  if op == 0xC2U {
    return Un(I64, Extend8S)
  }
  if op == 0xC3U {
    return Un(I64, Extend16S)
  }
  Un(I64, Extend32S)
}

///|
/// `memory.size` and `memory.grow` are followed by a reserved memory index byte.
/// A non-zero value means multiple memories, a proposal this tool refuses at the
/// container layer already; catching it here keeps the message about the actual
/// byte rather than about a section.
fn check_reserved(
  r : Reader,
  base : Int32,
  what : String,
) -> Unit raise ReadFail {
  let at = base + r.position()
  let m = r.u32_leb()
  if m != 0U {
    fail_at(
      at,
      E110MultiTable,
      "\{what} names memory \{m}; only a single memory is supported",
    )
  }
}

///|
/// A branch depth is a *relative* reference, so the only bound is the current
/// nesting. Checking it here means the CFG builder never has to.
fn check_label(at : Int32, n : Int32, labels : Int32) -> Unit raise ReadFail {
  if n < 0 || n >= labels {
    fail_at(
      at,
      E008BadIndex,
      "label \{n} is out of range: \{labels} label(s) in scope",
    )
  }
}

///|
/// Decode one defined function of a module, wiring up the index-space sizes.
///
/// Imported functions have no body; asking for one is an index error, not a
/// silent empty result.
pub fn decode_func(m : Module, idx : Int32) -> DecodedBody raise ReadFail {
  let code = match m.code_of(idx) {
    Some(c) => c
    None =>
      fail_at(
        0,
        E008BadIndex,
        "function \{idx} has no body (import or out of range)",
      )
  }
  let params = match m.func_type(idx) {
    Some(t) => t.params.length()
    None => 0
  }
  let ctx = BodyCtx::new(
    params + code.local_count,
    m.globals.length(),
    m.func_count(),
    m.types.length(),
  )
  decode_body(code, ctx)
}

///|
/// Decode instruction `0xFC <sub>`, the bulk-memory / saturating-truncation
/// prefix.
///
/// Every legal sub-opcode here has a known operand length, so this prefix never
/// stops the decode: sub-opcodes 0..7 are numeric (the saturating truncations,
/// which the *type checker* treats exactly like `trunc_s`), and 8..11 are the
/// bulk-memory operations, which are decoded and then refused at generation
/// time because a decompiled function cannot reproduce a passive segment copy.
pub fn decode_misc(
  r : Reader,
  base : Int32,
  at : Int32,
) -> Instr raise ReadFail {
  let sub = r.u32_leb().reinterpret_as_int()
  if sub >= 0 && sub <= 7 {
    let (to, from, mode) = trunc_sat_of(sub)
    return Conv(to, from, mode)
  }
  if sub == 8 {
    let d = r.u32_leb().reinterpret_as_int()
    check_reserved(r, base, "memory.init")
    return Misc(MemoryInit(d))
  }
  if sub == 9 {
    return Misc(DataDrop(r.u32_leb().reinterpret_as_int()))
  }
  if sub == 10 {
    check_reserved(r, base, "memory.copy")
    check_reserved(r, base, "memory.copy")
    return Misc(MemoryCopy)
  }
  if sub == 11 {
    check_reserved(r, base, "memory.fill")
    return Misc(MemoryFill)
  }
  fail_at(
    at,
    E006BadOpcode,
    "0xfc sub-opcode \{sub} is not defined by bulk memory",
  )
}
