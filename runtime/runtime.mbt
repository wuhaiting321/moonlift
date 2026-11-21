// Runtime support for code emitted by `moonlift decompile`.
//
// This file is *copied verbatim* into every generated package, and it is also
// compiled here, as part of moonlift — so `moon check` validates the exact text
// that ships to the output. Nothing in it depends on the decompiler.
//
// The whole file exists because MoonBit and WebAssembly disagree on a handful
// of operations, and the disagreement is silent:
//
// | operation | wasm | MoonBit |
// |---|---|---|
// | `i32.div_s` by zero | trap | panic (wasm-gc) / infinity-ish (js) |
// | `i32.div_s` MIN/-1  | trap | trap on wasm-gc, MIN on js — *differs by backend* |
// | shifts by >= width | count & (width-1) | same on both backends (measured) |
// | `f64.nearest` | ties to even | `Double::round` ties away from zero |
//
// The first two rows are why every division goes through a helper instead of an
// operator, and the last is why rounding is implemented here rather than called.
// Everything else — add, sub, mul, and, or, xor, comparisons, `<<`, `>>` — is a
// plain operator in the emitted code, because it was measured to behave
// identically on wasm-gc and js (32-bit wrap, masked shift counts).

///|
/// WebAssembly's `unreachable`, and the destination of every trap.
///
/// Generic so it can stand where a value of any type is expected; `abort` does
/// not return, so it satisfies every signature.
pub fn[T] trap(msg : String) -> T {
  abort("moonlift: " + msg)
}

// --- integer division -----------------------------------------------------
//
// Signed division traps twice: on a zero divisor, and on MIN / -1, whose exact
// quotient does not fit. Both are traps in wasm, so both are traps here, and the
// message says which one it was — a decompiled program that traps for the same
// reason as the original is correct; one that returns a number is not.

///|
pub fn i32_div_s(a : Int32, b : Int32) -> Int32 {
  if b == 0 {
    return trap("i32.div_s by zero")
  }
  if a == -2147483648 && b == -1 {
    return trap("i32.div_s overflow")
  }
  a / b
}

///|
pub fn i32_div_u(a : Int32, b : Int32) -> Int32 {
  if b == 0 {
    return trap("i32.div_u by zero")
  }
  (a.reinterpret_as_uint() / b.reinterpret_as_uint()).reinterpret_as_int()
}

///|
pub fn i32_rem_s(a : Int32, b : Int32) -> Int32 {
  if b == 0 {
    return trap("i32.rem_s by zero")
  }
  // MIN % -1 is 0, and does *not* trap: only the quotient overflows.
  if a == -2147483648 && b == -1 {
    return 0
  }
  a % b
}

///|
pub fn i32_rem_u(a : Int32, b : Int32) -> Int32 {
  if b == 0 {
    return trap("i32.rem_u by zero")
  }
  (a.reinterpret_as_uint() % b.reinterpret_as_uint()).reinterpret_as_int()
}

///|
pub fn i64_div_s(a : Int64, b : Int64) -> Int64 {
  if b == 0L {
    return trap("i64.div_s by zero")
  }
  if a == -9223372036854775808L && b == -1L {
    return trap("i64.div_s overflow")
  }
  a / b
}

///|
pub fn i64_div_u(a : Int64, b : Int64) -> Int64 {
  if b == 0L {
    return trap("i64.div_u by zero")
  }
  (a.reinterpret_as_uint64() / b.reinterpret_as_uint64()).reinterpret_as_int64()
}

///|
pub fn i64_rem_s(a : Int64, b : Int64) -> Int64 {
  if b == 0L {
    return trap("i64.rem_s by zero")
  }
  if a == -9223372036854775808L && b == -1L {
    return 0L
  }
  a % b
}

///|
pub fn i64_rem_u(a : Int64, b : Int64) -> Int64 {
  if b == 0L {
    return trap("i64.rem_u by zero")
  }
  (a.reinterpret_as_uint64() % b.reinterpret_as_uint64()).reinterpret_as_int64()
}

