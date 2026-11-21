// generic — generated source for corpus/extended/generic.wasm
// Hand-written for moonlift; no upstream source. CC0.
fn[T] twice(x : T, f : (T) -> T) -> T { f(f(x)) }
fn main { println(twice(3, fn(v) { v + 1 })) }
