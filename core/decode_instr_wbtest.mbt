///|
/// Instruction-decoder tests.
///
/// Two kinds here, and the distinction matters for what they prove:
///
/// - **Table tests** walk the spec's opcode layout and assert every entry
///   decodes to the expected mnemonic. They came from the spec, not from the
///   implementation, and `corpus/tools/verify_decode.js` then re-checks the same
///   claim against wabt — an independent decoder.
/// - **Structure tests** drive the error paths: label depth, `else` placement,
///   index bounds, truncation. Each asserts the error *code* and the *offset*,
///   because a diagnostic without a byte position is not actionable.

///|
/// A code body whose first instruction byte sits at absolute offset 100, so that
/// offset arithmetic is visibly exercised rather than accidentally correct at 0.
fn tb(bytes : Bytes) -> Code {
  { locals: [], local_count: 0, body: bytes, body_offset: 100, }
}

///|
/// Four locals, two globals, three functions, two types: small enough to make
/// an out-of-range index obvious, large enough for the happy paths.
fn tctx() -> BodyCtx {
  BodyCtx::new(4, 2, 3, 2)
}

///|
/// Decode a one-byte-per-item vector, terminated by the function `end`.
fn with_end(opcodes : Array[Int32]) -> Bytes {
  let acc : Array[Byte] = []
  for o in opcodes {
    acc.push(o.to_byte())
  }
  acc.push(0x0B)
  Bytes::from_array(acc[:])
}

///|
/// `mnemonic` of every instruction, for compact assertions.
fn mnemonics(b : DecodedBody) -> Array[String] {
  let out : Array[String] = []
  for r in b.instrs {
    out.push(r.instr.mnemonic())
  }
  out
}

///|
fn decode_of(bytes : Bytes) -> DecodedBody raise ReadFail {
  decode_body(tb(bytes), tctx())
}

///|
/// The error tag produced by decoding, or `"ok"`.
fn tag_of(bytes : Bytes) -> String {
  try {
    let _ = decode_of(bytes)
    "ok"
  } catch {
    ReadFail(d) => d.code.tag()
  }
}

///|
/// The error offset produced by decoding, or -1 when it succeeded.
fn offset_of(bytes : Bytes) -> Int32 {
  try {
    let _ = decode_of(bytes)
    -1
  } catch {
    ReadFail(d) => d.offset
  }
}

// --- the numeric block ---------------------------------------------------

///|
test "numeric block 0x45..0xc4 is contiguous and fully decodable" {
  // 128 opcodes with no immediates: comparisons, arithmetic, conversions and
  // sign extension. If any of them fell through to the dispatcher's default arm
  // the mnemonic would be an error, so this single loop covers the whole range.
  let mut op = 0x45
  while op <= 0xC4 {
    let b = decode_of(with_end([op]))
    // One instruction, not two: the function's own `end` terminates the body
    // rather than appearing in it. wabt's text agrees — it writes `end)` for the
    // outermost block and nothing for the function's end.
    assert_eq(b.instrs.length(), 1)
    let m = b.instrs[0].instr.mnemonic()
    assert_true(m.contains("."))
    op = op + 1
  }
}

///|
test "integer and float spellings differ where the spec says they do" {
  // The bug the wabt cross-check found: f32.div was rendered f32.div_s because
  // the decoder shares one DivS kind across both families.
  assert_eq(decode_of(with_end([0x95])).instrs[0].instr.mnemonic(), "f32.div")
  assert_eq(decode_of(with_end([0x6D])).instrs[0].instr.mnemonic(), "i32.div_s")
  assert_eq(decode_of(with_end([0x5D])).instrs[0].instr.mnemonic(), "f32.lt")
  assert_eq(decode_of(with_end([0x48])).instrs[0].instr.mnemonic(), "i32.lt_s")
  assert_eq(decode_of(with_end([0xA4])).instrs[0].instr.mnemonic(), "f64.min")
  assert_eq(decode_of(with_end([0x76])).instrs[0].instr.mnemonic(), "i32.shr_u")
}

///|
test "sign extension opcodes" {
  assert_eq(
    decode_of(with_end([0xC0])).instrs[0].instr.mnemonic(),
    "i32.extend8_s",
  )
  assert_eq(
    decode_of(with_end([0xC1])).instrs[0].instr.mnemonic(),
    "i32.extend16_s",
  )
  assert_eq(
    decode_of(with_end([0xC2])).instrs[0].instr.mnemonic(),
    "i64.extend8_s",
  )
  assert_eq(
    decode_of(with_end([0xC3])).instrs[0].instr.mnemonic(),
    "i64.extend16_s",
  )
  assert_eq(
    decode_of(with_end([0xC4])).instrs[0].instr.mnemonic(),
    "i64.extend32_s",
  )
}

