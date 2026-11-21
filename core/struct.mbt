///|
/// Structuring: the control-flow graph, rearranged into nested `while` / `if`.
///
/// The input to this stage is a validated, typed function — blocks of
/// straight-line statements plus a graph saying where each block goes. The
/// output is a tree of nodes that the code generator can print directly. The
/// question this stage answers is the one wasm's own structure refuses to
/// answer: **`br 2` leaves two regions at once**, and the target language has no
/// labelled `break`.
///
/// # Why the nesting tree and not a Relooper over the graph
///
/// wasm's constructs already form a tree, and `cfg.mbt` keeps it (every
/// construct's range, its parent, and which construct owns each instruction).
/// The graph is derived from that tree, so the tree is the *strongest* available
/// description of the program: rebuilding the structure from the graph alone
/// would have to rediscover information that was never lost.
///
/// So the emitter walks the tree, and the only genuinely new problem is the one
/// the tree does not solve — a branch that leaves several constructs at once. It
/// is solved with a single integer, `brk`, holding the construct being escaped:
///
/// ```text
/// brk = 7; break        // start leaving c7
/// ...                   // one `break` per construct level, each guarded by
/// if (brk == 7) { ... } // a check that asks "is this the level I wanted?"
/// ```
///
/// A dispatcher over the graph (`while` + `switch` on a state variable) is the
/// fallback when the graph cannot be expressed as a tree at all. Structured wasm
/// cannot produce such a graph — `br` may only name an enclosing label — so the
/// fallback is *not implemented*, and `E108` from the analysis is what would
/// report the case instead. Saying that plainly is better than shipping a
/// dispatcher that no input can reach and no test can exercise.
///
/// # The three transfers
///
/// Every branch becomes exactly one of:
///
/// | wasm | emitted | when |
/// |---|---|---|
/// | `br` to the innermost enclosing `loop` | `continue` | the label *is* the loop being executed |
/// | `br` to the innermost enclosing `block`/`if` | `break` | the label *is* the one-shot loop this construct became |
/// | `br` to anything further out | `brk = c; break` | a level has to be recorded and unwound |
///
/// The second and third cases are distinguished by distance, not by kind: a
/// branch to the construct the instruction is lexically inside needs no state,
/// and a branch to an outer one does.
///
/// # What each construct becomes
///
/// ```text
/// block            while true { ... ; break }              // one-shot loop
/// loop             while true { ... ; if (brk != c) break; brk = -1 }
/// if / else        if (cond) { ... } else { ... }
/// if, when a branch inside an arm targets that if:
///                  if (cond) { while true { ... } }         // so the break lands
/// ```
///
/// The `block` case is what makes `break` available at all: without a loop there
/// would be nothing to break out of, and the whole scheme rests on every
/// construct that can be left early owning exactly one loop level.

// --- the structured tree --------------------------------------------------

///|
/// One node of the recovered structure.
///
/// Blocks appear as `NLeaf` and carry the statements recovered by the stack
/// simulation; everything else is control flow. The tree is the same shape the
/// generated source will have, which is why the text renderer can print it as
/// pseudo-code and the code generator can print it as MoonBit without either one
/// having to re-derive anything.
pub enum Node {
  /// A sequence, in program order.
  NSeq(Array[Node])
  /// Straight-line statements, plus the index of the block they came from.
  NLeaf(Array[Stmt], Int32)
  /// `while true { body; break }` — a `block` construct, or the one-shot loop
  /// wrapped around an `if` arm so a branch to that `if` has somewhere to land.
  /// The id is the construct, or -1 for the anonymous arm wrapper.
  NWhileBrk(Int32, Array[Node])
  /// `while true { body; if (brk != c) { break }; brk = -1 }` — a `loop`.
  NWhileLoop(Int32, Array[Node])
  /// `if (cond) { then } else { else }`. An empty `else` is omitted.
  NIf(Expr, Array[Node], Array[Node])
  /// `brk = c; break` — start unwinding towards construct `c`.
  NUnwind(Int32)
  /// `continue`.
  NContinue
  /// `break`.
  NBreak
  /// `return (...)`.
  NReturn(Array[Expr])
  /// `unreachable`.
  NTrap
  /// `match (idx) { 0 => ...; 1 | 2 => ...; _ => ... }` — a `br_table`.
  NSwitch(Expr, Array[Node], Node)
  /// The check that follows a construct some branch escapes past.
  ///
  /// `child` is the construct just finished; `cont` is the enclosing loop
  /// construct, or -1 when the enclosing level is a `block` or an `if` arm and
  /// therefore has no `continue` to offer.
  NGuard(Int32, Int32)
  /// `brk = -1` — the body-level form of `NGuard`: nothing here can be unwound
  /// past, so the only thing to do is forget the request.
  NBrkReset
  /// The values one block hands to another: `from`'s exit expressions become
  /// `to`'s entry variables.
  ///
  /// The tree says *where* a block's values are delivered; naming the variables
  /// is the code generator's business. Keeping the two apart is what lets a
  /// block's statements be printed without knowing who receives them.
  NEdge(Int32, Int32)
  /// `t7 = e` — a value handed across an edge, written down at the edge.
  ///
  /// A block's entry values are stack slots that arrive from whichever
  /// predecessor ran, i.e. they are parameters. In a tree they cannot *be*
  /// parameters (there is no call), so each slot becomes a local that the
  /// predecessor writes and the successor reads. The write has to happen where
  /// the value is still correct — at the end of the predecessor, after its last
  /// statement — which is why this node lives next to the transfer and not at
  /// the top of the block that consumes it.
  NAssign(Int32, ValType, Expr)
  /// A note for the reader. Emitted where code was dropped, so that dropping it
  /// is visible rather than silent.
  NComment(String)
}

// --- the transfer out of a block ------------------------------------------

// Kinds of block terminator, after resolution against the layout.
//
// A flat record rather than an enum with payloads: `SBrIf` needs a *conditional*
// version of each of the three transfers, and a `Xfer` inside `Xfer` would be a
// recursive type for no gain — the condition is the only thing that nests, and
// it is already an `Expr`.

///|
let x_none : Int32 = 0

