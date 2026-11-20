///|
/// Tests for the runtime that ships inside every generated package.
///
/// Only the non-trapping paths are tested here: a trap is `abort`, which ends
/// the test process rather than failing a case. The trapping paths are exercised
/// from the CLI instead, where a trap is an observable exit (see
/// `script/check.sh`), and by the differential harness, where a program that
/// should trap and does not is a mismatch.

///|
/// NaN and the infinities, built from their bits: the constants live in another
/// package, and importing it just for three values would put an unused import in
/// the package that ships to the output.
fn a_nan() -> Double {
  Int64::reinterpret_as_double(0x7FF8000000000000L)
}

///|
fn nan_free_inf() -> Double {
  Int64::reinterpret_as_double(0x7FF0000000000000L)
}

///|
fn neg_inf() -> Double {
  Int64::reinterpret_as_double(0xFFF0000000000000L)
}

///|
test "runtime: rounding is ties-to-even, not ties-away-from-zero" {
  // The four cases that separate the two rules. `Double::round` would give 3, 4,
  // -3, 1 here — every one of them a silent disagreement with wasm.
  assert_eq(f64_nearest(2.5), 2.0)
  assert_eq(f64_nearest(3.5), 4.0)
  assert_eq(f64_nearest(-2.5), -2.0)
  assert_eq(f64_nearest(0.5), 0.0)
  // And the ones where both rules agree, so a wrong implementation would still
  // pass the four above if it was wrong in a different way.
  assert_eq(f64_nearest(2.4), 2.0)
  assert_eq(f64_nearest(2.6), 3.0)
  assert_eq(f64_nearest(-2.6), -3.0)
  assert_eq(f64_nearest(7.0), 7.0)
}

///|
test "runtime: nearest leaves infinities and NaN alone" {
  assert_true(f64_nearest(nan_free_inf()).is_inf())
  assert_true(f64_nearest(neg_inf()).is_neg_inf())
  assert_true(f64_nearest(a_nan()).is_nan())
}

///|
test "runtime: division returns the truncated quotient, like wasm" {
  assert_eq(i32_div_s(7, 2), 3)
  assert_eq(i32_div_s(-7, 2), -3)
  assert_eq(i32_div_s(7, -2), -3)
  // MIN % -1 is 0 and does not trap; only the quotient overflows.
  assert_eq(i32_rem_s(-2147483648, -1), 0)
  assert_eq(i32_rem_s(-7, 2), -1)
  assert_eq(i32_div_u(-1, 2), 2147483647)
  assert_eq(i32_rem_u(-1, 2), 1)
  assert_eq(i64_div_s(7L, 2L), 3L)
  assert_eq(i64_rem_s(-7L, 2L), -1L)
}

///|
test "runtime: unsigned shift of a negative i32" {
  // `>>` is arithmetic, so -8 >> 1 is -4; `i32.shr_u` has to give 2147483644.
  assert_eq(i32_shr_u(-8, 1), 2147483644)
  assert_eq(i32_shr_s(-8, 1), -4)
  // Shift counts are taken modulo the width, on both backends.
  assert_eq(i32_shl(1, 33), 2)
  assert_eq(i32_shr_u(1, 32), 1)
  assert_eq(i64_shr_u(-8L, 1L), 9223372036854775804L)
  assert_eq(i64_shl(1L, 65L), 2L)
}

///|
test "runtime: rotations wrap within the width" {
  assert_eq(i32_rotl(0x80000000, 1), 1)
  assert_eq(i32_rotr(1, 1), -2147483648)
  // A rotation by a multiple of the width, and by more than the width, are both
  // the identity after masking.
  assert_eq(i32_rotl(0x12345678, 0), 0x12345678)
  assert_eq(i32_rotl(0x12345678, 32), 0x12345678)
  assert_eq(i32_rotl(0x12345678, 36), i32_rotl(0x12345678, 4))
  assert_eq(i64_rotl(1L, 1L), 2L)
  assert_eq(i64_rotr(1L, 1L), -9223372036854775808L)
  assert_eq(i64_rotr(i64_rotl(7L, 13L), 13L), 7L)
}

