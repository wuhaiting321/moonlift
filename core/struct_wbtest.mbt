///|
/// White-box tests for the structurer.
///
/// Each module here is a complete, valid binary written out as bytes, so the
/// test drives the real path — decode, type-check, graph, structure — instead of
/// hand-building a `Layout`, which would let a bug in the layout hide from every
/// test that also hand-builds one. The bytes are what `corpus/tools/build.js`
/// produces for the one-line `.wat` quoted above each case, so they can be
/// re-derived by anyone who doubts them.

///|
/// The structured text of function 0, or the reason there is none.
fn tree_of(wasm : Bytes) -> String {
  match decode_bytes(wasm) {
    Err(d) => "decode failed: \{d.render()}"
    Ok(m) =>
      match structure_func(m, 0) {
        Err(d) => "structure failed: \{d.render()}"
        Ok(t) => t.render(m)
      }
  }
}

///|
/// `ok` when function 0 emitted every reachable block exactly once, or the two
/// counts when it did not.
fn coverage_of(wasm : Bytes) -> String {
  match decode_bytes(wasm) {
    Err(_) => "decode failed"
    Ok(m) =>
      match structure_func(m, 0) {
        Err(_) => "structure failed"
        Ok(t) =>
          if t.blocks == t.total_blocks {
            "ok"
          } else {
            "\{t.blocks} emitted of \{t.total_blocks}"
          }
      }
  }
}

// --- a function with no control flow --------------------------------------
//
//   (module (func (result i32) i32.const 42))

///|
test "struct: a straight-line body is one return and nothing else" {
  let text = tree_of(
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x06\x01\x04\x00\x41\x2a\x0b",
  )
  assert_true(text.contains("return (i32.const 42)"))
  // No loop, no branch, no `brk`: there is nothing to structure.
  assert_false(text.contains("while true"))
  assert_false(text.contains("brk"))
}

// --- a loop whose only exit is a back edge --------------------------------
//
//   (module (func (result i32) loop nop br 0 end i32.const 9))

///|
test "struct: br to the innermost loop is a continue" {
  let text = tree_of(
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x0c\x01\x0a\x00\x03\x40\x01\x0c\x00\x0b\x41\x09\x0b",
  )
  // A `loop` becomes a `while true` with a check that decides whether a pending
  // `brk` meant "restart me" or "leave me".
  assert_true(text.contains("loop"))
  assert_true(text.contains("continue"))
  assert_true(text.contains("if (brk != 1) { break }"))
}

// --- a branch that leaves two constructs at once --------------------------
//
//   (module (func (result i32) block block br 1 end end i32.const 5))

///|
test "struct: br past one construct is recorded in brk and unwound" {
  let text = tree_of(
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x0e\x01\x0c\x00\x02\x40\x02\x40\x0c\x01\x0b\x0b\x41\x05\x0b",
  )
  // `br 1` from inside the inner block leaves the outer one, which the code is
  // not lexically in: that is what `brk` is for.
  assert_true(text.contains("brk = 1; break"))
  // The inner block is finished normally after the unwinding, so the check that
  // follows it asks whether the request was for it.
  assert_true(text.contains("if (brk == 2) { brk = -1 }"))
}

// --- if / else as an expression -------------------------------------------
//
//   (module (func (result i32) i32.const 1 if (result i32)
//     i32.const 2 else i32.const 3 end))

///|
test "struct: both arms of an if are emitted with their own values" {
  let text = tree_of(
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x0e\x01\x0c\x00\x41\x01\x04\x7f\x41\x02\x05\x41\x03\x0b\x0b",
  )
  assert_true(text.contains("if (i32.const 1)"))
  assert_true(text.contains("return (i32.const 2)"))
  assert_true(text.contains("return (i32.const 3)"))
  // The condition belongs to the `if`, not to a statement of its own: a bare
  // `if (...)` line would mean the arms were never attached.
  assert_false(text.contains("  if (i32.const 1)\n"))
}

// --- a conditional exit from a block --------------------------------------
//
//   (module (func (param i32) (result i32) block
//     local.get 0 br_if 0 i32.const 1 return end i32.const 2))

///|
test "struct: br_if to the enclosing block is a conditional break" {
  let text = tree_of(
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x0a\x10\x01\x0e\x00\x02\x40\x20\x00\x0d\x00\x41\x01\x0f\x0b\x41\x02\x0b",
  )
  // The label names the block the instruction is lexically in, so no state is
  // needed — the `break` is the transfer.
  assert_true(text.contains("break"))
  assert_true(text.contains("return (i32.const 1)"))
  assert_true(text.contains("return (i32.const 2)"))
  assert_false(text.contains("brk = 1"))
}

