// Behavioural smoke test for the package generated from `corpus/good/nested.wasm`.
//
// Copied into the generated package by `script/check.sh`. The expectations come
// from the original module in Node:
//
//   cd corpus/tools && node oracle.js ../good/nested.wasm \
//     '[["route",[0]],["route",[1]],["route",[2]],["route",[5]],["route",[9]],
//       ["route_sum",[0,0]],["route_sum",[0,5]],["route_sum",[1,5]],
//       ["route_sum",[3,5]],["route_sum",[2,10]],["route_sum",[7,100]]]'
//
// This fixture is a `br_table` inside a `loop` inside a `block`, so it is the
// one that puts a `match` in the middle of a `while true` and lets three arms
// leave three different ways: `continue` (the back edge), `return` from inside
// a nested block, and `break` out of the outer one.
//
// `route_sum` is the sharper of the two. Its dispatch carries a value on the
// stack, so each arm has to write that value into the destination's slot before
// it leaves — the last point where the expression that produced it is still
// correct. Nothing about that shows up when the package merely compiles: the
// first version of this edge emitted an assignment from a temporary that was
// never written, and `route_sum(1, 5)` answered with whatever the slot happened
// to hold.

///|
test "route dispatches three ways out of a loop" {
  // 0 falls into the back edge and comes round again, then leaves through the
  // 100 arm; 1 and 2+ leave directly.
  inspect(route(0), content="7")
  inspect(route(1), content="100")
  inspect(route(2), content="100")
  inspect(route(5), content="100")
  inspect(route(9), content="100")
}

///|
test "route_sum carries a value across the dispatch" {
  // 1 leaves through the arm that adds 10, 2 and 3 through the arm that
  // multiplies by 3, and 0 goes round the loop once first — which is the arm
  // whose payload is discarded, because a branch to the loop takes no values.
  inspect(route_sum(0, 0), content="3")
  inspect(route_sum(0, 5), content="18")
  inspect(route_sum(1, 5), content="16")
  inspect(route_sum(3, 5), content="15")
  inspect(route_sum(2, 10), content="30")
  inspect(route_sum(7, 100), content="300")
}
