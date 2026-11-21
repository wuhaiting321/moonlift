// array_fixed — generated source for corpus/extended/array_fixed.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let a = FixedArray::make(12, 0)
  let mut i = 0
  while i < a.length() {
    a[i] = i * i
    i += 1
  }
  let mut acc = 0
  for x in a { acc += x }
  println(acc)
}