///|
let x_to : Int32 = 1

///|
let x_cont : Int32 = 2

///|
let x_brk : Int32 = 3

///|
let x_ret : Int32 = 4

///|
let x_trap : Int32 = 5

///|
let x_if : Int32 = 6

///|
let x_table : Int32 = 7

///|
let x_skip : Int32 = 8

///|
/// Where a block goes when it finishes.
priv struct Xfer {
  kind : Int32
  /// Target construct, for `x_to` / `x_cont` / `x_brk`.
  target : Int32
  /// Per-index targets, for `x_table`.
  table : Array[Int32]
  /// Target past the end of the table.
  dflt : Int32
  /// The condition of a conditional transfer, or the selector of a `br_table`.
  cond : Expr?
  vals : Array[Expr]
}

///|
fn no_xfer() -> Xfer {
  { kind: x_none, target: -1, table: [], dflt: -1, cond: None, vals: [], }
}

// --- the emission context -------------------------------------------------

///|
/// Everything the emitter needs, resolved once.
///
/// The transfers are computed up front because the emitter asks questions about
/// them *before* reaching the block: "does any branch inside this construct
/// escape past it?" decides whether a guard is emitted after it, and that
/// question is about the whole subtree.
priv struct Ctx {
  l : Layout
  g : Cfg
  fs : FuncStack
  /// Per block: its resolved terminator.
  xf : Array[Xfer]
  /// Per instruction position: the lowest-numbered construct that opens there.
  /// Constructs are numbered in opening order, so the lowest number at a
  /// position is the outermost one — the one whose parent is the construct the
  /// emitter is currently walking.
  first_at : Array[Int32]
  /// Per instruction position: the block containing it. An edge is named by the
  /// block it lands in, so "where does this construct end" has to resolve to a
  /// block index.
  block_at : Array[Int32]
  cons : Int32
  /// Reachable blocks, i.e. the number of blocks the walker has to emit.
  reach : Int32
  /// Blocks emitted so far. A structured function must end with
  /// `visited == reach`; anything else means code was dropped or duplicated.
  mut visited : Int32
  /// Slots reserved per block for entry values, so that block `b` slot `k` has a
  /// name of its own no matter how many other blocks are live at the same time.
  stride : Int32
}

///|
fn new_ctx(l : Layout, g : Cfg, fs : FuncStack) -> Ctx {
  let nb = g.block_count()
  let xf : Array[Xfer] = []
  let mut b = 0
  while b < nb {
    xf.push(resolve_xfer(l, g, fs, b))
    b = b + 1
  }
  let block_at = Array::make(l.total + 1, -1)
  b = 0
  while b < nb {
    let blk = g.blocks[b]
    let mut k = blk.first
    while k < blk.end {
      block_at[k] = b
      k = k + 1
    }
    b = b + 1
  }
  let cons = l.kind.length()
  let first_at = Array::make(l.total + 1, -1)
  let mut c = cons - 1
  while c >= 1 {
    first_at[l.open[c]] = c
    c = c - 1
  }
  let mut reach = 0
  b = 0
  while b < nb {
    if g.blocks[b].reachable {
      reach = reach + 1
    }
    b = b + 1
  }
  // Entry widths decide the naming scheme: block `b` slot `k` is temp
  // `fs.temps + b * stride + k`. A shared counter would collide, because a block
  // nested inside another block is live at the same time as its host.
  let mut stride = 1
  b = 0
  while b < nb {
    let w = fs.blocks[b].entry.length()
    if w > stride {
      stride = w
    }
    b = b + 1
  }
  { l, g, fs, xf, first_at, block_at, cons, reach, visited: 0, stride, }
}

///|
/// The temp holding block `b`'s `k`-th entry value.
fn in_temp(ctx : Ctx, b : Int32, k : Int32) -> Int32 {
  ctx.fs.temps + b * ctx.stride + k
}

///|
/// Replace `in0`-style references to a block's own parameters with the temps
/// that carry them.
///
/// The substitution happens when the tree is built, not when it is printed: a
/// block's statements and its exit values are the only places its parameters can
/// appear, and both are produced by `split_block`, which knows the block.
fn subst(ctx : Ctx, b : Int32, e : Expr) -> Expr {
  match e {
    EParam(k) => ETemp(in_temp(ctx, b, k))
    EConst(_) | ELocal(_) | EGlobal(_) | ETemp(_) | EMemorySize => e
    ELoad(op, a) => ELoad(op, subst(ctx, b, a))
    EBin(t, k, x, y) => EBin(t, k, subst(ctx, b, x), subst(ctx, b, y))
    EUn(t, k, x) => EUn(t, k, subst(ctx, b, x))
    EConv(f, t, m, x) => EConv(f, t, m, subst(ctx, b, x))
    ECall(f, args) => ECall(f, subst_list(ctx, b, args))
    ESelect(x, y, z) =>
      ESelect(subst(ctx, b, x), subst(ctx, b, y), subst(ctx, b, z))
    EMemoryGrow(x) => EMemoryGrow(subst(ctx, b, x))
  }
}

///|
fn subst_list(ctx : Ctx, b : Int32, xs : Array[Expr]) -> Array[Expr] {
  let out : Array[Expr] = []
  for x in xs {
    out.push(subst(ctx, b, x))
  }
  out
}

///|
fn subst_stmt(ctx : Ctx, b : Int32, s : Stmt) -> Stmt {
  match s {
    SLocal(i, e) => SLocal(i, subst(ctx, b, e))
    SGlobal(i, e) => SGlobal(i, subst(ctx, b, e))
    STemp(t, e) => STemp(t, subst(ctx, b, e))
    SStore(op, a, v) => SStore(op, subst(ctx, b, a), subst(ctx, b, v))
    SEval(e) => SEval(subst(ctx, b, e))
    SIf(e) => SIf(subst(ctx, b, e))
    SBr(d, vs) => SBr(d, subst_list(ctx, b, vs))
    SBrIf(d, vs, c) => SBrIf(d, subst_list(ctx, b, vs), subst(ctx, b, c))
    SBrTable(ls, d, vs, c) =>
      SBrTable(ls, d, subst_list(ctx, b, vs), subst(ctx, b, c))
    SReturn(vs) => SReturn(subst_list(ctx, b, vs))
    SUnreachable => s
  }
}