///|
test "runtime: sign extension matches the width it names" {
  assert_eq(i32_extend8_s(0xFF), -1)
  assert_eq(i32_extend8_s(0x7F), 127)
  assert_eq(i32_extend16_s(0xFFFF), -1)
  assert_eq(i32_extend16_s(0x8000), -32768)
  assert_eq(i64_extend8_s(0xFFL), -1L)
  assert_eq(i64_extend32_s(0xFFFFFFFFL), -1L)
  assert_eq(i64_extend32_s(0x7FFFFFFFL), 2147483647L)
}

///|
test "runtime: truncation checks the exact half-open bound" {
  // The bound that matters: 2147483648.0 is representable exactly in f64 and is
  // one past the largest i32, so it must trap — but 2147483647.9 does not.
  assert_eq(i32_trunc_f64_s(2147483647.9), 2147483647)
  assert_eq(i32_trunc_f64_s(-2147483648.9), -2147483648)
  assert_eq(i64_trunc_f64_s(-7.9), -7L)
}

///|
test "runtime: saturating truncation saturates instead of trapping" {
  assert_eq(i32_trunc_sat_f64_s(a_nan()), 0)
  assert_eq(i32_trunc_sat_f64_s(1.0e30), 2147483647)
  assert_eq(i32_trunc_sat_f64_s(-1.0e30), -2147483648)
  assert_eq(i32_trunc_sat_f64_u(-5.0), 0)
  assert_eq(i64_trunc_sat_f32_s(Float::reinterpret_from_int(0x7FC00000)), 0L)
  // The unsigned 32-bit case is the one whose *result* is a wrapped i32: a value
  // near 2^32 has to come back as a negative `Int` with the same bits.
  assert_eq(i32_trunc_f64_u(4294967295.0), -1)
  assert_eq(i32_trunc_f64_u(2147483648.0), -2147483648)
  assert_eq(i64_trunc_sat_f64_s(1.0e30), 9223372036854775807L)
}

///|
test "runtime: memory is little-endian in both directions" {
  let m = Memory::new(1, 1)
  m.store_i32(0, 0x12345678)
  assert_eq(m.byte_at(0), 0x78)
  assert_eq(m.byte_at(3), 0x12)
  assert_eq(m.load_i32(0), 0x12345678)
  m.store_i64(8, 0x0102030405060708L)
  assert_eq(m.byte_at(8), 0x08)
  assert_eq(m.byte_at(15), 0x01)
  assert_eq(m.load_i64(8), 0x0102030405060708L)
}

///|
test "runtime: narrow loads sign- and zero-extend" {
  let m = Memory::new(1, 1)
  m.store_i32_8(0, 0xFF)
  assert_eq(m.load_i32_8u(0), 255)
  assert_eq(m.load_i32_8s(0), -1)
  assert_eq(m.load_i64_8u(0), 255L)
  assert_eq(m.load_i64_8s(0), -1L)
  m.store_i32_16(4, 0x8000)
  assert_eq(m.load_i32_16u(4), 32768)
  assert_eq(m.load_i32_16s(4), -32768)
  m.store_i64(8, -1L)
  assert_eq(m.load_i64_32s(8), -1L)
  // The 32-bit load of the same bytes is unsigned-extended by `_32u`.
  assert_eq(m.load_i64_32u(8), 4294967295L)
}

///|
test "runtime: floats survive a round trip through memory bit for bit" {
  let m = Memory::new(1, 1)
  m.store_f32(0, 3.25)
  assert_eq(m.load_f32(0), 3.25)
  m.store_f64(8, -1.0 / 3.0)
  assert_eq(m.load_f64(8), -1.0 / 3.0)
  // NaN is the case a conversion could silently normalise; the payload has to
  // survive, so the bits are compared rather than the value.
  m.store_f32(0, Float::reinterpret_from_int(0x7FC00001))
  assert_eq(m.load_f32(0).reinterpret_as_int(), 0x7FC00001)
}

///|
test "runtime: grow returns the old size and zero-fills" {
  let m = Memory::new(1, 4)
  assert_eq(m.size(), 1)
  m.store_i32(0, 7)
  assert_eq(m.grow(1), 1)
  assert_eq(m.size(), 2)
  // The old contents survive, and the new page is zero — the spec requires both.
  assert_eq(m.load_i32(0), 7)
  assert_eq(m.load_i32(65536), 0)
  // Past the limit, `grow` reports failure instead of trapping: a program that
  // checks the result keeps running, which is what the original did.
  assert_eq(m.grow(100), -1)
  assert_eq(m.size(), 2)
}