// --- shifts and rotations -------------------------------------------------
//
// `<<` and `>>` already mask the count the way wasm does (measured: `1 << 33`
// is 2 on both backends), so only the *unsigned* shift needs help: MoonBit's
// `>>` is arithmetic, and an i32 with the top bit set has no unsigned value.

///|
pub fn i32_shr_u(a : Int32, n : Int32) -> Int32 {
  (a.reinterpret_as_uint() >> n).reinterpret_as_int()
}

///|
pub fn i64_shr_u(a : Int64, n : Int64) -> Int64 {
  (a.reinterpret_as_uint64() >> (n & 63L).to_int()).reinterpret_as_int64()
}

///|
pub fn i32_shl(a : Int32, n : Int32) -> Int32 {
  a << (n & 31)
}

///|
pub fn i32_shr_s(a : Int32, n : Int32) -> Int32 {
  a >> (n & 31)
}

///|
pub fn i64_shl(a : Int64, n : Int64) -> Int64 {
  // The count is an i64 on the wasm stack and is taken modulo 64, so the low six
  // bits are all that matter and the conversion cannot lose them.
  a << (n & 63L).to_int()
}

///|
pub fn i64_shr_s(a : Int64, n : Int64) -> Int64 {
  a >> (n & 63L).to_int()
}

///|
pub fn i32_rotl(a : Int32, n : Int32) -> Int32 {
  let s = n & 31
  if s == 0 {
    a
  } else {
    (a << s) | i32_shr_u(a, 32 - s)
  }
}

///|
pub fn i32_rotr(a : Int32, n : Int32) -> Int32 {
  let s = n & 31
  if s == 0 {
    a
  } else {
    i32_shr_u(a, s) | (a << (32 - s))
  }
}

///|
pub fn i64_rotl(a : Int64, n : Int64) -> Int64 {
  let s = (n & 63L).to_int()
  if s == 0 {
    a
  } else {
    (a << s) | i64_shr_u(a, (64 - s).to_int64())
  }
}

///|
pub fn i64_rotr(a : Int64, n : Int64) -> Int64 {
  let s = (n & 63L).to_int()
  if s == 0 {
    a
  } else {
    i64_shr_u(a, s.to_int64()) | (a << (64 - s))
  }
}

// --- bit counting ---------------------------------------------------------
//
// The counts come back as `Int` (== `Int32`), and i64 pushes them as i64.

///|
pub fn i64_clz(a : Int64) -> Int64 {
  a.clz().to_int64()
}

///|
pub fn i64_ctz(a : Int64) -> Int64 {
  a.ctz().to_int64()
}

///|
pub fn i64_popcnt(a : Int64) -> Int64 {
  a.popcnt().to_int64()
}

// --- sign extension -------------------------------------------------------

///|
pub fn i32_extend8_s(a : Int32) -> Int32 {
  a << 24 >> 24
}

///|
pub fn i32_extend16_s(a : Int32) -> Int32 {
  a << 16 >> 16
}

///|
pub fn i64_extend8_s(a : Int64) -> Int64 {
  a << 56 >> 56
}

///|
pub fn i64_extend16_s(a : Int64) -> Int64 {
  a << 48 >> 48
}

///|
pub fn i64_extend32_s(a : Int64) -> Int64 {
  a << 32 >> 32
}

// --- conversions ----------------------------------------------------------

///|
pub fn i64_extend_i32_u(a : Int32) -> Int64 {
  a.reinterpret_as_uint().to_uint64().reinterpret_as_int64()
}

///|
pub fn f32_convert_i32_u(a : Int32) -> Float {
  Float::from_uint(a.reinterpret_as_uint())
}

///|
pub fn f64_convert_i32_u(a : Int32) -> Double {
  a.reinterpret_as_uint().to_double()
}

///|
pub fn f32_convert_i64_u(a : Int64) -> Float {
  Float::from_uint64(a.reinterpret_as_uint64())
}

///|
pub fn f64_convert_i64_u(a : Int64) -> Double {
  a.reinterpret_as_uint64().to_double()
}

