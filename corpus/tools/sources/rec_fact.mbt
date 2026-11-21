// rec_fact — generated source for corpus/extended/rec_fact.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn fact(n : Int) -> Int {
  if n < 2 { 1 } else { n * fact(n - 1) }
}
fn main { println(fact(10)) }
