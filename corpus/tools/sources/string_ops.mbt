// string_ops — generated source for corpus/extended/string_ops.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let a = "moon"
  let b = "lift"
  let c = a + b
  println(c)
  println(c.length())
  println(c.substring(start=1, end=5))
  println(c.starts_with("oon"))
}
