// cmp_float — generated source for corpus/extended/cmp_float.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let a = 2.5
  let b = 2.5000001
  println(a < b)
  println(a >= b)
  println(a == b)
  println(a.is_nan())
  println(a.is_inf())
}