///|
test "conversion opcodes keep the operand type in the mnemonic" {
  assert_eq(
    decode_of(with_end([0xA7])).instrs[0].instr.mnemonic(),
    "i32.wrap_i64",
  )
  assert_eq(
    decode_of(with_end([0xAA])).instrs[0].instr.mnemonic(),
    "i32.trunc_f64_s",
  )
  assert_eq(
    decode_of(with_end([0xB6])).instrs[0].instr.mnemonic(),
    "f32.demote_f64",
  )
  assert_eq(
    decode_of(with_end([0xBB])).instrs[0].instr.mnemonic(),
    "f64.promote_f32",
  )
  assert_eq(
    decode_of(with_end([0xBC])).instrs[0].instr.mnemonic(),
    "i32.reinterpret_f32",
  )
  assert_eq(
    decode_of(with_end([0xBF])).instrs[0].instr.mnemonic(),
    "f64.reinterpret_i64",
  )
}

// --- memory operands -----------------------------------------------------

///|
test "all 23 memory opcodes round-trip through their mnemonics" {
  // The mnemonics are *computed* from (type, width, signed, store) rather than
  // stored, so this asserts that the computation reproduces the 23 spellings in
  // the spec. align=0 and offset=0 are the shortest legal encoding of a memarg.
  let expect = [
    "i32.load", "i64.load", "f32.load", "f64.load", "i32.load8_s", "i32.load8_u",
    "i32.load16_s", "i32.load16_u", "i64.load8_s", "i64.load8_u", "i64.load16_s",
    "i64.load16_u", "i64.load32_s", "i64.load32_u", "i32.store", "i64.store", "f32.store",
    "f64.store", "i32.store8", "i32.store16", "i64.store8", "i64.store16", "i64.store32",
  ]
  let mut op = 0x28
  let mut i = 0
  while op <= 0x3E {
    let b = decode_of(with_end([op, 0, 0]))
    assert_eq(b.instrs[0].instr.mnemonic(), expect[i])
    op = op + 1
    i = i + 1
  }
  assert_eq(i, 23)
}

///|
test "memarg carries offset and alignment, and alignment is validated" {
  // i32.load offset=16 align=4 → align exponent 2 is legal for a 4-byte access.
  let ok = decode_of(with_end([0x28, 2, 16]))
  assert_eq(ok.instrs[0].instr.render(), "i32.load offset=16 align=4")
  // align exponent 3 on a 4-byte access is over-aligned: a spec violation, and
  // accepting it would let the generator emit a misaligned read.
  assert_eq(tag_of(with_end([0x28, 3, 0])), "E007")
}

// --- control flow structure ----------------------------------------------

///|
test "nested blocks produce a balanced stream with offsets" {
  // block (result i32) { block { nop } i32.const 1 }
  let b = decode_of(
    with_end([0x02, 0x7F, 0x02, 0x40, 0x01, 0x0B, 0x41, 0x01, 0x0B]),
  )
  // Two blocks, one nop, two `end`s. The third `end` closes the function and is
  // the body terminator, so it is validated but not stored.
  assert_eq(mnemonics(b), ["block", "block", "nop", "end", "i32.const", "end"])
  assert_eq(b.instrs[0].offset, 100) // `block` opcode at 100
  assert_eq(b.instrs[1].offset, 102) // `block` opcode at 102
  assert_eq(b.instrs[2].offset, 104) // `nop` at 104
}

///|
test "label depth is checked against the current nesting" {
  // At the top level exactly one label is in scope: the function body.
  assert_eq(tag_of(with_end([0x0C, 0])), "ok") // br 0 is a return
  assert_eq(tag_of(with_end([0x0C, 1])), "E008")
  // Inside one block, two labels are in scope.
  assert_eq(tag_of(with_end([0x02, 0x40, 0x0C, 1, 0x0B])), "ok")
  assert_eq(tag_of(with_end([0x02, 0x40, 0x0C, 2, 0x0B])), "E008")
}

///|
test "else is only legal directly inside an if" {
  assert_eq(tag_of(with_end([0x05])), "E006")
  assert_eq(tag_of(with_end([0x02, 0x40, 0x05, 0x0B])), "E006")
  assert_eq(tag_of(with_end([0x04, 0x40, 0x05, 0x0B])), "ok")
  // Two `else` in the same `if` is malformed, and the second one must say so.
  assert_eq(tag_of(with_end([0x04, 0x40, 0x05, 0x05, 0x0B])), "E006")
}

///|
test "a body must end with its own end and nothing after it" {
  assert_eq(tag_of(b"\x01"), "E001") // nop but no end
  assert_eq(tag_of(b"\x0b"), "ok") // an empty body is just its `end`
  // A second `end` means the body ended a byte early. Silently ignoring the
  // remainder would hide exactly the corruption this check exists for.
  assert_eq(tag_of(b"\x0b\x0b"), "E005")
  assert_eq(tag_of(b"\x0b\x01\x0b"), "E005")
}

