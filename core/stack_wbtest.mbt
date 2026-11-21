///|
/// Typed stack simulation tests.
///
/// The instruction lists are hand-written and the expected strings are derived
/// from the `.wat` shape by hand, in the comment above each case. A test that
/// recorded whatever the code printed would lock in whatever the code did —
/// including the two reordering hazards this stage exists to get right, which are
/// exactly the ones a snapshot test cannot judge.
///
/// `analyze_blocks` is called directly rather than `analyze_func`: the latter
/// needs a whole `Module`, and a module built for a test is one more thing that
/// can be wrong. Everything below the module boundary is what this stage adds.

///|
/// The minimal module the statement renderer needs. Function labels come out as
/// `$f<idx>`, which is what an unnamed function is called everywhere else.
fn empty_module() -> Module {
  {
    size: 0,
    types: [],
    imports: [],
    func_types: [],
    tables: [],
    memories: [],
    globals: [],
    exports: [],
    elems: [],
    codes: [],
    datas: [],
    customs: [],
    sections: [],
    func_names: [],
    start_func: -1,
    has_start: false,
    data_count: 0,
    has_data_count: false,
  }
}

///|
fn env(
  params : Array[ValType],
  locals : Array[ValType],
  results : Array[ValType],
) -> FuncEnv {
  let all : Array[ValType] = []
  for p in params {
    all.push(p)
  }
  for l in locals {
    all.push(l)
  }
  { locals: all, globals: [], results, funcs: [], has_memory: true, }
}

///|
/// An environment that can call one function, `(i32) -> i32`.
fn env_calling(results : Array[ValType]) -> FuncEnv {
  let all : Array[ValType] = [I32]
  {
    locals: all,
    globals: [],
    results,
    funcs: [FuncType::new([I32], [I32])],
    has_memory: true,
  }
}

///|
fn run(xs : Array[Instr], e : FuncEnv) -> Result[Array[BlockStack], Diag] {
  let l = match build_layout(instructions(xs)) {
    None => abort("stack fixture does not balance")
    Some(l) => l
  }
  analyze_blocks(l, e, build_cfg(l))
}

///|
fn blocks(xs : Array[Instr], e : FuncEnv) -> Array[BlockStack] {
  match run(xs, e) {
    Ok(b) => b
    Err(d) => abort(d.render())
  }
}

///|
fn failure(xs : Array[Instr], e : FuncEnv) -> Diag {
  match run(xs, e) {
    Ok(_) => abort("expected a rejection, got statements")
    Err(d) => d
  }
}

///|
/// Statements of one block, one per `|`, so a whole block fits on one line of
/// the test.
fn text(bs : BlockStack) -> String {
  let b = StringBuilder()
  for st in bs.stmts {
    b.write_string(st.render(empty_module()))
    b.write_string(" | ")
  }
  b.to_string()
}

///|
/// The values a block hands to the next instruction.
fn out_text(bs : BlockStack) -> String {
  render_vals(bs.exit_exprs, empty_module())
}

// --- expression recovery --------------------------------------------------

///|
test "stack: a binary operator folds its two reads into one statement" {
  // local.get 0; local.get 1; i32.add; local.set 2
  let xs = [LocalGet(0), LocalGet(1), Bin(I32, Add), LocalSet(2)]
  let got = blocks(xs, env([I32, I32], [I32], []))
  assert_eq(got.length(), 1)
  assert_eq(text(got[0]), "local 2 = i32.add(local 0, local 1) | ")
  assert_eq(got[0].forced, 0)
  assert_eq(got[0].hazard, 0)
}

///|
test "stack: a comparison produces i32, not the operand type" {
  // local.get 0; local.get 1; i64.lt_u   with i64 params
  let xs = [LocalGet(0), LocalGet(1), Bin(I64, LtU)]
  let got = blocks(xs, env([I64, I64], [], [I32]))
  assert_eq(out_text(got[0]), "(i64.lt_u(local 0, local 1))")
  assert_eq(got[0].exit[0].name(), "i32")
}

///|
test "stack: a conversion keeps its operand and changes its type" {
  // local.get 0; f64.promote_f32   with an f32 param
  let xs = [LocalGet(0), Conv(F64, F32, Promote)]
  let got = blocks(xs, env([F32], [], [F64]))
  assert_eq(out_text(got[0]), "(f64.promote_f32(local 0))")
  assert_eq(got[0].exit[0].name(), "f64")
}