///|
fn subst_stmts(ctx : Ctx, b : Int32, xs : Array[Stmt]) -> Array[Stmt] {
  let out : Array[Stmt] = []
  for x in xs {
    out.push(subst_stmt(ctx, b, x))
  }
  out
}

// --- resolving a terminator ----------------------------------------------

///|
/// True when leaving construct `t` also leaves the function.
///
/// A construct whose `end` is the last instruction of the body has nothing after
/// it, so a branch to it is a `return` wearing a label. A `loop` is excluded: a
/// branch to one re-enters it, so its `close` is not a position control ever
/// reaches by branching.
fn leaves_function(l : Layout, t : Int32) -> Bool {
  t > 0 && l.kind[t] != 1 && l.close[t] >= l.total
}

///|
/// The construct a branch leaves or re-enters, given the *instruction* it is and
/// the wasm label depth it names.
///
/// Three answers, and the difference between them is the whole of the
/// structuring problem: a re-entered loop needs no state (`continue`), a left
/// block needs none either (`break`), and anything further out needs the `brk`
/// variable because the target is not the level the code is in.
fn transfer_of(l : Layout, at : Int32, t : Int32) -> (Int32, Int32) {
  if t < 0 || leaves_function(l, t) {
    // A branch past the outermost label is a return; the simulator rewrites
    // those, so the second case is the only one that gets here in practice.
    return (x_ret, t)
  }
  let q = l.owner[at]
  if t == q {
    if l.kind[t] == 1 {
      (x_cont, t)
    } else {
      (x_brk, t)
    }
  } else {
    (x_to, t)
  }
}

///|
fn resolve_xfer(l : Layout, g : Cfg, fs : FuncStack, b : Int32) -> Xfer {
  let blk = g.blocks[b]
  if !blk.reachable {
    return {
      kind: x_skip,
      target: -1,
      table: [],
      dflt: -1,
      cond: None,
      vals: [],
    }
  }
  let stmts = fs.blocks[b].stmts
  if stmts.length() == 0 {
    return no_xfer()
  }
  let at = blk.end - 1
  match stmts[stmts.length() - 1] {
    SBr(d, vals) => {
      let (k, t) = transfer_of(l, at, branch_construct(l, at, d))
      { kind: k, target: t, table: [], dflt: -1, cond: None, vals, }
    }
    SBrIf(d, vals, cond) => {
      let (k, t) = transfer_of(l, at, branch_construct(l, at, d))
      // `vals` is kept: a `br_if` inside a `(result i32)` block carries a value
      // on the taken side, and the edge is the only place it can be written
      // down. It is the same list the fall-through keeps on the stack.
      { kind: k, target: t, table: [], dflt: -1, cond: Some(cond), vals, }
    }
    SBrTable(ls, d, vals, idx) => {
      let table : Array[Int32] = []
      for x in ls {
        let (_, t) = transfer_of(l, at, branch_construct(l, at, x))
        table.push(t)
      }
      let (_, dt) = transfer_of(l, at, branch_construct(l, at, d))
      { kind: x_table, target: -1, table, dflt: dt, cond: Some(idx), vals, }
    }
    SReturn(vals) =>
      { kind: x_ret, target: -1, table: [], dflt: -1, cond: None, vals, }
    SUnreachable =>
      { kind: x_trap, target: -1, table: [], dflt: -1, cond: None, vals: [], }
    SIf(cond) =>
      {
        kind: x_if,
        target: -1,
        table: [],
        dflt: -1,
        cond: Some(cond),
        vals: [],
      }
    _ => no_xfer()
  }
}

// --- queries over the transfers ------------------------------------------

///|
/// True when construct `t` is `c` itself or an ancestor of it — i.e. a branch to
/// `t` passes *through* `c` and has to be carried past it.
fn reaches_past(l : Layout, t : Int32, c : Int32) -> Bool {
  if leaves_function(l, t) {
    return false
  }
  let mut p = c
  let mut ans = false
  let mut go = t >= 0
  while go {
    if p == t {
      ans = true
      go = false
    } else if p == 0 {
      go = false
    } else {
      p = l.parent[p]
    }
  }
  ans
}

///|
fn xfer_targets_any(x : Xfer, l : Layout, c : Int32) -> Bool {
  if x.kind == x_to || x.kind == x_cont || x.kind == x_brk {
    return reaches_past(l, x.target, c)
  }
  if x.kind != x_table {
    return false
  }
  let mut found = false
  for t in x.table {
    if reaches_past(l, t, c) {
      found = true
    }
  }
  if reaches_past(l, x.dflt, c) {
    found = true
  }
  found
}

///|
/// True when some branch inside construct `c` targets `c` itself.
///
/// This is the one case an `if` cannot express: leaving an `if` early means
/// skipping the rest of an arm, and an arm has no loop to `break` out of. The
/// arm gets a one-shot loop of its own, and this predicate is what decides it.
fn xfer_hits(ctx : Ctx, x : Xfer, c : Int32) -> Bool {
  if x.kind == x_to || x.kind == x_cont || x.kind == x_brk {
    return !leaves_function(ctx.l, x.target) && x.target == c
  }
  if x.kind != x_table {
    return false
  }
  let mut found = false
  for t in x.table {
    if !leaves_function(ctx.l, t) && t == c {
      found = true
    }
  }
  if !leaves_function(ctx.l, x.dflt) && x.dflt == c {
    found = true
  }
  found
}

///|
/// Apply `f` to every block whose first instruction lies in `[lo, hi)`.
fn for_blocks_in(
  ctx : Ctx,
  lo : Int32,
  hi : Int32,
  f : (Int32) -> Bool,
) -> Bool {
  let mut b = 0
  let mut found = false
  let mut go = true
  while b < ctx.g.block_count() && go {
    let blk = ctx.g.blocks[b]
    if blk.first >= hi {
      go = false
    } else {
      if blk.first >= lo && f(b) {
        found = true
        go = false
      }
      b = b + 1
    }
  }
  found
}