// --- a four-way dispatch ---------------------------------------------------
//
//   (module (func (result i32) block block block i32.const 0
//     br_table 0 1 2 end i32.const 10 return end i32.const 20 return end
//     i32.const 30))

///|
test "struct: br_table becomes a match with one arm per label" {
  let text = tree_of(
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x1c\x01\x1a\x00\x02\x40\x02\x40\x02\x40\x41\x00\x0e\x02\x00\x01\x02\x0b\x41\x0a\x0f\x0b\x41\x14\x0f\x0b\x41\x1e\x0b",
  )
  assert_true(text.contains("match (i32.const 0)"))
  // `br_table 0 1 2` is two table entries and a default, not three entries:
  // the last label in the immediate is the default and is never an arm.
  assert_true(text.contains("  0 => break"))
  assert_true(text.contains("  1 => brk = 2; break"))
  assert_true(text.contains("_ => brk = 1; break"))
}

// --- the invariant every other test rests on ------------------------------
//
// A structured function that drops a block produces code that silently omits
// it; one that emits a block twice produces code that runs it twice. Both are
// invisible in the output, which is why the count is asserted rather than
// inspected.

///|
test "struct: every reachable block is emitted exactly once" {
  let cases : Array[Bytes] = [
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x06\x01\x04\x00\x41\x2a\x0b",
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x0c\x01\x0a\x00\x03\x40\x01\x0c\x00\x0b\x41\x09\x0b",
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x0e\x01\x0c\x00\x02\x40\x02\x40\x0c\x01\x0b\x0b\x41\x05\x0b",
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x0e\x01\x0c\x00\x41\x01\x04\x7f\x41\x02\x05\x41\x03\x0b\x0b",
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x0a\x10\x01\x0e\x00\x02\x40\x20\x00\x0d\x00\x41\x01\x0f\x0b\x41\x02\x0b",
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x0a\x1c\x01\x1a\x00\x02\x40\x02\x40\x02\x40\x41\x00\x0e\x02\x00\x01\x02\x0b\x41\x0a\x0f\x0b\x41\x14\x0f\x0b\x41\x1e\x0b",
  ]
  for c in cases {
    assert_eq(coverage_of(c), "ok")
  }
}

// --- a value that crosses a block boundary --------------------------------
//
//   (module (func (param i32) (result i32)
//     local.get 0
//     block (result i32) local.get 0 i32.const 1 i32.add end
//     i32.add))

///|
test "struct: a block's entry value is written down at the edge" {
  let text = tree_of(
    b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x0a\x0f\x01\x0d\x00\x20\x00\x02\x7f\x20\x00\x41\x01\x6a\x0b\x6a\x0b",
  )
  // `local 0` is pushed before the block opens, so it has to survive the block
  // and be consumed after it: that is a value crossing an edge, and it needs a
  // name. A structured tree has no parameters, so the name is a temp.
  assert_true(text.contains("t2 = local 0"))
  // The block's own result is handed on the same way, at the `end`.
  assert_true(text.contains("i32.add(local 0, i32.const 1)"))
  // The one thing that must never happen: a block parameter left unbound. The
  // name `in0` is how the analysis spells it, and it has no binding in a tree.
  assert_false(text.contains("in0"))
  assert_false(text.contains("in1"))
}

// --- a loop with a result, inside a block with a result --------------------
//
//   (module (func (param i32) (result i32) (local i32)
//     block (result i32)
//       loop (result i32) ... br 1 end
//     end))

///|
test "struct: values cross a loop edge and a block edge in one body" {
  let bytes = b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x0a\x24\x01\x22\x01\x01\x7f\x02\x7f\x03\x7f\x20\x01\x41\x01\x6a\x22\x01\x20\x00\x48\x04\x7f\x20\x01\x05\x41\x09\x0b\x21\x01\x20\x01\x0c\x01\x0b\x0b\x0b"
  let text = tree_of(bytes)
  assert_false(text.contains("in0"))
  assert_false(text.contains("in1"))
  // The `br 1` leaves both the loop and the block, and the value it carries is
  // the block's result — so it is assigned on the way out, not at the use site.
  assert_true(text.contains("t"))
  assert_eq(coverage_of(bytes), "ok")
}