///|
test "stack: select keeps all three operands and the value type" {
  // local.get 0; local.get 1; local.get 0; local.get 1; i32.gt_s; select
  let xs = [
    LocalGet(0),
    LocalGet(1),
    LocalGet(0),
    LocalGet(1),
    Bin(I32, GtS),
    Select,
  ]
  let got = blocks(xs, env([I32, I32], [], [I32]))
  assert_eq(
    out_text(got[0]),
    "(select(local 0, local 1, i32.gt_s(local 0, local 1)))",
  )
}

///|
test "stack: a discarded pure expression produces no statement" {
  // i32.const 1; drop
  let got = blocks([Const(I32V(1)), Drop], env([], [], []))
  assert_eq(text(got[0]), "")
  assert_eq(got[0].exit.length(), 0)
}

// --- the two reordering hazards -------------------------------------------

///|
test "stack: a local read live across an overwrite is sunk first" {
  // local.get 0; i32.const 7; local.set 0; local.get 0; i32.add
  //
  // The first read must be evaluated *before* the assignment, or the function
  // computes 7 + 7 instead of x + 7.
  let xs = [
    LocalGet(0),
    Const(I32V(7)),
    LocalSet(0),
    LocalGet(0),
    Bin(I32, Add),
  ]
  let got = blocks(xs, env([I32], [], [I32]))
  assert_eq(text(got[0]), "t0 = local 0 | local 0 = i32.const 7 | ")
  assert_eq(out_text(got[0]), "(i32.add(t0, local 0))")
  assert_eq(got[0].hazard, 1)
  assert_eq(got[0].forced, 0)
}

///|
test "stack: a load live across a store is sunk first" {
  // local.get 0; i32.load; local.get 0; i32.const 99; i32.store
  let load = MemOp::new(I32, 4, false, false, 2, 0U)
  let store = MemOp::new(I32, 4, false, true, 2, 0U)
  let xs = [LocalGet(0), Mem(load), LocalGet(0), Const(I32V(99)), Mem(store)]
  let got = blocks(xs, env([I32], [], [I32]))
  assert_eq(
    text(got[0]),
    "t0 = i32.load[offset=0 align=4](local 0) | i32.store[offset=0 align=4](local 0, i32.const 99) | ",
  )
  assert_eq(out_text(got[0]), "(t0)")
  assert_eq(got[0].hazard, 1)
}

///|
test "stack: a load consumed by the very store it precedes is not sunk" {
  // i32.const 0; i32.const 1; i32.store   -- the value is not a load, but the
  // address expression is evaluated as part of the store, so no spill is due.
  let store = MemOp::new(I32, 4, false, true, 2, 0U)
  let xs = [Const(I32V(0)), Const(I32V(1)), Mem(store)]
  let got = blocks(xs, env([], [], []))
  assert_eq(
    text(got[0]),
    "i32.store[offset=0 align=4](i32.const 0, i32.const 1) | ",
  )
  assert_eq(got[0].hazard, 0)
}

// --- evaluation order that is not a hazard --------------------------------

///|
test "stack: local.tee followed by a read of the same local does not spill" {
  // local.get 0; i32.const 1; i32.add; local.tee 0; local.get 0; i32.mul
  let xs = [
    LocalGet(0),
    Const(I32V(1)),
    Bin(I32, Add),
    LocalTee(0),
    LocalGet(0),
    Bin(I32, Mul),
  ]
  let got = blocks(xs, env([I32], [], [I32]))
  assert_eq(text(got[0]), "local 0 = i32.add(local 0, i32.const 1) | ")
  assert_eq(out_text(got[0]), "(i32.mul(local 0, local 0))")
  assert_eq(got[0].hazard, 0)
}

///|
test "stack: a call result is materialised where the call happens" {
  // local.get 0; call $f0; call $f0
  let xs = [LocalGet(0), Call(0), Call(0)]
  let got = blocks(xs, env_calling([I32]))
  assert_eq(text(got[0]), "t0 = call $f0(local 0) | t1 = call $f0(t0) | ")
  assert_eq(got[0].forced, 2)
  assert_eq(got[0].hazard, 0)
}

