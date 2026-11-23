// Behavioural smoke test for the package generated from `corpus/good/indirect.wasm`.
//
// This file is copied into the generated package by `script/check.sh`. Every
// expected value below came from running the *original* module in Node:
//
//   cd corpus/tools && node oracle.js ../good/indirect.wasm \
//     '[["apply1",[0,10]],["apply1",[1,10]],["apply2",[2,3,4]],
//       ["apply2",[3,3,4]],["apply0",[4]],["vt",[0,10]],["vt",[1,10]],
//       ["chain",[5]],["mixed",[5]],["loopdispatch",[0,5]],["loopdispatch",[3,4]]]'
//
//   apply1(0,10)=11  apply1(1,10)=20  apply2(2,3,4)=7  apply2(3,3,4)=12
//   apply0(4)=42     vt(0,10)=11      vt(1,10)=20
//   chain(5)=14      mixed(5)=12      loopdispatch(0,5)=7  loopdispatch(3,4)=18
//
// The table holds $add1 and $dbl as (i32)->i32 in slots 0..1, $add and $mul as
// (i32,i32)->i32 in slots 2..3, $const as ()->i32 in slot 4, and nothing in
// slots 5..7. Calling a slot with the wrong signature, a null slot, or a slot
// past the end are the three traps; they abort the process, so they are covered
// by `script/indirect.sh` (one process per case) rather than here.

///|
test "three signatures in one table" {
  inspect(apply1(0, 10), content="11")
  inspect(apply1(1, 10), content="20")
  inspect(apply2(2, 3, 4), content="7")
  inspect(apply2(3, 3, 4), content="12")
  inspect(apply0(4), content="42")
}

///|
test "the index is read from memory, like a method table" {
  inspect(vt(0, 10), content="11")
  inspect(vt(1, 10), content="20")
}

///|
test "indirect calls chain and mix with direct ones" {
  inspect(chain(5), content="14")
  inspect(mixed(5), content="12")
}

///|
test "a loop that dispatches on every iteration" {
  inspect(loopdispatch(0, 5), content="7")
  inspect(loopdispatch(3, 4), content="18")
}
