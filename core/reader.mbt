///|
/// Raised by every read that cannot be satisfied. Always carries a `Diag`, so
/// the byte offset survives unwinding — this is the property that makes the
/// decompiler debuggable on a 2 MB binary.
pub suberror ReadFail {
  ReadFail(Diag)
}

///|
/// A forward-only cursor over a byte slice.
///
/// Deliberately not a `BytesView`: views are cheap but they make "position in
/// the file" an extra concept the decoder has to track, and every diagnostic in
/// this project is expressed as an absolute offset into the input.
///
/// All arithmetic is little-endian, matching the wasm binary format.
///
/// `limit` exists so that a section can be handed to a parser as a bounded
/// *window* over the same buffer (`slice`). The window shares the absolute
/// offset space of the parent, so a diagnostic inside a section still quotes
/// the byte position in the file, while a parser physically cannot read past
/// the section it was given. Both properties are needed: wasm sections are
/// length-delimited, and a size field that disagrees with its content is one of
/// the most common forms of corruption.
pub struct Reader {
  data : Bytes
  /// Offset of the next byte to read. Publicly readable, mutated only by reads.
  mut pos : Int32
  /// Absolute offset one past the last readable byte of this window.
  limit : Int32
}

///|
pub fn Reader::new(data : Bytes) -> Reader {
  { data, pos: 0, limit: data.length(), }
}

///|
/// Carve a bounded window of `len` bytes off the front of this reader.
///
/// The current reader advances past those bytes, the returned window cannot
/// read beyond them. Offsets stay absolute.
pub fn Reader::slice(self : Reader, len : Int32) -> Reader raise ReadFail {
  if len < 0 || self.pos + len > self.limit {
    fail_at(
      self.pos,
      E001Truncated,
      "unexpected end of input slicing \{len} bytes (only \{self.remaining()} left)",
    )
  }
  let w = { data: self.data, pos: self.pos, limit: self.pos + len, }
  self.pos = self.pos + len
  w
}

///|
pub fn Reader::data(self : Reader) -> Bytes {
  self.data
}

///|
/// Absolute offset of the next byte to be read. This is what diagnostics quote.
pub fn Reader::position(self : Reader) -> Int32 {
  self.pos
}

///|
pub fn Reader::length(self : Reader) -> Int32 {
  self.limit
}

///|
pub fn Reader::remaining(self : Reader) -> Int32 {
  self.limit - self.pos
}

///|
pub fn Reader::at_end(self : Reader) -> Bool {
  self.pos >= self.limit
}

///|
/// Jump to an absolute offset. Only used for error recovery and for tests that
/// re-read a section; forward decoding never seeks backwards.
pub fn Reader::seek(self : Reader, pos : Int32) -> Unit {
  self.pos = pos
}

///|
/// Generic on purpose: it always diverges, so it can stand in for any expected
/// type at the tail of a function without a dummy `return`.
fn[T] fail_at(
  offset : Int32,
  code : ErrorCode,
  message : String,
) -> T raise ReadFail {
  raise ReadFail(Diag::new(code, offset, message))
}

///|
/// One unsigned byte.
pub fn Reader::u8(self : Reader) -> Byte raise ReadFail {
  if self.pos >= self.limit {
    fail_at(self.pos, E001Truncated, "unexpected end of input reading 1 byte")
  }
  let b = self.data[self.pos]
  self.pos = self.pos + 1
  b
}

///|
/// Look at the next byte without consuming it. Returns `None` at end of input,
/// which is how section loops terminate.
pub fn Reader::peek_u8(self : Reader) -> Byte? {
  if self.pos >= self.limit {
    None
  } else {
    Some(self.data[self.pos])
  }
}

///|
/// Drop `n` bytes. Fails rather than silently clamping: a truncated section is
/// a malformed module, not something to paper over.
pub fn Reader::skip(self : Reader, n : Int32) -> Unit raise ReadFail {
  if n < 0 || self.pos + n > self.limit {
    fail_at(
      self.pos,
      E001Truncated,
      "unexpected end of input skipping \{n} bytes",
    )
  }
  self.pos = self.pos + n
}

///|
/// Copy `n` bytes out. A copy, not a view: the returned bytes outlive the read
/// position and are stored in the IR.
pub fn Reader::bytes(self : Reader, n : Int32) -> Bytes raise ReadFail {
  if n < 0 || self.pos + n > self.limit {
    fail_at(
      self.pos,
      E001Truncated,
      "unexpected end of input reading \{n} bytes (only \{self.remaining()} left)",
    )
  }
  let acc : Array[Byte] = []
  let mut i = 0
  while i < n {
    acc.push(self.data[self.pos + i])
    i = i + 1
  }
  self.pos = self.pos + n
  Bytes::from_array(acc[:])
}

// --- fixed-width little-endian reads -------------------------------------

///|
pub fn Reader::u32_le(self : Reader) -> UInt32 raise ReadFail {
  let at = self.pos
  let b = self.bytes(4)
  let v = b[0].to_uint() |
    (b[1].to_uint() << 8) |
    (b[2].to_uint() << 16) |
    (b[3].to_uint() << 24)
  let _ = at
  v
}

///|
pub fn Reader::u64_le(self : Reader) -> UInt64 raise ReadFail {
  let b = self.bytes(8)
  let mut v : UInt64 = 0UL
  let mut i = 0
  while i < 8 {
    v = v | (b[i].to_uint64() << (8 * i))
    i = i + 1
  }
  v
}

///|
/// `f32` from 4 little-endian bytes, bit-exact (no decimal round-trip).
pub fn Reader::f32_le(self : Reader) -> Float raise ReadFail {
  Float::reinterpret_from_uint(self.u32_le())
}