// --- indices -------------------------------------------------------------

///|
test "a rejected index is reported at the byte that carries it" {
  // The diagnostic has to point at the opcode, not at the function. Body starts
  // at 100, so `local.get` is at 100 and its LEB operand at 101.
  assert_eq(offset_of(with_end([0x20, 9])), 100)
  assert_eq(offset_of(with_end([0x02, 0x40, 0x20, 9])), 102)
}

///|
test "local, global, function and type indices are bounds checked" {
  assert_eq(tag_of(with_end([0x20, 3])), "ok") // local.get 3 of 4
  assert_eq(tag_of(with_end([0x20, 4])), "E008")
  assert_eq(tag_of(with_end([0x23, 1])), "ok")
  assert_eq(tag_of(with_end([0x23, 2])), "E008")
  assert_eq(tag_of(with_end([0x10, 2])), "ok")
  assert_eq(tag_of(with_end([0x10, 3])), "E008")
  assert_eq(tag_of(with_end([0x11, 1, 0])), "ok") // call_indirect (type 1)
  assert_eq(tag_of(with_end([0x11, 2, 0])), "E008")
}

///|
test "call_indirect naming a second table is reported as multi-table" {
  assert_eq(tag_of(with_end([0x11, 0, 1])), "E110")
}

// --- constants -----------------------------------------------------------

///|
test "integer constants are sign-extended from their LEB encoding" {
  // -1 encoded in one byte, and the 32-bit minimum in five.
  assert_eq(
    decode_of(with_end([0x41, 0x7F])).instrs[0].instr.render(),
    "i32.const -1",
  )
  assert_eq(
    decode_of(with_end([0x41, 0x80, 0x80, 0x80, 0x80, 0x78])).instrs[0].instr.render(),
    "i32.const -2147483648",
  )
  assert_eq(
    decode_of(with_end([0x42, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])).instrs[0].instr.render(),
    "i64.const -1",
  )
}

///|
test "float constants keep their exact bit pattern" {
  // 0x3F800000 is 1.0f; rendering it as a decimal would lose NaN payloads.
  let f32v = decode_of(with_end([0x43, 0x00, 0x00, 0x80, 0x3F]))
  assert_eq(f32v.instrs[0].instr.render(), "f32.const 0x3f800000")
  // 0.1f64 = 0x3FB999999999999A exactly.
  let f64v = decode_of(
    with_end([0x44, 0x9A, 0x99, 0x99, 0x99, 0x99, 0x99, 0xB9, 0x3F]),
  )
  assert_eq(f64v.instrs[0].instr.render(), "f64.const 0x3fb999999999999a")
}

// --- bulk memory and the stop rule --------------------------------------

///|
test "the 0xfc prefix decodes saturating truncation and bulk memory" {
  // sub 0 = i32.trunc_sat_f32_s, sub 7 = i64.trunc_sat_f64_u.
  assert_eq(
    decode_of(with_end([0xFC, 0])).instrs[0].instr.mnemonic(),
    "i32.trunc_sat_f32_s",
  )
  assert_eq(
    decode_of(with_end([0xFC, 7])).instrs[0].instr.mnemonic(),
    "i64.trunc_sat_f64_u",
  )
  // sub 11 = memory.fill, followed by its reserved memory index.
  assert_eq(
    decode_of(with_end([0xFC, 11, 0])).instrs[0].instr.mnemonic(),
    "memory.fill",
  )
  assert_eq(tag_of(with_end([0xFC, 99])), "E006")
}

///|
test "an opcode with an unknown operand length stops the decode, not the file" {
  // 0xFD is the SIMD prefix: we cannot skip its operands without implementing
  // its table, so decoding stops and the body is marked partial. The bytes that
  // were understood stay available with their offsets.
  let b = decode_of(with_end([0x01, 0xFD, 0x0B, 0x0B]))
  assert_false(b.is_complete())
  assert_eq(b.instrs.length(), 1) // nop only
  assert_true(b.stop_note().contains("0xfd/0x0b"))
  assert_true(b.stop_note().contains("simd"))
}

// --- totality ------------------------------------------------------------

///|
test "every opcode byte either decodes or produces a diagnostic" {
  // Not a semantic claim — a liveness one. A dispatch table with a missing arm
  // typically loops, panics or returns a wrong instruction; this walks all 256
  // bytes and requires the decoder to do neither. The set of codes is the union
  // of everything a single byte can legitimately provoke.
  let allowed = [
    "ok", "E001", "E004", "E005", "E006", "E007", "E008", "E101", "E110",
  ]
  let mut op = 0
  while op <= 0xFF {
    let t = tag_of(with_end([op]))
    assert_true(allowed.contains(t))
    op = op + 1
  }
}
