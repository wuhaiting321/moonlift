// match_result — generated source for corpus/extended/match_result.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn value(r : Result[Int, String]) -> Int {
  match r {
    Ok(x) => x + 1
    Err(_) => -1
  }
}
fn main { println(value(Ok(41)) + value(Err("no"))) }