///|
pub fn f32_nearest(a : Float) -> Float {
  Float::from_double(nearest_double(a.to_double()))
}

///|
pub fn f64_nearest(a : Double) -> Double {
  nearest_double(a)
}

///|
/// Round to the nearest integer, ties to even — what wasm's `nearest` means and
/// what MoonBit's `round` does not do (it rounds halves away from zero).
///
/// The trick is that `floor(x + 0.5)` is ties-up, so a value that *is* a tie is
/// detected separately by asking whether the fractional part is exactly one half
/// and, if so, whether the floor is odd. Only that case is nudged.
fn nearest_double(a : Double) -> Double {
  if a.is_nan() || a.is_inf() {
    return a
  }
  let f = a.floor()
  let d = a - f
  if d > 0.5 {
    f + 1.0
  } else if d < 0.5 {
    f
  } else if f % 2.0 == 0.0 {
    f
  } else {
    f + 1.0
  }
}

// --- trapping float-to-int truncation -------------------------------------
//
// wasm traps when the value is NaN or outside the destination range, and the
// bounds are exact halves: `-2147483648.0` converts, `2147483648.0` does not.
// MoonBit's `to_int` truncates without checking, so the check is here, and it is
// done in floating point against the exact bound — comparing after conversion
// would be too late.

///|
/// The trap test for `i32.trunc_*`.
///
/// The bound is not `-2^31`: truncation rounds *toward zero*, so
/// `-2147483648.9` truncates to `-2147483648`, which is representable. A check
/// written against the raw input would trap there, and the difference is a
/// program that dies where the original returned a number. The lower bound is
/// therefore one *below* the minimum, and the comparison is inclusive.
fn check_trunc_i32(x : Double, signed : Bool, what : String) -> Unit {
  if x.is_nan() {
    trap("\{what}: NaN")
  }
  if signed {
    if x <= -2147483649.0 || x >= 2147483648.0 {
      trap("\{what}: out of range")
    }
  } else if x <= -1.0 || x >= 4294967296.0 {
    trap("\{what}: out of range")
  }
}

///|
/// The same test for 64-bit results.
///
/// Here the bound is *exclusive*: `-2^63` is representable in f64 and is a legal
/// result, and the next f64 below it is 2048 away, so `x < -2^63` is the precise
/// condition — writing `x <= -2^63 - 1` would round back to `-2^63` and trap on
/// a value that converts.
fn check_trunc_i64(x : Double, signed : Bool, what : String) -> Unit {
  if x.is_nan() {
    trap("\{what}: NaN")
  }
  if signed {
    if x < -9223372036854775808.0 || x >= 9223372036854775808.0 {
      trap("\{what}: out of range")
    }
  } else if x <= -1.0 || x >= 18446744073709551616.0 {
    trap("\{what}: out of range")
  }
}

///|
pub fn i32_trunc_f32_s(a : Float) -> Int32 {
  let x = a.to_double()
  check_trunc_i32(x, true, "i32.trunc_f32_s")
  x.to_int()
}

///|
pub fn i32_trunc_f32_u(a : Float) -> Int32 {
  let x = a.to_double()
  check_trunc_i32(x, false, "i32.trunc_f32_u")
  x.to_int64().to_int()
}

///|
pub fn i32_trunc_f64_s(a : Double) -> Int32 {
  check_trunc_i32(a, true, "i32.trunc_f64_s")
  a.to_int()
}

///|
pub fn i32_trunc_f64_u(a : Double) -> Int32 {
  check_trunc_i32(a, false, "i32.trunc_f64_u")
  a.to_int64().to_int()
}

///|
pub fn i64_trunc_f32_s(a : Float) -> Int64 {
  let x = a.to_double()
  check_trunc_i64(x, true, "i64.trunc_f32_s")
  x.to_int64()
}

///|
pub fn i64_trunc_f32_u(a : Float) -> Int64 {
  let x = a.to_double()
  check_trunc_i64(x, false, "i64.trunc_f32_u")
  x.to_int64()
}

