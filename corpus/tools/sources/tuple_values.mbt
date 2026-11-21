// tuple_values — generated source for corpus/extended/tuple_values.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn swap(t : (Int, Int)) -> (Int, Int) { (t.1, t.0) }
fn main {
  let (a, b) = swap((3, 9))
  println(a * 10 + b)
}