///|
/// True when a branch inside construct `c` needs carrying past it, so the code
/// after the construct has to look at `brk`.
///
/// Without this test every construct would be followed by a guard, which is
/// correct but would bury the shape of the function in bookkeeping.
fn escapes_out(ctx : Ctx, c : Int32) -> Bool {
  for_blocks_in(ctx, ctx.l.open[c], ctx.l.close[c], fn(b) {
    xfer_targets_any(ctx.xf[b], ctx.l, c)
  })
}

///|
/// True when a branch inside `[lo, hi)` targets construct `c` itself.
fn self_hit_in(ctx : Ctx, c : Int32, lo : Int32, hi : Int32) -> Bool {
  for_blocks_in(ctx, lo, hi, fn(b) { xfer_hits(ctx, ctx.xf[b], c) })
}

// --- emission ------------------------------------------------------------

///|
/// The construct opening exactly at position `p` whose parent is `cid`, or -1.
fn Ctx::opener_at(self : Ctx, p : Int32, cid : Int32) -> Int32 {
  let mut c = self.first_at[p]
  while c >= 1 && c < self.cons && self.l.open[c] == p {
    if self.l.parent[c] == cid {
      return c
    }
    c = c + 1
  }
  -1
}

///|
/// The block a transfer lands in, or -1 when it leaves the function.
fn succ_block(ctx : Ctx, t : Int32) -> Int32 {
  if t < 0 || leaves_function(ctx.l, t) {
    return -1
  }
  let p = if ctx.l.kind[t] == 1 { ctx.l.open[t] } else { ctx.l.close[t] }
  if p < 0 || p >= ctx.l.total {
    return -1
  }
  ctx.block_at[p]
}

///|
/// The edge that hands `from`'s exit values to `to`, when `to` expects any.
///
/// Most edges carry nothing — in the MVP subset a block's entry is empty unless
/// something branches to it with a value on the stack — so the node is emitted
/// only when the target has an entry. That keeps the tree readable without
/// hiding anything: an edge that carries nothing has nothing to show.
fn push_edges(ctx : Ctx, out : Array[Node], from : Int32, to : Int32) -> Unit {
  push_edges_vals(ctx, out, from, to, ctx.fs.blocks[from].exit_exprs)
}

///|
/// The same edge, with the values the branch transfers given explicitly.
///
/// Two statements describe the same edge and they do not always agree. The
/// branch statement knows exactly what it carries; the block's exit stack knows
/// what was left on it, which is the same thing whenever the branch carries
/// everything the successor needs. It does not when the branch carries *less*:
/// a branch to a `loop` transfers the loop's parameters, which the MVP subset
/// cannot express, so `wants` is empty while the destination — a loop body
/// re-entered with the values it reads at its top — still has an entry shape.
/// There the exit stack is the only record of the values, so the longer of the
/// two lists wins. When they disagree in the other direction the statement is
/// used, because a type marker on the exit stack is not a value.
fn push_edges_vals(
  ctx : Ctx,
  out : Array[Node],
  from : Int32,
  to : Int32,
  vals : Array[Expr],
) -> Unit {
  if to < 0 || to >= ctx.fs.blocks.length() {
    return
  }
  let n = ctx.fs.blocks[to].entry.length()
  if n == 0 {
    return
  }
  out.push(NEdge(from, to))
  let exit = ctx.fs.blocks[from].exit_exprs
  let src = if vals.length() >= n { vals } else { exit }
  let mut k = 0
  while k < n && k < src.length() {
    // The type comes from the *destination* block's entry shape: that is what
    // the value has to be, and it is the only statement the successor can read.
    out.push(
      NAssign(
        in_temp(ctx, to, k),
        ctx.fs.blocks[to].entry[k],
        subst(ctx, from, src[k]),
      ),
    )
    k = k + 1
  }
}

///|
fn with_edge(
  ctx : Ctx,
  from : Int32,
  to : Int32,
  xs : Array[Node],
) -> Array[Node] {
  let out : Array[Node] = []
  push_edges(ctx, out, from, to)
  for x in xs {
    out.push(x)
  }
  out
}

///|
/// The statements of a block, with its terminator turned into nodes.
///
/// The terminator is kept in the statement list for the `if` case and removed
/// for every other one, because an `if` is emitted by the construct walker
/// (which needs the condition) while a branch is emitted where the block is.
fn split_block(ctx : Ctx, b : Int32) -> (Array[Stmt], Array[Node]) {
  let blk = ctx.g.blocks[b]
  let stmts = subst_stmts(ctx, b, ctx.fs.blocks[b].stmts)
  let x = ctx.xf[b]
  if x.kind == x_none {
    // A block that falls into the exit block is falling off the end of the
    // function — because it is the last one, or because the construct it is in
    // ends there. Either way the values on its exit stack *are* the result, and
    // this is the only point where the expressions that produced them are still
    // in scope.
    if blk.succ.length() > 0 && blk.succ[0] == ctx.g.exit {
      return (stmts, [NReturn(subst_list(ctx, b, ctx.fs.blocks[b].exit_exprs))])
    }
    let out : Array[Node] = []
    if blk.succ.length() > 0 {
      push_edges(ctx, out, b, blk.succ[0])
    }
    return (stmts, out)
  }
  // `if` keeps its condition statement: the construct walker pulls it out and
  // turns it into the opening of the two arms. A skipped block has nothing to
  // lower. Everything else ends in a transfer, which replaces the terminator.
  if x.kind == x_if || x.kind == x_skip || stmts.length() == 0 {
    return (stmts, [])
  }
  let kept : Array[Stmt] = []
  let mut k = 0
  while k < stmts.length() - 1 {
    kept.push(stmts[k])
    k = k + 1
  }
  (kept, xfer_nodes(ctx, b, x))
}

///|
/// The node for a transfer to construct `t`, carrying `vals`.
fn transfer_node(ctx : Ctx, at : Int32, t : Int32, vals : Array[Expr]) -> Node {
  if t < 0 || leaves_function(ctx.l, t) {
    // Outside the construct there is nothing left to receive the values, so
    // leaving it at the end of the body *is* returning them.
    return NReturn(vals)
  }
  let q = ctx.l.owner[at]
  if ctx.l.kind[t] == 1 {
    if t == q {
      NContinue
    } else {
      NUnwind(t)
    }
  } else if t == q {
    NBreak
  } else {
    NUnwind(t)
  }
}

