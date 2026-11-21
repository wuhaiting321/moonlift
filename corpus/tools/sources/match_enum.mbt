// match_enum — generated source for corpus/extended/match_enum.wasm
// Hand-written for moonlift; no upstream source. CC0.
enum Color {
  Red
  Green
  Blue
}
fn code(c : Color) -> Int {
  match c {
    Red => 1
    Green => 2
    Blue => 3
  }
}
fn main { println(code(Red) + code(Green) + code(Blue)) }
