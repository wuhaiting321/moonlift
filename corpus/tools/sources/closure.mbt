// closure — generated source for corpus/extended/closure.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn apply(f : (Int) -> Int, x : Int) -> Int { f(x) }
fn main {
  let k = 7
  println(apply(fn(v) { v * k }, 6))
  println(apply(fn(v) { v + k }, 6))
}
