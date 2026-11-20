///|
/// White-box tests for the byte reader.
///
/// Test vectors are taken from the WebAssembly core spec, appendix "Binary
/// format" (LEB128 examples) and from IEEE-754 bit patterns, not from this
/// implementation — otherwise the tests would only prove self-consistency.
///
/// A raising call inside a `test` body fails the test, so success cases read as
/// plain code; only the rejection cases need `catch_diag`.
fn catch_diag(f : () -> Unit raise ReadFail) -> Diag {
  try {
    f()
    Diag::new(E001Truncated, -1, "no error was raised")
  } catch {
    ReadFail(d) => d
  }
}

///|
test "reads single bytes and tracks the absolute offset" {
  let r = Reader::new(b"\x00\x7f\xff")
  assert_eq(r.position(), 0)
  assert_eq(r.u8().to_uint(), 0x00U)
  assert_eq(r.position(), 1)
  assert_eq(r.u8().to_uint(), 0x7FU)
  assert_eq(r.u8().to_uint(), 0xFFU)
  assert_eq(r.position(), 3)
  assert_true(r.at_end())
  assert_eq(r.remaining(), 0)
}

///|
test "truncation reports the offset where it ran out" {
  let r = Reader::new(b"\x01")
  assert_eq(r.u8().to_uint(), 1U)
  let d = catch_diag(() => r.u8() |> ignore)
  assert_eq(d.code.tag(), "E001")
  assert_eq(d.offset, 1)
}

///|
test "peek does not consume and terminates section loops" {
  let r = Reader::new(b"\x2a")
  assert_eq(r.peek_u8().unwrap().to_uint(), 0x2AU)
  assert_eq(r.position(), 0)
  assert_eq(r.u8().to_uint(), 0x2AU)
  assert_true(r.peek_u8() is None)
}

///|
test "skip and bytes refuse to read past the end" {
  let r = Reader::new(b"\x01\x02")
  r.skip(2)
  let d = catch_diag(() => r.skip(1))
  assert_eq(d.code.tag(), "E001")
  let r2 = Reader::new(b"\x01\x02")
  let d2 = catch_diag(() => r2.bytes(5) |> ignore)
  assert_eq(d2.code.tag(), "E001")
  assert_true(d2.message.contains("only 2 left"))
}

///|
test "bytes copies rather than aliasing the input" {
  let src = b"\x0a\x0b\x0c"
  let r = Reader::new(src)
  let got = r.bytes(2)
  assert_eq(got.length(), 2)
  assert_eq(got[0].to_uint(), 0x0AU)
  assert_eq(got[1].to_uint(), 0x0BU)
  assert_eq(r.position(), 2)
}

///|
test "little-endian fixed widths" {
  let r = Reader::new(b"\x78\x56\x34\x12")
  assert_eq(r.u32_le(), 0x12345678U)
  let r2 = Reader::new(b"\x01\x00\x00\x00\x00\x00\x00\x80")
  assert_eq(r2.u64_le(), 0x8000000000000001UL)
}

///|
test "floats are rebuilt bit-exactly" {
  let one = Reader::new(b"\x00\x00\x80\x3f").f32_le()
  assert_eq(one.reinterpret_as_uint(), 0x3F800000U)
  assert_true(one == 1.0)
  // 0.1 as f64 = 0x3FB999999999999A; a decimal round-trip would not survive this.
  let tenth = Reader::new(b"\x9a\x99\x99\x99\x99\x99\xb9\x3f").f64_le()
  assert_eq(tenth.reinterpret_as_uint64(), 0x3FB999999999999AUL)
  let nan = Reader::new(b"\x00\x00\xc0\x7f").f32_le()
  assert_true(nan.is_nan())
}

///|
test "u32 LEB128 spec vectors" {
  assert_eq(Reader::new(b"\x00").u32_leb(), 0U)
  assert_eq(Reader::new(b"\xe5\x8e\x26").u32_leb(), 624485U)
  assert_eq(Reader::new(b"\xff\xff\xff\xff\x0f").u32_leb(), 0xFFFFFFFFU)
  // Non-minimal but legal: zero encoded in two bytes.
  assert_eq(Reader::new(b"\x80\x00").u32_leb(), 0U)
  let r = Reader::new(b"\xe5\x8e\x26")
  assert_eq(r.u32_leb(), 624485U)
  assert_eq(r.position(), 3)
}

///|
test "u32 LEB128 rejects overflow instead of masking" {
  let d = catch_diag(() => {
    Reader::new(b"\xff\xff\xff\xff\x1f").u32_leb() |> ignore
  })
  assert_eq(d.code.tag(), "E004")
  // Six bytes: the fifth still has the continuation bit set.
  let d2 = catch_diag(() => {
    Reader::new(b"\x80\x80\x80\x80\x80\x00").u32_leb() |> ignore
  })
  assert_eq(d2.code.tag(), "E004")
}

