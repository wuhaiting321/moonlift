// array_sum — generated source for corpus/extended/array_sum.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let a : Array[Int] = [1, 2, 3, 4, 5, 6, 7, 8]
  let mut acc = 0
  for x in a { acc += x }
  println(acc)
  println(a.length())
  println(a[3])
}
