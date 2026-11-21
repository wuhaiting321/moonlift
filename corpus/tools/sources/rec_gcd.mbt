// rec_gcd — generated source for corpus/extended/rec_gcd.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn gcd(a : Int, b : Int) -> Int {
  if b == 0 { a } else { gcd(b, a % b) }
}
fn main { println(gcd(1071, 462)) }
