// loop_nested — generated source for corpus/extended/loop_nested.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let mut acc = 0
  for i in 0..<8 {
    for j in 0..<8 {
      acc += i * j
    }
  }
  println(acc)
}