///|
test "runtime: the i64 shift operators mask the count too" {
  // Relied on by the emitter, which prints `<<` and `>>` rather than a helper
  // call. If this ever stops holding on one backend, the gate says so.
  assert_eq(1L << 65, 2L)
  assert_eq(-8L >> 1, -4L)
  let big : Int64 = 1L
  assert_eq(big << 64, 1L)
}

///|
test "runtime: wasm min/max disagree with the host on zeros and NaN" {
  // `min(0, -0)` is -0 in wasm, because the sign decides when the values are
  // equal; a host `min` that returns the first operand would give +0.
  let mz = f64_min(0.0, -0.0)
  assert_eq(mz.reinterpret_as_int64(), -9223372036854775808L)
  let xz = f64_max(0.0, -0.0)
  assert_eq(xz.reinterpret_as_int64(), 0L)
  // A NaN in either side makes the result NaN, not the other operand.
  assert_true(f32_min(1.0, f32_nan_from_bits()).is_nan())
  assert_true(f64_max(f64_nan_from_bits(), 1.0).is_nan())
  // Otherwise it is the ordinary comparison.
  assert_eq(f32_min(1.0, 2.0), 1.0)
  assert_eq(f64_max(1.0, 2.0), 2.0)
}

///|
fn f32_nan_from_bits() -> Float {
  Float::reinterpret_from_int(0x7FC00000)
}

///|
fn f64_nan_from_bits() -> Double {
  Int64::reinterpret_as_double(0x7FF8000000000000L)
}

///|
test "runtime: abs, neg and copysign work on the sign bit" {
  // -0.0 is the case that separates bit arithmetic from value arithmetic.
  assert_eq(f64_abs(-0.0).reinterpret_as_int64(), 0L)
  assert_eq(f64_neg(0.0).reinterpret_as_int64(), -9223372036854775808L)
  assert_eq(f32_abs(-0.0).reinterpret_as_int(), 0)
  assert_eq(f32_neg(0.0).reinterpret_as_int(), -2147483648)
  // copysign takes the magnitude of the first and the sign of the second.
  assert_eq(f32_copysign(-3.0, 1.0), 3.0)
  assert_eq(f32_copysign(3.0, -1.0), -3.0)
  assert_eq(f64_copysign(-3.0, -0.0).reinterpret_as_int64() < 0L, true)
}

///|
test "runtime: unsigned comparison is not signed comparison" {
  assert_true(i32_lt_u(1, -1))
  assert_false(i32_lt_u(-1, 1))
  assert_true(i32_ge_u(-1, 1))
  assert_eq(i32_min_u(-1, 1), 1)
  assert_eq(i32_max_u(-1, 1), -1)
  assert_eq(i32_min_s(-1, 1), -1)
  assert_eq(i32_max_s(-1, 1), 1)
  assert_eq(i64_min_u(-1L, 1L), 1L)
  assert_eq(i64_max_s(-1L, 1L), 1L)
}

///|
/// A `grow` past the representable size must answer -1, not trap and not ask for
/// an array it cannot have.
///
/// Found by the differential harness: `memory.wasm` exports `memory.grow`, one
/// planned call passed 2147483647, and `pages + delta` in 32 bits wrapped
/// negative — passing the limit test and dying inside the allocation. The
/// original module answers -1, so this was a decompiler bug that only showed up
/// when the two implementations were compared.
test "memory: grow refuses a size it cannot represent" {
  let m = Memory::new(1, 65536)
  // 2^31 - 1 pages is the call that wrapped.
  inspect(m.grow(2147483647), content="-1")
  // A negative delta is refused by the spec, not silently treated as a shrink.
  inspect(m.grow(-1), content="-1")
  // The ceiling itself: 40,000 pages is under `max_pages` but over what an
  // `Int`-indexed array can hold, so it is refused without allocating.
  inspect(m.grow(40000), content="-1")
  inspect(m.size(), content="1")
  // And a legal grow still works, returning the *old* size.
  inspect(m.grow(0), content="1")
  inspect(m.grow(1), content="1")
  inspect(m.size(), content="2")
}
