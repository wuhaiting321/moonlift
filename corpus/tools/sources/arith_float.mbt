// arith_float — generated source for corpus/extended/arith_float.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let a : Float = (3.5 : Float)
  let b : Float = (1.25 : Float)
  println((a + b).to_double())
  println((a * b).to_double())
  println((a / b).to_double())
}
