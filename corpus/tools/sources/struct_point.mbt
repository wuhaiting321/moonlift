// struct_point — generated source for corpus/extended/struct_point.wasm
// Hand-written for moonlift; no upstream source. CC0.
struct Point { x : Int; y : Int }
fn norm(p : Point) -> Int { p.x * p.x + p.y * p.y }
fn main {
  let p = { x: 3, y: 4 }
  println(norm(p))
}
