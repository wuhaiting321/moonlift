// match_option — generated source for corpus/extended/match_option.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn value(o : Int?) -> Int {
  match o {
    Some(x) => x * 2
    None => -1
  }
}
fn main { println(value(Some(21)) + value(None)) }
