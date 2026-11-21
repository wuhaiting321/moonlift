// loop_while — generated source for corpus/extended/loop_while.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let mut i = 0
  let mut acc = 0
  while i < 20 {
    acc += i * i
    i += 1
  }
  println(acc)
}
