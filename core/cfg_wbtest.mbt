///|
/// Control-flow graph tests.
///
/// Two layers are tested separately, and the split is deliberate:
///
/// - **Graph analysis** is fed hand-written successor matrices. That is the only
///   way to test the irreducible case: structured wasm cannot express it (`br`
///   only targets enclosing labels, so every CFG the format produces is
///   reducible), yet the analysis must handle it, and a test that "proves" the
///   detector works by passing it no bad input proves nothing.
/// - **CFG construction** is fed instruction lists, and each expected block count
///   is derived from the `.wat` structure by hand in a comment. A test that just
///   recorded whatever the code printed would lock in bugs.
///
/// Assertions are `assert_eq` / `assert_true`, like the rest of the suite: an
/// `inspect` snapshot of a `Show` value is deprecated, and a test whose
/// expectation lives in a comment is harder to review than one that states it in
/// code.

///|
fn instructions(xs : Array[Instr]) -> Array[InstrRef] {
  let out : Array[InstrRef] = []
  let mut i = 0
  for x in xs {
    out.push(InstrRef::new(i, x))
    i = i + 1
  }
  out
}

///|
/// Build a CFG, aborting on an unbalanced stream: every instruction list below
/// is hand-written, so failing to balance is a bug in the test, not a case.
fn cfg_of(xs : Array[Instr]) -> Cfg {
  match build_layout(instructions(xs)) {
    None => abort("test fixture does not balance")
    Some(l) => build_cfg(l)
  }
}

///|
/// True when a layout can be built. `Layout` has no `Show`, so the tests ask the
/// question instead of printing the answer.
fn balances(xs : Array[Instr]) -> Bool {
  match build_layout(instructions(xs)) {
    None => false
    Some(_) => true
  }
}

///|
/// Successor lists of a CFG, exit edges dropped, for compact assertions.
fn succs_of(c : Cfg) -> Array[Array[Int32]] {
  let out : Array[Array[Int32]] = []
  for b in c.blocks {
    let row : Array[Int32] = []
    for x in b.succ {
      if x != c.exit {
        row.push(x)
      }
    }
    out.push(row)
  }
  out
}

// --- graph analysis on synthetic matrices ---------------------------------

///|
test "graph: diamond is reducible and its join has a single dominator" {
  //   0 -> 1, 2 ; 1 -> 3 ; 2 -> 3 ; 3 -> (end)
  let g = analyze_graph(4, [[1, 2], [3], [3], []])
  assert_true(g.reducible)
  assert_eq(g.bad_from.length(), 0)
  assert_eq(g.idom, [-1, 0, 0, 0])
  assert_eq(g.header.length(), 0)
}

///|
test "graph: a self-loop is a back edge, not a defect" {
  //  0 -> 1 ; 1 -> 1 ; 1 -> 2
  let g = analyze_graph(3, [[1], [1, 2], []])
  assert_true(g.reducible)
  assert_eq(g.header, [1])
  assert_eq(g.nodes[0], [1])
  assert_eq(g.tails[0], [1])
}

///|
test "graph: two entries into a cycle are irreducible" {
  //   0 -> 1, 2 ; 1 -> 3 ; 2 -> 3 ; 3 -> 2
  //
  // The classic Hecht–Ullman example: `3 -> 2` closes a cycle whose header `2`
  // is not reached on every path into `3`, because `0 -> 1 -> 3` skips it. No
  // nesting of `block` / `loop` / `if` can produce this, which is exactly why
  // the graph analysis is tested on a matrix rather than on a wasm fixture.
  let g = analyze_graph(4, [[1, 2], [3], [3], [2]])
  assert_false(g.reducible)
  assert_eq(g.bad_from, [2])
  assert_eq(g.bad_to, [3])
}

///|
test "graph: unreachable nodes are excluded from the analysis" {
  //  0 -> 1 ; 2 is unreachable but points at 0
  let g = analyze_graph(3, [[1], [], [0]])
  assert_eq(g.reachable, [true, true, false])
  assert_true(g.reducible)
  assert_eq(g.idom, [-1, 0, -1])
}