///|
test "s32 LEB128 spec vectors" {
  assert_eq(Reader::new(b"\x7f").s32_leb(), -1)
  assert_eq(Reader::new(b"\xc0\xbb\x78").s32_leb(), -123456)
  assert_eq(Reader::new(b"\xff\xff\xff\xff\x07").s32_leb(), 2147483647)
  assert_eq(Reader::new(b"\x80\x80\x80\x80\x78").s32_leb(), -2147483648)
  assert_eq(Reader::new(b"\x3f").s32_leb(), 63)
  assert_eq(Reader::new(b"\x40").s32_leb(), -64)
}

///|
test "s32 LEB128 rejects inconsistent sign bits" {
  // Fifth byte 0x08 would mean a positive value that does not fit in 31 bits.
  let d = catch_diag(() => {
    Reader::new(b"\x80\x80\x80\x80\x08").s32_leb() |> ignore
  })
  assert_eq(d.code.tag(), "E004")
  assert_eq(d.offset, 4)
}

///|
test "u64 LEB128 boundaries" {
  assert_eq(Reader::new(b"\x00").u64_leb(), 0UL)
  assert_eq(
    Reader::new(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01").u64_leb(),
    0xFFFFFFFFFFFFFFFFUL,
  )
  let d = catch_diag(() => {
    Reader::new(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02").u64_leb() |> ignore
  })
  assert_eq(d.code.tag(), "E004")
}

///|
test "s64 LEB128 boundaries" {
  assert_eq(Reader::new(b"\x7f").s64_leb(), -1L)
  assert_eq(Reader::new(b"\x00").s64_leb(), 0L)
  assert_eq(
    Reader::new(b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x7f").s64_leb(),
    -9223372036854775808L,
  )
  assert_eq(
    Reader::new(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00").s64_leb(),
    9223372036854775807L,
  )
}

///|
test "names carry a length prefix and are UTF-8 validated" {
  let r = Reader::new(b"\x03abc")
  assert_eq(r.name(), "abc")
  assert_eq(r.position(), 4)
  // Two-byte UTF-8 sequence for U+00E9 (é).
  let r2 = Reader::new(b"\x02\xc3\xa9")
  assert_eq(r2.name(), "é")
}

///|
test "invalid UTF-8 in a name is reported at the offending byte" {
  // 0xC3 expects a continuation byte; 0x28 is not one, and sits at offset 2.
  let r = Reader::new(b"\x02\xc3\x28")
  let d = catch_diag(() => r.name() |> ignore)
  assert_eq(d.code.tag(), "E009")
  assert_eq(d.offset, 2)
}

///|
test "name length past the end of input is a truncation error" {
  let r = Reader::new(b"\x09abc")
  let d = catch_diag(() => r.name() |> ignore)
  assert_eq(d.code.tag(), "E001")
  assert_eq(d.offset, 0)
}

///|
test "UTF-8 validator accepts the edges of each range" {
  assert_true(validate_utf8(b"ascii") is None)
  assert_true(validate_utf8(b"\x7f") is None)
  assert_true(validate_utf8(b"\xc2\x80") is None) // U+0080, smallest 2-byte
  assert_true(validate_utf8(b"\xe0\xa0\x80") is None) // U+0800, smallest 3-byte
  assert_true(validate_utf8(b"\xed\x9f\xbf") is None) // U+D7FF, below surrogates
  assert_true(validate_utf8(b"\xee\x80\x80") is None) // U+E000, above surrogates
  assert_true(validate_utf8(b"\xf0\x90\x80\x80") is None) // U+10000
  assert_true(validate_utf8(b"\xf4\x8f\xbf\xbf") is None) // U+10FFFF
}

///|
test "UTF-8 validator rejects overlongs, surrogates and out-of-range" {
  assert_eq(validate_utf8(b"\xc0\x80"), Some(0)) // overlong NUL
  assert_eq(validate_utf8(b"\xe0\x80\x80"), Some(1)) // overlong 3-byte
  assert_eq(validate_utf8(b"\xed\xa0\x80"), Some(1)) // surrogate D800
  assert_eq(validate_utf8(b"\xf4\x90\x80\x80"), Some(1)) // U+110000
  assert_eq(validate_utf8(b"\xf5\x80\x80\x80"), Some(0)) // lead byte out of range
  assert_eq(validate_utf8(b"\x80"), Some(0)) // bare continuation
  assert_eq(validate_utf8(b"ab\xc3"), Some(2)) // truncated sequence
}

///|
test "attempt converts a raise into a Result for the public API" {
  let ok = attempt(() => Reader::new(b"\x2a").u8().to_uint())
  match ok {
    Ok(v) => assert_eq(v, 42U)
    Err(_) => assert_true(false)
  }
  let bad = attempt(() => Reader::new(b"").u8().to_uint())
  match bad {
    Ok(_) => assert_true(false)
    Err(d) => assert_eq(d.code.tag(), "E001")
  }
}

///|
test "names survive astral-plane characters" {
  // U+1F600 GRINNING FACE, 4-byte UTF-8. MoonBit strings are UTF-16, so this
  // exercises the surrogate-pair path that a naive byte-by-byte decoder breaks.
  let r = Reader::new(b"\x04\xf0\x9f\x98\x80")
  assert_eq(r.name(), "😀")
}
