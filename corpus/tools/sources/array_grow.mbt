// array_grow — generated source for corpus/extended/array_grow.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let a : Array[Int] = []
  let mut i = 0
  while i < 16 {
    a.push(i * 3)
    i += 1
  }
  println(a.length())
  println(a[15])
  a[15] = 99
  println(a[15])
}