///|
test "graph: an empty graph is reducible" {
  let g = analyze_graph(0, [])
  assert_true(g.reducible)
  assert_eq(g.header.length(), 0)
}

///|
test "graph: loop tails merge when two back edges share a header" {
  //  0 -> 1 ; 1 -> 2 ; 2 -> 3 ; 2 -> 1 ; 3 -> 1
  let g = analyze_graph(4, [[1], [2], [3, 1], [1]])
  assert_true(g.reducible)
  assert_eq(g.header, [1])
  assert_eq(g.nodes[0], [1, 2, 3])
  assert_eq(g.tails[0], [2, 3])
}

// --- CFG construction from instructions -----------------------------------

///|
test "cfg: an empty body has no blocks" {
  let c = cfg_of([])
  assert_eq(c.block_count(), 0)
  assert_eq(c.edge_count(), 0)
  assert_eq(c.render(), "  blocks 0  edges 0  loops 0  reducible yes\n")
}

///|
test "cfg: a straight line is one block that falls into the exit" {
  let c = cfg_of([Const(I32V(1)), Drop])
  assert_eq(c.block_count(), 1)
  assert_eq(c.blocks[0].first, 0)
  assert_eq(c.blocks[0].end, 2)
  assert_eq(c.blocks[0].succ, [1])
  assert_eq(c.exit, 1)
}

///|
test "cfg: if/else splits into four blocks and rejoins at the end" {
  // 0 i32.const 1
  // 1 if            <- then arm starts at op 2, else arm at op 3, both rejoin at 4
  // 2   nop
  // 3 else
  // 4   nop
  // 5 end
  // 6 nop
  let c = cfg_of([Const(I32V(1)), If(Empty), Nop, Else, Nop, End, Nop])
  assert_eq(c.block_count(), 4)
  assert_eq(c.edge_count(), 5)
  assert_eq(succs_of(c), [[1, 2], [3], [3], []])
  // Both arms are dominated by the block holding the `if`, and so is the join.
  assert_eq(c.blocks[1].idom, 0)
  assert_eq(c.blocks[2].idom, 0)
  assert_eq(c.blocks[3].idom, 0)
  // The exact rendering, because the format is what `disasm --cfg` promises.
  assert_eq(
    c.render(),
    (
      #|  blocks 4  edges 5  loops 0  reducible yes
      #|  b0   ops 0..2       succ b1 b2
      #|  b1   ops 2..3       succ b3
      #|  b2   ops 3..4       succ b3
      #|  b3   ops 4..5       succ exit
      #|  idom b1<-b0  b2<-b0  b3<-b0
      #|
    ),
  )
}

///|
test "cfg: if without else has one fewer block and one fewer edge" {
  // 0 cond
  // 1 if       <- then op 2, false branch jumps straight to op 3
  // 2   nop
  // 3 end
  // 4 nop
  let c = cfg_of([Const(I32V(1)), If(Empty), Nop, End, Nop])
  assert_eq(c.block_count(), 3)
  assert_eq(succs_of(c), [[1, 2], [2], []])
}

///|
test "cfg: a loop with br 0 is a single block with a self edge" {
  // loop
  //   nop
  //   br 0      <- back edge
  // end
  // nop
  let c = cfg_of([Loop(Empty), Nop, Br(0), End, Nop])
  assert_eq(c.block_count(), 2)
  assert_eq(succs_of(c), [[0], []])
  assert_eq(c.loops.length(), 1)
  assert_eq(c.loops[0].header, 0)
  assert_eq(c.loops[0].tails, [0])
  assert_true(c.reducible)
}

///|
test "cfg: br 0 at the top level leaves the function" {
  // The function body is itself a label, so `br 0` with no enclosing construct
  // is a `return`: the block's only successor is the exit.
  let c = cfg_of([Br(0)])
  assert_eq(c.block_count(), 1)
  assert_eq(c.blocks[0].succ, [1])
  assert_eq(c.exit, 1)
}

