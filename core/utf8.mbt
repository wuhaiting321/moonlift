///|
/// Strict UTF-8 validation.
///
/// The WebAssembly spec requires names (imports, exports, the `name` custom
/// section) to be valid UTF-8, and rejects modules where they are not. Being
/// strict here matters for a decompiler: a mangled name silently turned into
/// replacement characters would produce source that no longer matches the
/// original exports.
///
/// Returns `None` when the input is valid, or `Some(offset)` pointing at the
/// first byte that breaks the encoding.
pub fn validate_utf8(bytes : Bytes) -> Int32? {
  let len = bytes.length()
  let mut i = 0
  while i < len {
    let b0 = bytes[i].to_uint()
    if b0 < 0x80 {
      i = i + 1
      continue
    }
    // Continuation byte as lead, C0/C1 (overlong 2-byte), F5..FF (beyond U+10FFFF).
    if b0 < 0xC2 || b0 > 0xF4 {
      return Some(i)
    }
    let need = if b0 < 0xE0 { 1 } else if b0 < 0xF0 { 2 } else { 3 }
    if i + need >= len {
      return Some(i)
    }
    let b1 = bytes[i + 1].to_uint()
    match need {
      1 => if b1 < 0x80 || b1 > 0xBF { return Some(i + 1) }
      2 => {
        let (lo, hi) = if b0 == 0xE0 {
          (0xA0U, 0xBFU) // reject overlong 3-byte
        } else if b0 == 0xED {
          (0x80U, 0x9FU) // reject UTF-16 surrogates D800..DFFF
        } else {
          (0x80U, 0xBFU)
        }
        if b1 < lo || b1 > hi {
          return Some(i + 1)
        }
        if !is_continuation(bytes[i + 2]) {
          return Some(i + 2)
        }
      }
      _ => {
        let (lo, hi) = if b0 == 0xF0 {
          (0x90U, 0xBFU) // reject overlong 4-byte
        } else if b0 == 0xF4 {
          (0x80U, 0x8FU) // reject > U+10FFFF
        } else {
          (0x80U, 0xBFU)
        }
        if b1 < lo || b1 > hi {
          return Some(i + 1)
        }
        if !is_continuation(bytes[i + 2]) {
          return Some(i + 2)
        }
        if !is_continuation(bytes[i + 3]) {
          return Some(i + 3)
        }
      }
    }
    i = i + need + 1
  }
  None
}

///|
fn is_continuation(b : Byte) -> Bool {
  let u = b.to_uint()
  u >= 0x80 && u <= 0xBF
}

///|
/// Decode UTF-8 bytes into a `String`.
///
/// MoonBit strings are sequences of UTF-16 code units, and `Bytes::to_unchecked_string`
/// copies raw bytes rather than decoding them, so a real decoder is required.
/// The caller must have run `validate_utf8` first; this function does not
/// re-check and will produce garbage on malformed input.
pub fn decode_utf8(bytes : Bytes) -> String {
  let sb = StringBuilder()
  let len = bytes.length()
  let mut i = 0
  while i < len {
    let b0 = bytes[i].to_uint()
    if b0 < 0x80U {
      sb.write_char(b0.reinterpret_as_int().unsafe_to_char())
      i = i + 1
    } else if b0 < 0xE0U {
      let cp = ((b0 & 0x1FU) << 6) | (bytes[i + 1].to_uint() & 0x3FU)
      sb.write_char(cp.reinterpret_as_int().unsafe_to_char())
      i = i + 2
    } else if b0 < 0xF0U {
      let cp = ((b0 & 0x0FU) << 12) |
        ((bytes[i + 1].to_uint() & 0x3FU) << 6) |
        (bytes[i + 2].to_uint() & 0x3FU)
      sb.write_char(cp.reinterpret_as_int().unsafe_to_char())
      i = i + 3
    } else {
      let cp = ((b0 & 0x07U) << 18) |
        ((bytes[i + 1].to_uint() & 0x3FU) << 12) |
        ((bytes[i + 2].to_uint() & 0x3FU) << 6) |
        (bytes[i + 3].to_uint() & 0x3FU)
      sb.write_char(cp.reinterpret_as_int().unsafe_to_char())
      i = i + 4
    }
  }
  sb.to_string()
}
