// Behavioural smoke test for the package generated from `corpus/good/table.wasm`.
//
// This file is copied into the generated package by `script/check.sh`. Every
// expected value below came from running the *original* module in Node:
//
//   cd corpus/tools && node oracle.js ../good/table.wasm \
//     '[["apply",[0,10]],["apply",[1,10]],["apply_chain",[5]],["twice",[5]]]'
//
//   apply(0, 10) = 11    apply(1, 10) = 9
//   apply_chain(5) = 10  twice(5) = 7
//
// The table holds $inc, $dec, $dbl in slots 0..2; slot 3 is never initialised,
// which is why `apply(3, x)` traps and is not asserted here.

///|
test "apply dispatches through the element segment" {
  moonlift_init()
  inspect(apply(0, 10), content="11")
  inspect(apply(1, 10), content="9")
}

///|
test "a call whose result is consumed by another indirect call" {
  moonlift_init()
  inspect(apply_chain(5), content="10")
}

///|
test "a direct call to a function the table also holds" {
  moonlift_init()
  inspect(twice(5), content="7")
}