///|
/// One arm of a `br_table`: hand the values over, then transfer.
fn table_arm(
  ctx : Ctx,
  b : Int32,
  at : Int32,
  t : Int32,
  vals : Array[Expr],
) -> Node {
  let arm : Array[Node] = []
  // Every arm of the table transfers the same list, taken out of the branch
  // instruction rather than from the block's exit stack.
  push_edges_vals(ctx, arm, b, succ_block(ctx, t), vals)
  arm.push(transfer_node(ctx, at, t, vals))
  NSeq(arm)
}

///|
fn xfer_nodes(ctx : Ctx, b : Int32, x : Xfer) -> Array[Node] {
  let at = ctx.g.blocks[b].end - 1
  let blk = ctx.g.blocks[b]
  let out : Array[Node] = []
  // Branch payloads are values of *this* block, so their parameters are this
  // block's too.
  let x = {
    let y = x
    let vals = subst_list(ctx, b, y.vals)
    match y.cond {
      Some(c) => { ..y, vals, cond: Some(subst(ctx, b, c)), }
      None => { ..y, vals, }
    }
  }
  if x.kind == x_to || x.kind == x_cont || x.kind == x_brk {
    let tr = transfer_node(ctx, at, x.target, x.vals)
    match x.cond {
      Some(c) => {
        let arm : Array[Node] = []
        push_edges_vals(ctx, arm, b, succ_block(ctx, x.target), x.vals)
        arm.push(tr)
        out.push(NIf(c, arm, []))
        // The other side of a conditional branch is the fall-through, and it
        // receives the same values.
        if blk.succ.length() > 1 {
          push_edges(ctx, out, b, blk.succ[1])
        }
      }
      None => {
        push_edges_vals(ctx, out, b, succ_block(ctx, x.target), x.vals)
        out.push(tr)
      }
    }
    return out
  }
  if x.kind == x_ret {
    match x.cond {
      Some(c) => {
        // `br_if` whose target is the end of the body: the taken side returns,
        // the other side carries on into the next block. Dropping the condition
        // here would turn "return if empty" into "return", which is the
        // difference between a loop and a body that quits on the first
        // iteration.
        let arm : Array[Node] = [NReturn(x.vals)]
        out.push(NIf(c, arm, []))
        if blk.succ.length() > 1 {
          push_edges(ctx, out, b, blk.succ[1])
        }
        return out
      }
      None => return [NReturn(x.vals)]
    }
  }
  if x.kind == x_trap {
    return [NTrap]
  }
  if x.kind == x_table {
    let idx = match x.cond {
      Some(c) => c
      None => EConst(I32V(0))
    }
    let arms : Array[Node] = []
    for t in x.table {
      arms.push(table_arm(ctx, b, at, t, x.vals))
    }
    return [NSwitch(idx, arms, table_arm(ctx, b, at, x.dflt, x.vals))]
  }
  out
}

///|
/// Emit every block whose first instruction lies in `[lo, hi)`.
///
/// Unreachable blocks are not simulated, so their statement list is empty; they
/// are reported as one comment per run rather than dropped, because code that
/// disappears silently cannot be audited.
fn emit_leaves(ctx : Ctx, out : Array[Node], lo : Int32, hi : Int32) -> Unit {
  if lo >= hi {
    return
  }
  let mut b = 0
  let mut dead_run = false
  while b < ctx.g.block_count() {
    let blk = ctx.g.blocks[b]
    if blk.first >= hi {
      break
    }
    if blk.first >= lo {
      if blk.reachable {
        ctx.visited = ctx.visited + 1
        let (body, trs) = split_block(ctx, b)
        if body.length() > 0 {
          out.push(NLeaf(body, b))
        }
        for n in trs {
          out.push(n)
        }
        dead_run = false
      } else if !dead_run {
        out.push(NComment("b\{b} is unreachable"))
        dead_run = true
      }
    }
    b = b + 1
  }
}

///|
/// The body of a construct, walked in program order.
///
/// `loop_id` is the construct whose loop encloses this range (-1 for an
/// anonymous wrapper), and `has_loop` says whether there is one at all — the two
/// together decide what a guard after a child can do. When there is no loop, the
/// only escape left is "forget the request", which `NBrkReset` spells out.
fn emit_range(
  ctx : Ctx,
  cid : Int32,
  lo : Int32,
  hi : Int32,
  loop_id : Int32,
  has_loop : Bool,
) -> Array[Node] {
  let out : Array[Node] = []
  let mut cursor = lo
  let mut i = lo
  while i < hi {
    let c = ctx.opener_at(i, cid)
    if c < 0 {
      i = i + 1
    } else {
      emit_leaves(ctx, out, cursor, i)
      if ctx.l.kind[c] == 2 {
        emit_if(ctx, out, c, loop_id, has_loop)
      } else {
        out.push(emit_construct(ctx, c))
      }
      if escapes_out(ctx, c) {
        if has_loop {
          out.push(NGuard(c, cont_of(ctx, loop_id)))
        } else {
          out.push(NBrkReset)
        }
      }
      i = ctx.l.close[c]
      cursor = i
    }
  }
  emit_leaves(ctx, out, cursor, hi)
  out
}

///|
/// The construct whose `continue` is valid in the current scope, or -1.
///
/// Only a `loop` offers one: a `block`'s one-shot loop repeats nothing, so
/// `continue` there would restart a body that has already ended.
fn cont_of(ctx : Ctx, loop_id : Int32) -> Int32 {
  if loop_id >= 0 && ctx.l.kind[loop_id] == 1 {
    loop_id
  } else {
    -1
  }
}

///|
fn emit_construct(ctx : Ctx, c : Int32) -> Node {
  let body = emit_range(ctx, c, ctx.l.open[c], ctx.l.close[c], c, true)
  if ctx.l.kind[c] == 1 {
    NWhileLoop(c, body)
  } else {
    NWhileBrk(c, body)
  }
}

