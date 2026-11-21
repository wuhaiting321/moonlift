// trait_impl — generated source for corpus/extended/trait_impl.wasm
// Hand-written for moonlift; no upstream source. CC0.
trait Desc { describe(Self) -> Int }
struct Box { v : Int }
impl Desc for Box with describe(self) { self.v * 2 }
fn use_desc(d : Box) -> Int { d.describe() }
fn main { println(use_desc(Box::{ v: 21 })) }
