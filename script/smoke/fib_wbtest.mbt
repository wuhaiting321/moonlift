// Behavioural smoke test for the package generated from `corpus/good/fib.wasm`.
//
// This file is copied into the generated package by `script/check.sh`, which
// needs a rename (a `*_wbtest.mbt` file is only picked up when it sits beside the
// code it tests). Every expected value below came from running the *original*
// module in Node:
//
//   cd corpus/tools && node oracle.js ../good/fib.wasm \
//     '[["fib",[0]],["fib",[1]],["fib",[10]],["fib_iter",[0]],["fib_iter",[1]],
//       ["fib_iter",[10]],["roundtrip",[42]],["roundtrip",[-7]]]'
//
//   fib(0) = 0   fib(1) = 1   fib(10) = 55
//   fib_iter(0) = 1   fib_iter(1) = 1   fib_iter(10) = 89
//   roundtrip(42) = 42   roundtrip(-7) = -7
//
// A decompiler that only compiles is not a decompiler. This is the smallest
// test that would have caught the two bugs found while writing the emitter: a
// conditional `br` to the end of the body being emitted as an unconditional
// `return` (which turns a loop into a single iteration), and a block's entry
// value being read without ever having been written.

///|
test "fib recurses" {
  inspect(fib(0), content="0")
  inspect(fib(1), content="1")
  inspect(fib(10), content="55")
}

///|
test "fib_iter loops" {
  inspect(fib_iter(0), content="1")
  inspect(fib_iter(1), content="1")
  inspect(fib_iter(10), content="89")
}

///|
test "roundtrip goes through memory" {
  inspect(roundtrip(42), content="42")
  inspect(roundtrip(-7), content="-7")
}
