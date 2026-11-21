// table_switch — generated source for corpus/extended/table_switch.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn dispatch(n : Int) -> Int {
  match n {
    0 => 10
    1 => 20
    2 => 30
    3 => 40
    4 => 50
    5 => 60
    6 => 70
    7 => 80
    _ => 90
  }
}
fn main { println(dispatch(3) + dispatch(7) + dispatch(99)) }
