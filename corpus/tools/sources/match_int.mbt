// match_int — generated source for corpus/extended/match_int.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn classify(n : Int) -> Int {
  match n {
    0 => 100
    1 | 2 => 200
    3..=9 => 300
    _ => 400
  }
}
fn main { println(classify(0) + classify(5) + classify(50)) }
