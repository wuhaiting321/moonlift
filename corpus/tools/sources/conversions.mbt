// conversions — generated source for corpus/extended/conversions.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn main {
  let i = 12345
  println(i.to_double())
  println(i.to_int64())
  let d = 3.75
  println(d.to_int())
  println(d.trunc())
  println(d.floor())
  println(d.ceil())
}