///|
/// Take the `if (cond)` statement that the construct's condition lives on.
///
/// The `if` instruction is the last instruction of the block before the arm, and
/// its statement is therefore the last statement of the last leaf emitted. It
/// cannot be left in place: `if (cond)` on its own is not a statement, it is the
/// opening of the one below it.
fn take_if_cond(out : Array[Node]) -> Expr? {
  if out.length() == 0 {
    return None
  }
  let last = out[out.length() - 1]
  match last {
    NLeaf(stmts, b) => {
      if stmts.length() == 0 {
        return None
      }
      let n = stmts.length()
      match stmts[n - 1] {
        SIf(cond) => {
          let kept : Array[Stmt] = []
          let mut k = 0
          while k < n - 1 {
            kept.push(stmts[k])
            k = k + 1
          }
          let _ = out.pop()
          if kept.length() > 0 {
            out.push(NLeaf(kept, b))
          }
          Some(cond)
        }
        _ => None
      }
    }
    _ => None
  }
}

///|
/// Emit an `if` construct: the condition from the block before it, then the two
/// arms.
///
/// An arm is wrapped in a one-shot loop exactly when a branch inside it targets
/// this `if` — that branch has to skip the rest of the arm, and the arm has no
/// loop of its own to break out of. Wrapping is per arm, not per `if`, because
/// the common case has no such branch and `while true { ... }` around every arm
/// would be noise.
fn emit_if(
  ctx : Ctx,
  out : Array[Node],
  c : Int32,
  loop_id : Int32,
  has_loop : Bool,
) -> Unit {
  let cond = take_if_cond(out)
  let then_hi = if ctx.l.else_at[c] >= 0 {
    ctx.l.else_at[c]
  } else {
    ctx.l.close[c]
  }
  let mut then_nodes = emit_arm(
    ctx,
    c,
    ctx.l.open[c],
    then_hi,
    loop_id,
    has_loop,
  )
  let mut else_nodes = if ctx.l.else_at[c] >= 0 {
    emit_arm(ctx, c, ctx.l.else_at[c], ctx.l.close[c], loop_id, has_loop)
  } else {
    ([] : Array[Node])
  }
  // The block that ended with this `if` hands its exit values to both arms:
  // the operand stack below the condition is the same whichever arm runs.
  if ctx.l.open[c] > 0 {
    let pb = ctx.block_at[ctx.l.open[c] - 1]
    if pb >= 0 {
      let succ = ctx.g.blocks[pb].succ
      if succ.length() > 1 {
        then_nodes = with_edge(ctx, pb, succ[0], then_nodes)
        else_nodes = with_edge(ctx, pb, succ[1], else_nodes)
      }
    }
  }
  match cond {
    Some(cd) => out.push(NIf(cd, then_nodes, else_nodes))
    // An `if` in code no live path reaches: the block that held its condition
    // was not simulated, so there is no condition to test. Report it instead of
    // inventing one.
    None => out.push(NComment("if c\{c}: dead code, no condition recovered"))
  }
}

///|
fn emit_arm(
  ctx : Ctx,
  c : Int32,
  lo : Int32,
  hi : Int32,
  loop_id : Int32,
  has_loop : Bool,
) -> Array[Node] {
  if self_hit_in(ctx, c, lo, hi) {
    // A `break` lands at the end of the wrapped arm, which is exactly where a
    // branch to this `if` wants to continue.
    [NWhileBrk(-1, emit_range(ctx, c, lo, hi, -1, true))]
  } else {
    emit_range(ctx, c, lo, hi, loop_id, has_loop)
  }
}

// --- the tree, and its size ----------------------------------------------

///|
/// One function after structuring, with the numbers the documents quote.
pub struct FunctionTree {
  idx : Int32
  root : Node
  /// Constructs a branch escapes to, sorted — i.e. the values `brk` can hold.
  targets : Array[Int32]
  nodes : Int32
  leaves : Int32
  /// Reachable blocks emitted, and how many there were to emit.
  blocks : Int32
  total_blocks : Int32
  guards : Int32
  switches : Int32
  depth : Int32
  skipped : String
  refusal : Diag?
}

///|
fn empty_tree(idx : Int32) -> FunctionTree {
  {
    idx,
    root: NSeq([]),
    targets: [],
    nodes: 0,
    leaves: 0,
    blocks: 0,
    total_blocks: 0,
    guards: 0,
    switches: 0,
    depth: 0,
    skipped: "",
    refusal: None,
  }
}

///|
fn collect_targets(ctx : Ctx) -> Array[Int32] {
  let seen : Array[Int32] = []
  let mut b = 0
  while b < ctx.g.block_count() {
    let x = ctx.xf[b]
    if x.kind == x_to || x.kind == x_cont || x.kind == x_brk {
      if x.target >= 0 && !contains_int(seen, x.target) {
        seen.push(x.target)
      }
    } else if x.kind == x_table {
      for t in x.table {
        if t >= 0 && !contains_int(seen, t) {
          seen.push(t)
        }
      }
      if x.dflt >= 0 && !contains_int(seen, x.dflt) {
        seen.push(x.dflt)
      }
    }
    b = b + 1
  }
  sort_ints(seen)
  seen
}

