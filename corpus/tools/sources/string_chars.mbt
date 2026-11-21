// string_chars — generated source for corpus/extended/string_chars.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let s = "moonbit"
  let mut acc = 0
  for c in s {
    acc += c.to_int()
  }
  println(acc)
}