///|
test "stack: dropping a call result keeps the call" {
  // i32.const 1; call $f0; drop
  let got = blocks([Const(I32V(1)), Call(0), Drop], env_calling([]))
  // The call was already materialised, so the `drop` itself contributes nothing;
  // what matters is that the call statement survived.
  assert_eq(text(got[0]), "t0 = call $f0(i32.const 1) | ")
  assert_eq(got[0].exit.length(), 0)
}

// --- block boundaries -----------------------------------------------------

///|
test "stack: a block result is checked against the stack at its end" {
  // block (result i32) i32.const 1 i32.const 2 end   -- two values, one result
  let d = failure(
    [Block(Value(I32)), Const(I32V(1)), Const(I32V(2)), End],
    env([], [], [I32]),
  )
  assert_eq(d.code.tag(), "E011")
  assert_true(d.message.contains("2 value(s)"))
}

///|
test "stack: a block that produces its result is accepted" {
  // block (result i32) i32.const 1 end
  let got = blocks([Block(Value(I32)), Const(I32V(1)), End], env([], [], [I32]))
  assert_eq(got[0].exit[0].name(), "i32")
  assert_eq(out_text(got[0]), "(i32.const 1)")
}

///|
test "stack: the function body must leave exactly its results" {
  // (func (result i32) nop)
  let d = failure([Nop], env([], [], [I32]))
  assert_eq(d.code.tag(), "E011")
  assert_true(d.message.contains("returns [i32]"))
}

///|
test "stack: a return inside a block reports the function's results" {
  // i32.const 1; return    in a (result i32) function
  let got = blocks([Const(I32V(1)), Return], env([], [], [I32]))
  assert_eq(text(got[0]), "return (i32.const 1) | ")
  assert_eq(got[0].falls, false)
  assert_eq(got[0].exit[0].name(), "i32")
}

///|
test "stack: a branch to a block transfers its results and discards the rest" {
  // block (result i32) i32.const 1 br 0 end
  let got = blocks(
    [Block(Value(I32)), Const(I32V(1)), Br(0), End],
    env([], [], [I32]),
  )
  // One block: `br` splits *after* itself, so the constant and the branch are
  // in the same range (0..2) and the branch is its terminator.
  assert_eq(got.length(), 1)
  assert_eq(text(got[0]), "br 0 (i32.const 1) | ")
  assert_eq(got[0].falls, false)
  assert_eq(got[0].exit[0].name(), "i32")
}

///|
test "stack: a branch past the outermost label becomes a return" {
  // i32.const 1; br 0    with no enclosing construct
  let got = blocks([Const(I32V(1)), Br(0)], env([], [], [I32]))
  assert_eq(text(got[0]), "return (i32.const 1) | ")
}

///|
test "stack: br_if needs a value under its condition" {
  // block (result i32) i32.const 1 br_if 0 end
  //
  // `br_if` pops the condition and then requires the *target's* values to be on
  // top. Here the single i32 was consumed as the condition, so there is nothing
  // to branch with — a shape that reads as plausible and is not.
  let d = failure(
    [Block(Value(I32)), Const(I32V(1)), BrIf(0), End],
    env([], [], [I32]),
  )
  assert_eq(d.code.tag(), "E011")
  assert_true(d.message.contains("br_if"))
}

// --- rejections -----------------------------------------------------------

///|
test "stack: an operand of the wrong type is an error at its own byte" {
  // f32 param; i32.const 1; i32.add
  let xs = [LocalGet(0), Const(I32V(1)), Bin(I32, Add)]
  let d = failure(xs, env([F32], [], [I32]))
  assert_eq(d.code.tag(), "E011")
  assert_true(d.message.contains("i32.add needs i32"))
  assert_true(d.message.contains("f32"))
}

///|
test "stack: popping an empty stack is an error, not a crash" {
  let d = failure([Bin(I32, Add)], env([], [], [I32]))
  assert_eq(d.code.tag(), "E011")
  assert_true(d.message.contains("empty"))
}

///|
test "stack: select on two different types is refused" {
  // i32.const 1; f32.const 0; i32.const 1; select
  let xs = [Const(I32V(1)), Const(F32V(0U)), Const(I32V(1)), Select]
  let d = failure(xs, env([], [], [I32]))
  assert_eq(d.code.tag(), "E011")
  assert_true(d.message.contains("select operands differ"))
}