///|
/// Count nodes and the deepest nesting, in one walk.
fn measure(n : Node) -> (Int32, Int32, Int32, Int32, Int32) {
  match n {
    NSeq(xs) => {
      let mut nodes = 0
      let mut leaves = 0
      let mut guards = 0
      let mut switches = 0
      let mut depth = 0
      for x in xs {
        let (n2, l2, g2, s2, d2) = measure(x)
        nodes = nodes + n2
        leaves = leaves + l2
        guards = guards + g2
        switches = switches + s2
        if d2 > depth {
          depth = d2
        }
      }
      (nodes + 1, leaves, guards, switches, depth)
    }
    NLeaf(_, _) => (1, 1, 0, 0, 1)
    NWhileBrk(_, xs) | NWhileLoop(_, xs) => {
      let (n2, l2, g2, s2, d2) = measure(NSeq(xs))
      (n2 + 1, l2, g2, s2, d2 + 1)
    }
    NIf(_, a, b) => {
      let (na, la, ga, sa, da) = measure(NSeq(a))
      let (nb, lb, gb, sb, db) = measure(NSeq(b))
      let d = if da > db { da } else { db }
      (na + nb + 1, la + lb, ga + gb, sa + sb, d + 1)
    }
    NSwitch(_, arms, dflt) => {
      let mut nodes = 2
      let mut leaves = 0
      let mut switches = 1
      let mut depth = 1
      for a in arms {
        let (n2, l2, _, s2, d2) = measure(a)
        nodes = nodes + n2
        leaves = leaves + l2
        switches = switches + s2
        if d2 + 1 > depth {
          depth = d2 + 1
        }
      }
      let (nd, ld, _, sd, dd) = measure(dflt)
      nodes = nodes + nd
      leaves = leaves + ld
      switches = switches + sd
      if dd + 1 > depth {
        depth = dd + 1
      }
      (nodes, leaves, 0, switches, depth)
    }
    NGuard(_, _) => (1, 0, 1, 0, 1)
    _ => (1, 0, 0, 0, 1)
  }
}

// --- the public entry point ----------------------------------------------

///|
/// Structure one function.
///
/// A body outside the subset comes back as a tree that says why rather than as
/// an error: a refusal is a *decision* about one function, and the module it
/// belongs to is still worth reporting on.
pub fn structure_func(m : Module, idx : Int32) -> Result[FunctionTree, Diag] {
  let fs = match analyze_func(m, idx) {
    Err(d) => return Err(d)
    Ok(f) => f
  }
  if fs.skipped != "" {
    let t = empty_tree(idx)
    return Ok({ ..t, skipped: fs.skipped, })
  }
  match fs.refusal {
    Some(d) => {
      let t = empty_tree(idx)
      return Ok({ ..t, refusal: Some(d), })
    }
    None => ()
  }
  // `analyze_func` builds the layout and the graph internally and keeps them to
  // itself. Decoding one body a second time is cheaper than widening its
  // interface with two values only this stage wants, and it keeps the two
  // stages independent: neither can be changed without the other noticing.
  let body = match attempt(() => decode_func(m, idx)) {
    Ok(b) => b
    Err(d) => return Err(d)
  }
  let l = match build_layout(body.instrs) {
    None => {
      let t = empty_tree(idx)
      return Ok({ ..t, skipped: "brackets do not balance", })
    }
    Some(x) => x
  }
  let g = build_cfg(l)
  let ctx = new_ctx(l, g, fs)
  let root = NSeq(emit_range(ctx, 0, 0, l.total, -1, false))
  let (nodes, leaves, guards, switches, depth) = measure(root)
  Ok({
    idx,
    root,
    targets: collect_targets(ctx),
    nodes,
    leaves,
    blocks: ctx.visited,
    total_blocks: ctx.reach,
    guards,
    switches,
    depth,
    skipped: "",
    refusal: None,
  })
}

// --- rendering ------------------------------------------------------------

///|
/// A construct reference that a reader can follow: `c5` for a construct, `?` for
/// the anonymous wrapper.
fn cons_name(c : Int32) -> String {
  if c < 0 {
    "the arm".to_string()
  } else {
    "c\{c}"
  }
}

///|
fn render_seq(xs : Array[Node], m : Module, level : Int32) -> String {
  let b = StringBuilder()
  for x in xs {
    b.write_string(x.render(m, level))
  }
  b.to_string()
}

///|
/// One node on a single line, for the arms of a `match` — which in practice are
/// always single transfers, so joining them is faithful rather than lossy.
fn one_line(n : Node, m : Module) -> String {
  let s = n.render(m, 0)
  let b = StringBuilder()
  let mut first = true
  for part in s.split("\n") {
    let t = part.to_owned()
    if t != "" {
      if !first {
        b.write_string("; ")
      }
      b.write_string(t)
      first = false
    }
  }
  b.write_string("\n")
  b.to_string()
}

///|
/// Pseudo-code for one node, indented. Not MoonBit — the generated source is
/// S7's job and has to name variables, types and traps differently. This is the
/// shape, printed so it can be checked against `--cfg` by eye.
pub fn Node::render(self : Node, m : Module, level : Int32) -> String {
  let pad = indent(level)
  let b = StringBuilder()
  match self {
    NSeq(xs) =>
      for x in xs {
        b.write_string(x.render(m, level))
      }
    NLeaf(stmts, blk) => {
      b.write_string("\{pad};; b\{blk}\n")
      for s in stmts {
        b.write_string("\{pad}\{s.render(m)}\n")
      }
    }
    NWhileBrk(c, xs) => {
      b.write_string("\{pad}while true {   ;; \{cons_name(c)}, one-shot\n")
      b.write_string(render_seq(xs, m, level + 1))
      b.write_string("\{pad}  break\n\{pad}}\n")
    }
    NWhileLoop(c, xs) => {
      b.write_string("\{pad}while true {   ;; \{cons_name(c)}, loop\n")
      b.write_string(render_seq(xs, m, level + 1))
      b.write_string("\{pad}  if (brk != \{c}) { break }\n")
      b.write_string("\{pad}  brk = -1\n\{pad}}\n")
    }
    NIf(cond, a, b2) => {
      b.write_string("\{pad}if (\{cond.render(m)}) {\n")
      b.write_string(render_seq(a, m, level + 1))
      if b2.length() > 0 {
        b.write_string("\{pad}} else {\n")
        b.write_string(render_seq(b2, m, level + 1))
      }
      b.write_string("\{pad}}\n")
    }
    NUnwind(c) =>
      b.write_string("\{pad}brk = \{c}; break   ;; leave \{cons_name(c)}\n")
    NContinue => b.write_string("\{pad}continue\n")
    NBreak => b.write_string("\{pad}break\n")
    NReturn(vs) => b.write_string("\{pad}return \{render_vals(vs, m)}\n")
    NTrap => b.write_string("\{pad}unreachable\n")
    NSwitch(idx, arms, dflt) => {
      b.write_string("\{pad}match (\{idx.render(m)}) {\n")
      let mut i = 0
      for a in arms {
        b.write_string("\{pad}  \{i} => ")
        b.write_string(one_line(a, m))
        i = i + 1
      }
      b.write_string("\{pad}  _ => ")
      b.write_string(one_line(dflt, m))
      b.write_string("\{pad}}\n")
    }
    NGuard(child, cont) => {
      b.write_string("\{pad}if (brk >= 0) {\n")
      b.write_string("\{pad}  if (brk == \{child}) { brk = -1 }\n")
      if cont >= 0 {
        b.write_string(
          "\{pad}  else if (brk == \{cont}) { brk = -1; continue }\n",
        )
      }
      b.write_string("\{pad}  else { break }\n\{pad}}\n")
    }
    NEdge(from, to) => b.write_string("\{pad};; edge b\{from} -> b\{to}\n")
    NAssign(t, _, e) => b.write_string("\{pad}t\{t} = \{e.render(m)}\n")
    NBrkReset => b.write_string("\{pad}brk = -1\n")
    NComment(s) => b.write_string("\{pad};; \{s}\n")
  }
  b.to_string()
}

