// globals_counter — generated source for corpus/extended/globals_counter.wasm
// Hand-written for moonlift; no upstream source. CC0.
let counter : Array[Int] = [0]
fn bump() -> Int {
  counter[0] = counter[0] + 1
  counter[0]
}
fn main {
  let mut acc = 0
  let mut i = 0
  while i < 10 { acc += bump(); i += 1 }
  println(acc)
  println(counter[0])
}
