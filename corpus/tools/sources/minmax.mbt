// minmax — generated source for corpus/extended/minmax.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn smaller(a : Int, b : Int) -> Int { if a < b { a } else { b } }
fn larger(a : Int, b : Int) -> Int { if a > b { a } else { b } }
fn absolute(a : Int) -> Int { if a < 0 { 0 - a } else { a } }
fn main {
  println(smaller(3, 9))
  println(larger(3, 9))
  println(smaller(-7, -2))
  println(larger(-7, -2))
  println(absolute(-42))
}
