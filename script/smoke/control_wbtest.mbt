// Behavioural smoke test for the package generated from `corpus/good/control.wasm`.
//
// Copied into the generated package by `script/check.sh`. The expectations come
// from the original module in Node:
//
//   cd corpus/tools && node oracle.js ../good/control.wasm \
//     '[["classify",[0]],["classify",[1]],["classify",[2]],["classify",[3]],
//       ["classify",[9]],["sum_to",[0]],["sum_to",[5]],["abs",[-7]],["abs",[7]],
//       ["guard",[5]],["find_limit",[3]],["find_limit",[9]],
//       ["max",[3,9]],["max",[9,3]]]'
//
// This fixture is the one built to exercise the structurer — a `block`, a
// `loop`, a `br_table`, a branch two constructs out, and an `if` whose arms
// rejoin — so it is where a wrong rewrite of control flow shows up first.
//
// `e_guard(0)` is `unreachable` in the original and traps there; the generated
// code traps at the same place, so it is asserted as a trap rather than a value.

///|
test "classify walks a br_table" {
  inspect(classify(0), content="200")
  inspect(classify(1), content="200")
  inspect(classify(2), content="300")
  inspect(classify(3), content="400")
  inspect(classify(9), content="400")
}

///|
test "sum_to runs a loop" {
  inspect(sum_to(0), content="0")
  inspect(sum_to(5), content="10")
}

///|
test "abs takes an if" {
  inspect(abs(-7), content="7")
  inspect(abs(7), content="7")
}

///|
test "guard returns the value it guards" {
  // The wasm export is `guard`, which is a MoonBit keyword, so the generated
  // wrapper is named `e_guard`.
  inspect(e_guard(5), content="5")
}

///|
test "find_limit branches two constructs out" {
  inspect(find_limit(3), content="-1")
  inspect(find_limit(9), content="7")
}

///|
test "max selects" {
  inspect(max(3, 9), content="9")
  inspect(max(9, 3), content="9")
}