///|
/// `f64` from 8 little-endian bytes, bit-exact.
pub fn Reader::f64_le(self : Reader) -> Double raise ReadFail {
  self.u64_le().reinterpret_as_double()
}

// --- LEB128 ---------------------------------------------------------------
//
// Byte counts are fixed by the spec: at most 5 bytes for 32-bit values and 10
// for 64-bit values. The final byte has spare bits that must be zero (unsigned)
// or equal to the sign (signed); we reject rather than mask, because a widening
// value means the producer is broken and the decoded index would be nonsense.

///|
pub fn Reader::u32_leb(self : Reader) -> UInt32 raise ReadFail {
  let mut result : UInt32 = 0
  let mut i = 0
  while i < 5 {
    let at = self.pos
    let u = self.u8().to_uint()
    if i == 4 {
      if (u & 0xF0U) != 0U {
        fail_at(at, E004BadLeb128, "u32 LEB128 value does not fit in 32 bits")
      }
      return result | ((u & 0x7FU) << 28)
    }
    result = result | ((u & 0x7FU) << (7 * i))
    if (u & 0x80U) == 0U {
      return result
    }
    i = i + 1
  }
  fail_at(self.pos, E004BadLeb128, "u32 LEB128 sequence longer than 5 bytes")
}

///|
pub fn Reader::u64_leb(self : Reader) -> UInt64 raise ReadFail {
  let mut result : UInt64 = 0UL
  let mut i = 0
  while i < 10 {
    let at = self.pos
    let u = self.u8().to_uint()
    if i == 9 {
      if (u & 0xFEU) != 0U {
        fail_at(at, E004BadLeb128, "u64 LEB128 value does not fit in 64 bits")
      }
      return result | (u.to_uint64() << 63)
    }
    result = result | (u.to_uint64().land(0x7FUL) << (7 * i))
    if (u & 0x80U) == 0U {
      return result
    }
    i = i + 1
  }
  fail_at(self.pos, E004BadLeb128, "u64 LEB128 sequence longer than 10 bytes")
}

///|
/// Signed 32-bit LEB128, returned as `Int`.
///
/// `Int` is the right type here: on every backend we target, `Int` is exactly
/// i32 with wrapping arithmetic, which is also what the wasm `i32` type means.
/// Keeping the mapping 1:1 removes an entire class of conversion bugs.
pub fn Reader::s32_leb(self : Reader) -> Int32 raise ReadFail {
  let mut result : UInt32 = 0
  let mut i = 0
  while i < 5 {
    let at = self.pos
    let u = self.u8().to_uint()
    if i == 4 {
      let high = u & 0x78U
      if high != 0U && high != 0x78U {
        fail_at(at, E004BadLeb128, "s32 LEB128 sign bits are not consistent")
      }
      return (result | ((u & 0x7FU) << 28)).reinterpret_as_int()
    }
    result = result | ((u & 0x7FU) << (7 * i))
    if (u & 0x80U) == 0U {
      let shift = 7 * (i + 1)
      // Sign-extend: a short encoding carries the sign in bit 6 of its last byte.
      if shift < 32 && (u & 0x40U) != 0U {
        result = result | (0xFFFFFFFFU << shift)
      }
      return result.reinterpret_as_int()
    }
    i = i + 1
  }
  fail_at(self.pos, E004BadLeb128, "s32 LEB128 sequence longer than 5 bytes")
}

///|
pub fn Reader::s64_leb(self : Reader) -> Int64 raise ReadFail {
  let mut result : UInt64 = 0UL
  let mut i = 0
  while i < 10 {
    let at = self.pos
    let u = self.u8().to_uint()
    if i == 9 {
      let low = u & 0x7FU
      if low != 0U && low != 0x7FU {
        fail_at(at, E004BadLeb128, "s64 LEB128 sign bits are not consistent")
      }
      return (result | (low.to_uint64() << 63)).reinterpret_as_int64()
    }
    result = result | (u.to_uint64().land(0x7FUL) << (7 * i))
    if (u & 0x80U) == 0U {
      let shift = 7 * (i + 1)
      if shift < 64 && (u & 0x40U) != 0U {
        result = result | (0xFFFFFFFFFFFFFFFFUL << shift)
      }
      return result.reinterpret_as_int64()
    }
    i = i + 1
  }
  fail_at(self.pos, E004BadLeb128, "s64 LEB128 sequence longer than 10 bytes")
}

// --- composite reads ------------------------------------------------------

///|
/// A wasm name: LEB128 length followed by that many UTF-8 bytes.
///
/// Validated here rather than at the point of use, so that an invalid name is
/// reported with the offset of the offending byte and not 200 lines later.
pub fn Reader::name(self : Reader) -> String raise ReadFail {
  let start = self.pos
  let len = self.u32_leb()
  if len > self.remaining().reinterpret_as_uint() {
    fail_at(start, E001Truncated, "name length \{len} exceeds remaining input")
  }
  let raw = self.bytes(len.reinterpret_as_int())
  match validate_utf8(raw) {
    Some(bad) =>
      fail_at(start + 1 + bad, E009BadUtf8, "name is not valid UTF-8")
    None => decode_utf8(raw)
  }
}

///|
/// Bridge between the raising decoder and the `Result`-based public API.
///
/// The decoder internals raise because a read failure has to abort the whole
/// function anyway; the public surface returns `Result` because callers want to
/// print a diagnostic and continue with the next file.
pub fn[T] attempt(f : () -> T raise ReadFail) -> DecodeResult[T] {
  Ok(f()) catch {
    ReadFail(d) => Err(d)
  }
}