///|
pub fn i64_trunc_f64_s(a : Double) -> Int64 {
  check_trunc_i64(a, true, "i64.trunc_f64_s")
  a.to_int64()
}

///|
pub fn i64_trunc_f64_u(a : Double) -> Int64 {
  check_trunc_i64(a, false, "i64.trunc_f64_u")
  a.to_int64()
}

// Saturating truncation never traps: NaN becomes 0, and out-of-range saturates
// to the nearest representable end. Both halves are needed, because the
// non-saturating versions above are silent about which end was missed.

///|
fn saturate(x : Double, lo : Double, hi : Double) -> Double {
  if x.is_nan() {
    0.0
  } else if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
pub fn i32_trunc_sat_f32_s(a : Float) -> Int32 {
  saturate(a.to_double(), -2147483648.0, 2147483647.0).to_int()
}

///|
pub fn i32_trunc_sat_f32_u(a : Float) -> Int32 {
  saturate(a.to_double(), 0.0, 4294967295.0).to_int64().to_int()
}

///|
pub fn i32_trunc_sat_f64_s(a : Double) -> Int32 {
  saturate(a, -2147483648.0, 2147483647.0).to_int()
}

///|
pub fn i32_trunc_sat_f64_u(a : Double) -> Int32 {
  saturate(a, 0.0, 4294967295.0).to_int64().to_int()
}

///|
pub fn i64_trunc_sat_f32_s(a : Float) -> Int64 {
  saturate(a.to_double(), -9223372036854775808.0, 9223372036854775807.0).to_int64()
}

///|
pub fn i64_trunc_sat_f32_u(a : Float) -> Int64 {
  saturate(a.to_double(), 0.0, 18446744073709551615.0).to_int64()
}

///|
pub fn i64_trunc_sat_f64_s(a : Double) -> Int64 {
  saturate(a, -9223372036854775808.0, 9223372036854775807.0).to_int64()
}

///|
pub fn i64_trunc_sat_f64_u(a : Double) -> Int64 {
  saturate(a, 0.0, 18446744073709551615.0).to_int64()
}

// --- memory ---------------------------------------------------------------
//
// One linear memory, little-endian, bounds-checked on every access: an access
// past the end is a wasm trap, and a generated program that reads whatever
// happens to follow the array would be wrong in the worst way — silently.

///|

///|
/// The largest memory this representation can hold: 32,767 pages, just under
/// 2 GiB. A MoonBit array is indexed by `Int`, so anything larger does not fit —
/// `grow` reports -1 rather than dying inside an allocation.
let page_limit : Int64 = 32767

///|
pub struct Memory {
  mut data : FixedArray[Byte]
  mut pages : Int32
  max_pages : Int32
}

///|
pub fn Memory::new(pages : Int32, max_pages : Int32) -> Memory {
  let p = if max_pages < pages { pages } else { max_pages }
  { data: FixedArray::make(pages * 65536, b'\x00'), pages, max_pages: p, }
}

///|
pub fn Memory::size(self : Memory) -> Int32 {
  self.pages
}

///|
/// `memory.grow`: returns the previous size in pages, or -1 when the request
/// cannot be met. The new pages are zero-filled, as the spec requires.
pub fn Memory::grow(self : Memory, delta : Int32) -> Int32 {
  let old = self.pages
  // Every comparison below is done in 64 bits. `grow(2147483647)` on a
  // one-page memory is a legal call that must answer -1, and `old + delta` in
  // 32 bits wraps to a negative number that passes a `>` test and then asks for
  // an array with a negative length.
  let want = old.to_int64() + delta.to_int64()
  if delta < 0 || want > self.max_pages.to_int64() {
    return -1
  }
  // A MoonBit array is indexed by `Int`, so 2 GiB is the ceiling here as well as
  // in practice. Past it the honest answer is the one wasm gives when the host
  // cannot provide the memory: -1, not a trap and not an allocation that dies.
  if want > page_limit {
    return -1
  }
  if delta == 0 {
    return old
  }
  let fresh = FixedArray::make(want.to_int() * 65536, b'\x00')
  let mut i = 0
  let n = old * 65536
  while i < n {
    fresh[i] = self.data[i]
    i = i + 1
  }
  self.data = fresh
  self.pages = want.to_int()
  old
}

///|
fn Memory::check(self : Memory, a : Int32, n : Int32) -> Unit {
  // 64-bit again: `a + n` for an address near 2^31 wraps negative and would wave
  // through an access that the spec says traps.
  let end = a.to_int64() + n.to_int64()
  if a < 0 || end > self.data.length().to_int64() {
    trap("out of bounds memory access")
  }
}

///|
fn Memory::byte_at(self : Memory, a : Int32) -> Int32 {
  self.data[a].to_int()
}

///|
fn Memory::put(self : Memory, a : Int32, v : Int32) -> Unit {
  self.data[a] = v.to_byte()
}

///|
pub fn Memory::load_i32(self : Memory, a : Int32) -> Int32 {
  self.check(a, 4)
  self.byte_at(a) |
  (self.byte_at(a + 1) << 8) |
  (self.byte_at(a + 2) << 16) |
  (self.byte_at(a + 3) << 24)
}

///|
pub fn Memory::load_i32_8u(self : Memory, a : Int32) -> Int32 {
  self.check(a, 1)
  self.byte_at(a)
}

///|
pub fn Memory::load_i32_8s(self : Memory, a : Int32) -> Int32 {
  i32_extend8_s(self.load_i32_8u(a))
}

///|
pub fn Memory::load_i32_16u(self : Memory, a : Int32) -> Int32 {
  self.check(a, 2)
  self.byte_at(a) | (self.byte_at(a + 1) << 8)
}

///|
pub fn Memory::load_i32_16s(self : Memory, a : Int32) -> Int32 {
  i32_extend16_s(self.load_i32_16u(a))
}

///|
pub fn Memory::load_i64(self : Memory, a : Int32) -> Int64 {
  self.check(a, 8)
  let mut v = 0L
  let mut i = 7
  while i >= 0 {
    v = (v << 8) | self.byte_at(a + i).to_int64()
    i = i - 1
  }
  v
}

///|
pub fn Memory::load_i64_8u(self : Memory, a : Int32) -> Int64 {
  self.load_i32_8u(a).to_int64()
}

///|
pub fn Memory::load_i64_8s(self : Memory, a : Int32) -> Int64 {
  self.load_i32_8s(a).to_int64()
}

///|
pub fn Memory::load_i64_16u(self : Memory, a : Int32) -> Int64 {
  self.load_i32_16u(a).to_int64()
}

///|
pub fn Memory::load_i64_16s(self : Memory, a : Int32) -> Int64 {
  self.load_i32_16s(a).to_int64()
}

///|
pub fn Memory::load_i64_32u(self : Memory, a : Int32) -> Int64 {
  self.load_i32(a).reinterpret_as_uint().to_uint64().reinterpret_as_int64()
}

///|
pub fn Memory::load_i64_32s(self : Memory, a : Int32) -> Int64 {
  self.load_i32(a).to_int64()
}

///|
pub fn Memory::load_f32(self : Memory, a : Int32) -> Float {
  Float::reinterpret_from_int(self.load_i32(a))
}

///|
pub fn Memory::load_f64(self : Memory, a : Int32) -> Double {
  Int64::reinterpret_as_double(self.load_i64(a))
}

///|
pub fn Memory::store_i32(self : Memory, a : Int32, v : Int32) -> Unit {
  self.check(a, 4)
  self.put(a, v)
  self.put(a + 1, v >> 8)
  self.put(a + 2, v >> 16)
  self.put(a + 3, v >> 24)
}

///|
pub fn Memory::store_i32_8(self : Memory, a : Int32, v : Int32) -> Unit {
  self.check(a, 1)
  self.put(a, v)
}

///|
pub fn Memory::store_i32_16(self : Memory, a : Int32, v : Int32) -> Unit {
  self.check(a, 2)
  self.put(a, v)
  self.put(a + 1, v >> 8)
}

///|
pub fn Memory::store_i64(self : Memory, a : Int32, v : Int64) -> Unit {
  self.check(a, 8)
  let mut x = v
  let mut i = 0
  while i < 8 {
    self.put(a + i, x.to_int())
    x = x >> 8
    i = i + 1
  }
}

///|
pub fn Memory::store_i64_8(self : Memory, a : Int32, v : Int64) -> Unit {
  self.check(a, 1)
  self.put(a, v.to_int())
}

///|
pub fn Memory::store_i64_16(self : Memory, a : Int32, v : Int64) -> Unit {
  self.check(a, 2)
  self.put(a, v.to_int())
  self.put(a + 1, (v >> 8).to_int())
}

///|
pub fn Memory::store_i64_32(self : Memory, a : Int32, v : Int64) -> Unit {
  self.check(a, 4)
  let mut x = v
  let mut i = 0
  while i < 4 {
    self.put(a + i, x.to_int())
    x = x >> 8
    i = i + 1
  }
}

///|
pub fn Memory::store_f32(self : Memory, a : Int32, v : Float) -> Unit {
  self.store_i32(a, v.reinterpret_as_int())
}

///|
pub fn Memory::store_f64(self : Memory, a : Int32, v : Double) -> Unit {
  self.store_i64(a, v.reinterpret_as_int64())
}

///|
/// Copy a data segment in. `src` is a byte string literal in the generated code,
/// so the initial memory image is visible in the source rather than hidden in a
/// separate resource.
pub fn Memory::init_bytes(self : Memory, offset : Int32, src : Bytes) -> Unit {
  self.check(offset, src.length())
  let mut i = 0
  while i < src.length() {
    self.data[offset + i] = src.at(i)
    i = i + 1
  }
}

// --- comparison and selection ---------------------------------------------
//
// Signed comparison is the language's `<`, but unsigned comparison has to go
// through the unsigned type: `-1 < 1` is true as integers and false as u32, and
// wasm means the second one.

///|
pub fn i32_lt_u(a : Int32, b : Int32) -> Bool {
  a.reinterpret_as_uint() < b.reinterpret_as_uint()
}

///|
pub fn i32_le_u(a : Int32, b : Int32) -> Bool {
  a.reinterpret_as_uint() <= b.reinterpret_as_uint()
}

///|
pub fn i32_gt_u(a : Int32, b : Int32) -> Bool {
  a.reinterpret_as_uint() > b.reinterpret_as_uint()
}

///|
pub fn i32_ge_u(a : Int32, b : Int32) -> Bool {
  a.reinterpret_as_uint() >= b.reinterpret_as_uint()
}

///|
pub fn i64_lt_u(a : Int64, b : Int64) -> Bool {
  a.reinterpret_as_uint64() < b.reinterpret_as_uint64()
}

///|
pub fn i64_le_u(a : Int64, b : Int64) -> Bool {
  a.reinterpret_as_uint64() <= b.reinterpret_as_uint64()
}

///|
pub fn i64_gt_u(a : Int64, b : Int64) -> Bool {
  a.reinterpret_as_uint64() > b.reinterpret_as_uint64()
}

///|
pub fn i64_ge_u(a : Int64, b : Int64) -> Bool {
  a.reinterpret_as_uint64() >= b.reinterpret_as_uint64()
}

///|
pub fn i32_min_s(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
pub fn i32_max_s(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
pub fn i32_min_u(a : Int32, b : Int32) -> Int32 {
  if i32_lt_u(a, b) {
    a
  } else {
    b
  }
}

///|
pub fn i32_max_u(a : Int32, b : Int32) -> Int32 {
  if i32_gt_u(a, b) {
    a
  } else {
    b
  }
}

///|
pub fn i64_min_s(a : Int64, b : Int64) -> Int64 {
  if a < b {
    a
  } else {
    b
  }
}

///|
pub fn i64_max_s(a : Int64, b : Int64) -> Int64 {
  if a > b {
    a
  } else {
    b
  }
}

///|
pub fn i64_min_u(a : Int64, b : Int64) -> Int64 {
  if i64_lt_u(a, b) {
    a
  } else {
    b
  }
}

///|
pub fn i64_max_u(a : Int64, b : Int64) -> Int64 {
  if i64_gt_u(a, b) {
    a
  } else {
    b
  }
}

// --- float bit operations -------------------------------------------------
//
// `abs`, `neg` and `copysign` are defined on the *bits*, not on the value: they
// have to leave a NaN's payload alone and tell `-0` from `0`. Whatever the host
// `abs` does with `-0` is irrelevant here, because the comparison a differential
// test makes is on bits.

///|
pub fn f32_abs(a : Float) -> Float {
  Float::reinterpret_from_int(a.reinterpret_as_int() & 0x7FFFFFFF)
}

///|
pub fn f32_neg(a : Float) -> Float {
  Float::reinterpret_from_int(a.reinterpret_as_int() ^ 0x80000000)
}

///|
pub fn f64_abs(a : Double) -> Double {
  Int64::reinterpret_as_double(a.reinterpret_as_int64() & 0x7FFFFFFFFFFFFFFFL)
}

///|
pub fn f64_neg(a : Double) -> Double {
  Int64::reinterpret_as_double(a.reinterpret_as_int64() ^ -9223372036854775808L)
}

///|
pub fn f32_copysign(a : Float, b : Float) -> Float {
  let sign = b.reinterpret_as_int() & 0x80000000
  Float::reinterpret_from_int((a.reinterpret_as_int() & 0x7FFFFFFF) | sign)
}

///|
pub fn f64_copysign(a : Double, b : Double) -> Double {
  let sign = b.reinterpret_as_int64() & -9223372036854775808L
  Int64::reinterpret_as_double(
    (a.reinterpret_as_int64() & 0x7FFFFFFFFFFFFFFFL) | sign,
  )
}

// wasm's min/max are not the host's: a NaN in either operand makes the result
// NaN (rather than the other operand), and when both are zero the sign decides,
// so `min(0, -0)` is `-0`. Both rules matter to a program that compares bits.

///|
fn f32_nan() -> Float {
  Float::reinterpret_from_int(0x7FC00000)
}

///|
fn f64_nan() -> Double {
  Int64::reinterpret_as_double(0x7FF8000000000000L)
}

///|
pub fn f32_min(a : Float, b : Float) -> Float {
  if a.is_nan() || b.is_nan() {
    f32_nan()
  } else if a == 0.0 && b == 0.0 {
    if a.reinterpret_as_int() < 0 || b.reinterpret_as_int() < 0 {
      Float::reinterpret_from_int(0x80000000)
    } else {
      0.0
    }
  } else if a < b {
    a
  } else {
    b
  }
}

///|
pub fn f32_max(a : Float, b : Float) -> Float {
  if a.is_nan() || b.is_nan() {
    f32_nan()
  } else if a == 0.0 && b == 0.0 {
    if a.reinterpret_as_int() < 0 && b.reinterpret_as_int() < 0 {
      Float::reinterpret_from_int(0x80000000)
    } else {
      0.0
    }
  } else if a > b {
    a
  } else {
    b
  }
}

///|
pub fn f64_min(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    f64_nan()
  } else if a == 0.0 && b == 0.0 {
    if a.reinterpret_as_int64() < 0L || b.reinterpret_as_int64() < 0L {
      Int64::reinterpret_as_double(-9223372036854775808L)
    } else {
      0.0
    }
  } else if a < b {
    a
  } else {
    b
  }
}

///|
pub fn f64_max(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    f64_nan()
  } else if a == 0.0 && b == 0.0 {
    if a.reinterpret_as_int64() < 0L && b.reinterpret_as_int64() < 0L {
      Int64::reinterpret_as_double(-9223372036854775808L)
    } else {
      0.0
    }
  } else if a > b {
    a
  } else {
    b
  }
}