///|
test "cfg: br_table produces one edge per distinct label" {
  // block $a
  //   block $b
  //     br_table 0 1     <- $b closes at op 1, $a at op 2
  //   end
  //   nop
  // end
  let c = cfg_of([Block(Empty), Block(Empty), BrTable([0, 1], 1), End, Nop, End])
  assert_eq(c.block_count(), 2)
  // Targets: $b's end is op 1 (block 1), $a's end is op 2 (the exit).
  assert_eq(c.blocks[0].succ, [1, 2])
  assert_eq(c.exit, 2)
}

///|
test "cfg: code after an unconditional br is marked unreachable" {
  let c = cfg_of([Br(0), Nop])
  assert_eq(c.block_count(), 2)
  assert_true(c.blocks[0].reachable)
  assert_false(c.blocks[1].reachable)
  assert_eq(c.unreachable_count(), 1)
}

///|
test "cfg: unreachable terminates a block with no successors" {
  // if
  //   unreachable
  // end
  // nop
  let c = cfg_of([Const(I32V(1)), If(Empty), Unreachable, End, Nop])
  assert_eq(c.block_count(), 3)
  // The trapping arm has no successor at all: nothing continues from it.
  assert_eq(c.blocks[1].succ, [])
  assert_eq(succs_of(c), [[1, 2], [], []])
  assert_eq(c.edge_count(), 3)
}

///|
test "cfg: nested loops report the inner loop's depth" {
  // loop $a
  //   nop
  //   loop $b
  //     br_if 0       <- depth 0 is $b, whose header lands in block 1
  //   end
  //   br 0            <- depth 0 is now $a, whose header lands in block 0
  // end
  //
  // The inner branch is `br_if`, not `br`: with an unconditional `br 0` the
  // inner loop would never fall through, and the code after it — including the
  // outer back edge — would be unreachable. That is not a hypothetical: it is
  // how this test first failed.
  let c = cfg_of([Loop(Empty), Nop, Loop(Empty), BrIf(0), End, Br(0), End])
  assert_eq(c.block_count(), 3)
  assert_eq(c.loops.length(), 2)
  assert_eq(c.loops[0].header, 0)
  assert_eq(c.loops[0].nodes, [0, 1, 2])
  assert_eq(c.loops[1].header, 1)
  assert_eq(c.loops[1].nodes, [1])
  assert_eq(c.max_loop_depth(), 1)
  assert_true(c.reducible)
}

///|
test "cfg: end and else are not blocks of their own" {
  // 0 nop / 1 if / 2 nop / 3 else / 4 nop / 5 end
  // Four real instructions, so no block range may exceed 0..4 even though the
  // instruction list has six entries.
  let c = cfg_of([Nop, If(Empty), Nop, Else, Nop, End])
  assert_eq(c.ops.length(), 4)
  let mut highest = 0
  for b in c.blocks {
    if b.end > highest {
      highest = b.end
    }
  }
  assert_eq(highest, 4)
}

///|
test "cfg: an unbalanced stream is refused rather than guessed" {
  // An `end` with nothing open: the decoder can never produce this (the body's
  // own `end` is not in the instruction list), but the layout builder is also
  // reachable from tests and from future callers.
  assert_false(balances([Nop, End]))
  // A `block` that never closes.
  assert_false(balances([Block(Empty), Nop]))
  // The well-formed version of the first case.
  assert_true(balances([Nop]))
}

///|
test "cfg: a partial body yields no graph" {
  let body : DecodedBody = {
    instrs: instructions([Nop]),
    complete: false,
    stop_offset: 7,
    stop_op: 0xFD,
    stop_sub: 0,
  }
  let ok = match cfg_of_body(body) {
    None => false
    Some(_) => true
  }
  assert_false(ok)
}
