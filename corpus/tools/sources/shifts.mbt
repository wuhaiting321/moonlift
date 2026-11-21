// shifts — generated source for corpus/extended/shifts.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let x = 0x12345678
  println(x << 4)
  println(x >> 4)
  println(x & 0xFF)
  println(x ^ 0xFF)
  println(x.clz())
  println(x.ctz())
}