///|
/// One function, as pseudo-code.
pub fn FunctionTree::render(self : FunctionTree, m : Module) -> String {
  let b = StringBuilder()
  b.write_string(
    "\nfunc \{self.idx} \{m.func_label(self.idx)}\{render_signature(m.func_type(self.idx))}\n",
  )
  if self.skipped != "" {
    b.write_string("  skipped: \{self.skipped}\n")
    return b.to_string()
  }
  match self.refusal {
    Some(d) => {
      b.write_string("  refused: \{d.render()}\n")
      return b.to_string()
    }
    None => ()
  }
  if self.targets.length() > 0 {
    b.write_string("  ;; brk: ")
    let mut i = 0
    for t in self.targets {
      if i > 0 {
        b.write_string(", ")
      }
      b.write_string("\{t} = \{cons_name(t)}")
      i = i + 1
    }
    b.write_string("\n")
  }
  b.write_string(self.root.render(m, 1))
  b.to_string()
}

// --- whole-module views ---------------------------------------------------

///|
/// Aggregate numbers over a module, for `--struct --stats` and the documents.
pub struct StructStats {
  funcs : Int32
  structured : Int32
  skipped : Int32
  refused : Int32
  nodes : Int32
  leaves : Int32
  blocks : Int32
  total_blocks : Int32
  guards : Int32
  switches : Int32
  max_depth : Int32
  s_skipped : Array[String]
  s_refused : Array[String]
}

///|
pub fn struct_stats(m : Module) -> StructStats {
  let mut funcs = 0
  let mut structured = 0
  let mut skipped = 0
  let mut refused = 0
  let mut nodes = 0
  let mut leaves = 0
  let mut blocks = 0
  let mut total_blocks = 0
  let mut guards = 0
  let mut switches = 0
  let mut max_depth = 0
  let s_skipped : Array[String] = []
  let s_refused : Array[String] = []
  let mut i = 0
  while i < m.func_count() {
    match m.code_of(i) {
      Some(_) => {
        funcs = funcs + 1
        let t = structure_func(m, i)
        match t {
          Err(d) => {
            refused = refused + 1
            s_refused.push("\{i}: \{d.render()}")
          }
          Ok(t) =>
            if t.skipped != "" {
              skipped = skipped + 1
              s_skipped.push("f\{i} \{m.func_label(i)}: \{t.skipped}")
            } else {
              match t.refusal {
                Some(d) => {
                  refused = refused + 1
                  s_refused.push("f\{i} \{m.func_label(i)}: \{d.render()}")
                }
                None => {
                  structured = structured + 1
                  nodes = nodes + t.nodes
                  leaves = leaves + t.leaves
                  blocks = blocks + t.blocks
                  total_blocks = total_blocks + t.total_blocks
                  guards = guards + t.guards
                  switches = switches + t.switches
                  if t.depth > max_depth {
                    max_depth = t.depth
                  }
                }
              }
            }
        }
      }
      None => ()
    }
    i = i + 1
  }
  {
    funcs,
    structured,
    skipped,
    refused,
    nodes,
    leaves,
    blocks,
    total_blocks,
    guards,
    switches,
    max_depth,
    s_skipped,
    s_refused,
  }
}

///|
pub fn StructStats::render(self : StructStats) -> String {
  let b = StringBuilder()
  b.write_string("structured      \{self.structured} of \{self.funcs} bodies\n")
  b.write_string("nodes           \{self.nodes}\n")
  b.write_string("blocks emitted  \{self.blocks} of \{self.total_blocks}\n")
  b.write_string("guards          \{self.guards}\n")
  b.write_string("switches        \{self.switches}\n")
  b.write_string("max depth       \{self.max_depth}\n")
  b.write_string("skipped         \{self.skipped}\n")
  b.write_string("refused         \{self.refused}\n")
  for s in self.s_skipped {
    b.write_string("  \{s}\n")
  }
  for s in self.s_refused {
    b.write_string("  \{s}\n")
  }
  b.to_string()
}

///|
/// Pseudo-code for every function of a module.
pub fn tree_text(m : Module, path : String) -> String {
  let b = StringBuilder()
  b.write_string(
    ";; structured control flow of \{path} (\{m.func_count()} functions)\n",
  )
  b.write_string(
    ";; `brk` is the construct a pending branch is leaving; -1 means none.\n",
  )
  let mut i = 0
  while i < m.func_count() {
    match m.code_of(i) {
      Some(_) =>
        match structure_func(m, i) {
          Err(d) => b.write_string("\nfunc \{i}: rejected — \{d.render()}\n")
          Ok(t) => b.write_string(t.render(m))
        }
      None => ()
    }
    i = i + 1
  }
  b.to_string()
}

///|
/// `tree_text` in the shape the CLI's other views use, so a failure to read the
/// code section and a failure to structure it are reported the same way.
pub fn tree_text_result(m : Module, path : String) -> DecodeResult[String] {
  Ok(tree_text(m, path))
}

///|
pub fn struct_summary_text(m : Module) -> DecodeResult[String] {
  Ok(struct_stats(m).render())
}
