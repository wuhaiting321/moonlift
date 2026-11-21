// loop_break — generated source for corpus/extended/loop_break.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let mut i = 0
  let mut acc = 0
  while true {
    i += 1
    if i % 3 == 0 { continue }
    if i > 25 { break }
    acc += i
  }
  println(acc)
}