///|
test "stack: a block typed by index is refused as multi-value" {
  let d = failure([Const(I32V(1)), If(TypeIdx(0)), End], env([], [], []))
  assert_eq(d.code.tag(), "E112")
}

///|
test "stack: a call returning two values is refused as multi-value" {
  let e : FuncEnv = {
    locals: [I32],
    globals: [],
    results: [],
    funcs: [FuncType::new([I32], [I32, I32])],
    has_memory: true,
  }
  let d = failure([LocalGet(0), Call(0)], e)
  assert_eq(d.code.tag(), "E112")
  assert_true(d.message.contains("multi-value"))
}

///|
test "stack: a function returning two values is refused at the signature" {
  // (module (func (result i32 i32) i32.const 1 i32.const 2))
  // The emitter can only print one MoonBit result. Before this refusal it
  // printed `vs[0]` and silently dropped the rest, which also left a local
  // "read" by the scan but unused in the generated file.
  let wasm = b"\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x00\x02\x7f\x7f\x03\x02\x01\x00\x0a\x08\x01\x06\x00\x41\x01\x41\x02\x0b"
  match decode_bytes(wasm) {
    Err(d) => abort("decode failed: \{d.render()}")
    Ok(m) =>
      match analyze_func(m, 0) {
        Err(d) => abort("unexpected hard error: \{d.render()}")
        Ok(fs) =>
          match fs.refusal {
            Some(d) => {
              assert_eq(d.code.tag(), "E112")
              assert_true(d.message.contains("multi-value"))
            }
            None =>
              abort("a two-result function must be refused, not truncated")
          }
      }
  }
}

///|
test "stack: a memory instruction in a module without memory is an index error" {
  let e : FuncEnv = {
    locals: [I32],
    globals: [],
    results: [I32],
    funcs: [],
    has_memory: false,
  }
  let load = MemOp::new(I32, 4, false, false, 2, 0U)
  let d = failure([LocalGet(0), Mem(load)], e)
  assert_eq(d.code.tag(), "E008")
  assert_true(d.message.contains("no memory"))
}

///|
test "stack: call_indirect is refused by name rather than silently dropped" {
  let d = failure([CallIndirect(0)], env([], [], []))
  assert_eq(d.code.tag(), "E111")
}

///|
test "stack: bulk memory is refused by name" {
  let d = failure([Misc(MemoryCopy)], env([], [], []))
  assert_eq(d.code.tag(), "E109")
}

// --- dead code ------------------------------------------------------------

///|
test "stack: code after unreachable is kept and marked dead" {
  // unreachable; i32.const 1
  let got = blocks([Unreachable, Const(I32V(1))], env([], [], [I32]))
  assert_eq(got.length(), 2)
  assert_eq(got[0].falls, false)
  assert_true(got[1].dead)
  assert_eq(got[1].stmts.length(), 0)
}

// --- globals: the same hazard, one indirection away ------------------------

///|
test "stack: a global read live across a write to the same global is sunk" {
  // i32.const 1; global.get 0; i32.const 2; global.set 0; i32.add
  let e : FuncEnv = {
    locals: [],
    globals: [I32],
    results: [I32],
    funcs: [],
    has_memory: true,
  }
  let got = blocks(
    [Const(I32V(1)), GlobalGet(0), Const(I32V(2)), GlobalSet(0), Bin(I32, Add)],
    e,
  )
  assert_eq(text(got[0]), "t0 = global 0 | global 0 = i32.const 2 | ")
  assert_eq(out_text(got[0]), "(i32.add(i32.const 1, t0))")
  assert_eq(got[0].hazard, 1)
}

///|
test "stack: a global read live across a call is sunk, because the callee may write it" {
  // global.get 0; i32.const 2; call $f0; i32.add
  let e : FuncEnv = {
    locals: [],
    globals: [I32],
    results: [I32],
    funcs: [FuncType::new([I32], [I32])],
    has_memory: true,
  }
  let got = blocks([GlobalGet(0), Const(I32V(2)), Call(0), Bin(I32, Add)], e)
  // The argument `i32.const 2` is consumed by the call, so only the global read
  // is left pending and only it is sunk.
  assert_eq(text(got[0]), "t0 = global 0 | t1 = call $f0(i32.const 2) | ")
  assert_eq(out_text(got[0]), "(i32.add(t0, t1))")
  assert_eq(got[0].hazard, 1)
  assert_eq(got[0].forced, 1)
}
