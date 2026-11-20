///|
/// Control-flow analysis: structured wasm control flow → basic blocks →
/// dominators → natural loops → reducibility.
///
/// Four things are established here, and each one is consumed by a later stage:
///
/// 1. **Basic blocks.** A flat list of straight-line runs over *real*
///    instructions. `end` and `else` are structural: they close a range, so they
///    are not blocks of their own and never appear in one.
/// 2. **Dominators.** `dom[b]` is a boolean row over the blocks that lie on
///    every path from the entry to `b`, plus the immediate dominator — the
///    parent pointer of the dominator tree.
/// 3. **Natural loops.** An edge whose target dominates its source is a back
///    edge; the loop it closes is the set of blocks that reach the source
///    without passing through the target.
/// 4. **Reducibility.** A flow graph is reducible when every retreating edge of
///    a DFS spanning tree is a back edge (Hecht–Ullman). Irreducible graphs need
///    the Relooper's dispatcher; reducible ones do not, and can be emitted as
///    nested `if` / `while`.
///
/// Why bother, when wasm control flow is already structured? The *nesting* is a
/// tree, but the graph is not: `br 2` leaves two regions at once, an `if` has
/// two entries, and `loop` is the only backward edge the format can express.
/// Whether a join point needs a flag, whether a region is a `while` or a
/// `loop`+`break`, and where that `break` sits are all questions about the flat
/// graph, not about the nesting tree.
///
/// One deliberate asymmetry: the graph is built from a **complete** body only.
/// A body whose decode stopped at a SIMD opcode has unbalanced brackets, and a
/// "best effort" CFG of half a function would be worse than no CFG at all —
/// `cfg_of_body` returns `None` and the caller reports why.

// --- constructs -----------------------------------------------------------
//
// A construct is a `block`, a `loop`, or an `if`, measured in **real
// instruction indices**: `open` is the first instruction inside, `close` the
// first one after, so the range is half-open and an empty construct has
// `open == close`. For an `if` the `if` instruction itself is real — it has two
// successors — and sits at `open - 1`.

// --- layout ---------------------------------------------------------------
//
// Private working form: parallel arrays, built once and never mutated. The
// public `Cfg` is materialised afterwards, so a reader of `Cfg` never has to
// wonder whether a field is final yet.

///|
/// The instruction stream with `end` / `else` removed, plus the bracket
/// structure resolved into ranges.
priv struct Layout {
  ops : Array[InstrRef]
  /// Per construct: 0 block, 1 loop, 2 if. Index 0 is the function body.
  kind : Array[Int32]
  /// Per construct: its block type, so a consumer can ask what a branch to it
  /// must supply without reopening the instruction stream. Index 0 is `Empty`
  /// and is never consulted — a branch to the function body returns, and its
  /// types come from the signature rather than from here.
  btype : Array[BlockType]
  open : Array[Int32]
  close : Array[Int32]
  else_at : Array[Int32]
  parent : Array[Int32]
  /// Per instruction: innermost construct containing it.
  owner : Array[Int32]
  /// Per instruction: the construct opened by this instruction, when it is an
  /// `if`; -1 otherwise.
  opened : Array[Int32]
  /// Per instruction: where a fall-through goes when it is *not* `at + 1`,
  /// which happens exactly when the instruction ends a then-arm.
  escape : Array[Int32]
  /// Per position: where control really lands after a construct ends here.
  /// Equal to the position itself except where an `else` arm starts, in which
  /// case it is the end of the enclosing `if` — see the note in pass C.
  resolve : Array[Int32]
  total : Int32
}

///|
/// Resolve `br depth` at instruction `at` to a target instruction index.
///
/// The innermost label is depth 0, which is why the walk starts at `owner[at]`
/// itself: the enclosing construct *is* the innermost label. A branch to a
/// `loop` re-enters it (target `open`); a branch to a `block` or `if` leaves it
/// (target `close`). That single asymmetry is the whole of wasm's loop
/// construct.
fn Layout::target_of(self : Layout, at : Int32, depth : Int32) -> Int32 {
  let mut c = self.owner[at]
  let mut d = depth
  while d > 0 {
    let p = self.parent[c]
    // A depth past the function's own label is rejected by the decoder; if one
    // arrives anyway, resolving to the function exit is the safe reading.
    if p < 0 {
      break
    }
    c = p
    d = d - 1
  }
  if d > 0 {
    return self.close[0]
  }
  if self.kind[c] == 1 {
    self.open[c]
  } else {
    // Leaving `c` can land on an `else` of an enclosing `if`, which is not
    // where a completed construct continues.
    self.resolve[self.close[c]]
  }
}

///|
/// Where control goes after instruction `at` falls out of its block.
///
/// Usually `at + 1`. The exception is the last instruction of a then-arm: the
/// `else` keyword is not an instruction, so the next real instruction is the
/// first of the *other* arm, which is not where a fall-through goes. The
/// `escape` table records those few positions, and nothing else has to know
/// that `else` exists.
fn Layout::fallthrough(self : Layout, at : Int32) -> Int32 {
  let e = self.escape[at]
  if e >= 0 {
    e
  } else {
    at + 1
  }
}

///|
/// Split a validated body into a `Layout`, or `None` when the bracket structure
/// is unbalanced.
///
/// Three passes, each with one job:
///
/// - **A** matches `block`/`loop`/`if` with their `end` and records where each
///   `else` sits. This is the only pass that can fail, and it fails by returning
///   `None` rather than by guessing — a half-closed bracket tree has no correct
///   interpretation.
/// - **B** assigns each real instruction its index and its enclosing construct.
/// - **C** turns opener positions into ranges and installs the fall-through
///   escapes.
///
/// Splitting them keeps every pass a single loop over the instruction array,
/// which is the version of this algorithm that can be read and checked.
fn build_layout(instrs : Array[InstrRef]) -> Layout? {
  let n = instrs.length()
  // --- A: brackets ---
  let end_of = Array::make(n, -1)
  let else_of = Array::make(n, -1)
  let parent_op = Array::make(n, -1)
  let openers : Array[Int32] = []
  let stack : Array[Int32] = []
  let mut i = 0
  while i < n {
    match instrs[i].instr {
      Block(_) | Loop(_) | If(_) => {
        parent_op[i] = if stack.length() == 0 {
          -1
        } else {
          stack[stack.length() - 1]
        }
        stack.push(i)
        openers.push(i)
      }
      Else => {
        if stack.length() == 0 {
          return None
        }
        let o = stack[stack.length() - 1]
        match instrs[o].instr {
          If(_) => else_of[o] = i
          // An `else` under a `block` or `loop` cannot be given a meaning.
          _ => return None
        }
      }
      End =>
        if stack.length() == 0 {
          // The body's own terminating `end` is *not* in this list: the decoder
          // treats it as the end of the byte range rather than as an
          // instruction. So an `end` with nothing open is a stray token, not the
          // function's exit, and the stream is not a body.
          return None
        } else {
          end_of[stack[stack.length() - 1]] = i
          let _ = stack.pop()
        }
      _ => ()
    }
    i = i + 1
  }
  if stack.length() != 0 {
    return None
  }
  // --- B: real instruction indices ---
  let real_of = Array::make(n, 0)
  let ops : Array[InstrRef] = []
  let op_owner : Array[Int32] = []
  let stack2 : Array[Int32] = []
  i = 0
  while i < n {
    // The number of real instructions before `i`; for a real instruction this
    // is its own index.
    real_of[i] = ops.length()
    match instrs[i].instr {
      Block(_) | Loop(_) => stack2.push(i)
      If(_) => {
        // `if` is a real instruction with two successors, and it belongs to the
        // *enclosing* construct: pushing it onto the label stack first would
        // make `br 0` at the `if` itself resolve to itself.
        ops.push(instrs[i])
        op_owner.push(top_or_body(stack2))
        stack2.push(i)
      }
      End => if stack2.length() > 0 { let _ = stack2.pop() }
      Else => ()
      _ => {
        ops.push(instrs[i])
        op_owner.push(top_or_body(stack2))
      }
    }
    i = i + 1
  }
  // --- C: ranges ---
  let ckind : Array[Int32] = [0]
  let cbtype : Array[BlockType] = [Empty]
  let copen : Array[Int32] = [0]
  let cclose : Array[Int32] = [ops.length()]
  let celse : Array[Int32] = [-1]
  let cparent : Array[Int32] = [-1]
  let cid_of = Array::make(n, -1)
  for o in openers {
    let k = match instrs[o].instr {
      Loop(_) => 1
      If(_) => 2
      _ => 0
    }
    let pa = parent_op[o]
    cid_of[o] = ckind.length()
    ckind.push(k)
    cbtype.push(
      match instrs[o].instr {
        Block(t) | Loop(t) | If(t) => t
        _ => Empty
      },
    )
    // An `if` occupies a real instruction slot, so its body starts one later.
    copen.push(if k == 2 { real_of[o] + 1 } else { real_of[o] })
    cclose.push(real_of[end_of[o]])
    celse.push(if else_of[o] >= 0 { real_of[else_of[o]] } else { -1 })
    cparent.push(if pa < 0 { 0 } else { cid_of[pa] })
  }
  let owner : Array[Int32] = []
  let mut k = 0
  while k < ops.length() {
    let oo = op_owner[k]
    owner.push(if oo < 0 { 0 } else { cid_of[oo] })
    k = k + 1
  }
  let opened = Array::make(ops.length(), -1)
  let escape = Array::make(ops.length(), -1)
  // Positions that start an `else` arm, and the resolution of "I just finished
  // a construct here" past them.
  //
  // A real instruction can be *both* the first instruction of an `else` arm and
  // the position control reaches after a construct ends — `end if2` immediately
  // followed by `else if1` puts both at the same index. Arriving there from the
  // then-arm does not enter the arm: it skips to the end of the enclosing `if`.
  // Without this table the two readings collapse into one block, which then has
  // two predecessors carrying different stacks — a real module
  // (`_M0FPB12dec__count32`) fails type-checking because of it.
  let else_pos = Array::make(ops.length() + 1, -1)
  let mut q = 1
  while q < ckind.length() {
    let e = celse[q]
    if e >= 0 && e <= ops.length() {
      else_pos[e] = q
    }
    q = q + 1
  }
  let resolve = Array::make(ops.length() + 1, -1)
  let mut p = 0
  while p <= ops.length() {
    let mut t = p
    let mut steps = 0
    // `close[k] > else_at[k]` always, so the chain strictly increases and
    // cannot cycle; the counter is there to keep a corrupted layout from
    // looping forever rather than to bound a legitimate case.
    while else_pos[t] >= 0 && steps <= ckind.length() {
      t = cclose[else_pos[t]]
      steps = steps + 1
      if t > ops.length() {
        break
      }
    }
    resolve[p] = t
    p = p + 1
  }
  let mut c = 1
  while c < ckind.length() {
    if ckind[c] == 2 {
      // The `if` instruction sits immediately before its then-arm.
      opened[copen[c] - 1] = c
    }
    let e = celse[c]
    if e >= 1 {
      escape[e - 1] = resolve[cclose[c]]
    }
    c = c + 1
  }
  Some({
    ops,
    kind: ckind,
    btype: cbtype,
    open: copen,
    close: cclose,
    else_at: celse,
    parent: cparent,
    owner,
    opened,
    escape,
    resolve,
    total: ops.length(),
  })
}

///|
/// Innermost construct currently open, as an opener instruction index; -1 when
/// only the function body is open.
fn top_or_body(stack : Array[Int32]) -> Int32 {
  if stack.length() == 0 {
    -1
  } else {
    stack[stack.length() - 1]
  }
}

// --- graph analysis -------------------------------------------------------
//
// Everything below operates on `(nb, succ)` alone, with no knowledge of wasm.
// That separation is what makes the hard part testable: the irreducible case
// cannot be produced by structured wasm (`br` only targets enclosing labels, so
// every CFG the format can express is reducible), yet the analysis has to
// handle it, and a unit test feeds it a hand-written graph instead of pretending
// a fixture could.

///|
/// The result of analysing one successor matrix.
priv struct Graph {
  pred : Array[Array[Int32]]
  reachable : Array[Bool]
  /// Immediate dominator, -1 for the entry and for unreachable blocks.
  idom : Array[Int32]
  /// Natural loops, one per header, sorted by header.
  header : Array[Int32]
  nodes : Array[Array[Int32]]
  tails : Array[Array[Int32]]
  reducible : Bool
  /// The edges that make the graph irreducible, as parallel arrays.
  bad_from : Array[Int32]
  bad_to : Array[Int32]
}

///|
/// Analyse a graph given only its successor lists.
///
/// Precondition: node 0 is the entry; every index in `succ` is in `0..<nb`.
fn analyze_graph(nb : Int32, succ : Array[Array[Int32]]) -> Graph {
  let pred : Array[Array[Int32]] = []
  let mut i = 0
  while i < nb {
    pred.push([])
    i = i + 1
  }
  i = 0
  while i < nb {
    for v in succ[i] {
      pred[v].push(i)
    }
    i = i + 1
  }
  // --- depth-first spanning tree, iteratively ---
  //
  // Iterative because a wasm function can nest thousands of blocks deep, and a
  // recursive DFS would be a stack-depth limit disguised as a correctness bug.
  // `cursor[u]` is how far into `succ[u]` node `u` has been explored; a node is
  // finished (post-visited) exactly when its cursor reaches the end.
  let seen = Array::make(nb, false)
  let par = Array::make(nb, -1)
  let cursor = Array::make(nb, 0)
  let post : Array[Int32] = []
  let stack : Array[Int32] = []
  if nb > 0 {
    seen[0] = true
    stack.push(0)
    while stack.length() > 0 {
      let u = stack[stack.length() - 1]
      if cursor[u] < succ[u].length() {
        let v = succ[u][cursor[u]]
        cursor[u] = cursor[u] + 1
        if !seen[v] {
          seen[v] = true
          par[v] = u
          stack.push(v)
        }
      } else {
        let _ = stack.pop()
        post.push(u)
      }
    }
  }
  let reachable = Array::make(nb, false)
  i = 0
  while i < nb {
    reachable[i] = seen[i]
    i = i + 1
  }
  // Reverse postorder: the order in which the dominator fixpoint converges in a
  // single sweep for a reducible graph, and in few sweeps otherwise.
  let rpo : Array[Int32] = []
  i = post.length() - 1
  while i >= 0 {
    rpo.push(post[i])
    i = i - 1
  }
  // --- dominators ---
  let dom : Array[Array[Bool]] = []
  i = 0
  while i < nb {
    if !reachable[i] {
      dom.push(Array::make(0, false))
    } else {
      let d = Array::make(nb, false)
      if i == 0 {
        d[0] = true
      } else {
        let mut k = 0
        while k < nb {
          d[k] = reachable[k]
          k = k + 1
        }
      }
      dom.push(d)
    }
    i = i + 1
  }
  let mut changed = nb > 0
  let mut rounds = 0
  while changed && rounds < nb + 2 {
    changed = false
    let mut ri = 0
    while ri < rpo.length() {
      let b = rpo[ri]
      if b != 0 {
        let acc = Array::make(nb, false)
        let mut k = 0
        while k < nb {
          acc[k] = reachable[k]
          k = k + 1
        }
        let mut any = false
        for p in pred[b] {
          if reachable[p] {
            any = true
            let dp = dom[p]
            let mut j = 0
            while j < nb {
              if !dp[j] {
                acc[j] = false
              }
              j = j + 1
            }
          }
        }
        // A reachable node other than the entry always has a reachable
        // predecessor, so `any` is always true here; the guard is for graphs
        // handed in by a test that do not satisfy that.
        if any {
          acc[b] = true
          let old = dom[b]
          let mut diff = false
          let mut j = 0
          while j < nb {
            if old[j] != acc[j] {
              diff = true
            }
            j = j + 1
          }
          if diff {
            dom[b] = acc
            changed = true
          }
        }
      }
      ri = ri + 1
    }
    rounds = rounds + 1
  }
  // --- immediate dominators ---
  //
  // The dominators of a node form a chain, so the immediate dominator is the
  // unique node in that set (other than the node itself) whose own dominator set
  // is exactly one element smaller. Comparing set sizes finds it in O(nb).
  let domsize = Array::make(nb, 0)
  i = 0
  while i < nb {
    if reachable[i] {
      let mut s = 0
      let mut k = 0
      while k < nb {
        if dom[i][k] {
          s = s + 1
        }
        k = k + 1
      }
      domsize[i] = s
    }
    i = i + 1
  }
  let idom = Array::make(nb, -1)
  i = 1
  while i < nb {
    if reachable[i] {
      let want = domsize[i] - 1
      let mut k = 0
      while k < nb {
        if k != i && dom[i][k] && domsize[k] == want {
          idom[i] = k
        }
        k = k + 1
      }
    }
    i = i + 1
  }
  // --- natural loops ---
  //
  // A back edge is an edge whose target dominates its source — that is the
  // definition, not a heuristic, and it is why the dominator matrix is computed
  // before any loop work. Two back edges with the same header describe one loop,
  // so the node sets are merged; multiple tails are normal in a switch that
  // continues.
  let header : Array[Int32] = []
  let nodes : Array[Array[Int32]] = []
  let tails : Array[Array[Int32]] = []
  let slot_of = Array::make(nb, -1)
  i = 0
  while i < nb {
    if reachable[i] {
      for v in succ[i] {
        if reachable[v] && dom[i][v] {
          let mut slot = slot_of[v]
          if slot < 0 {
            slot = header.length()
            slot_of[v] = slot
            header.push(v)
            nodes.push([v])
            tails.push([])
          }
          tails[slot].push(i)
          expand_loop(nodes[slot], i, pred, nb)
        }
      }
    }
    i = i + 1
  }
  i = 0
  while i < nodes.length() {
    sort_ints(nodes[i])
    sort_ints(tails[i])
    i = i + 1
  }
  sort_loops(header, nodes, tails)
  // --- reducibility ---
  //
  // Hecht–Ullman: the graph is reducible iff every retreating edge of the DFS
  // tree is a back edge. A retreating edge that is *not* a back edge means two
  // paths into a cycle, which is exactly the shape structured control flow
  // cannot express — and the shape the Relooper's dispatcher exists for.
  let bad_from : Array[Int32] = []
  let bad_to : Array[Int32] = []
  i = 0
  while i < nb {
    if reachable[i] {
      for v in succ[i] {
        if reachable[v] && is_ancestor(par, i, v) && !dom[i][v] {
          bad_from.push(i)
          bad_to.push(v)
        }
      }
    }
    i = i + 1
  }
  {
    pred,
    reachable,
    idom,
    header,
    nodes,
    tails,
    reducible: bad_from.length() == 0,
    bad_from,
    bad_to,
  }
}

///|
/// Grow a natural loop to its full node set: everything that reaches `tail`
/// without passing through the header (the header is already a member).
fn expand_loop(
  nodes : Array[Int32],
  tail : Int32,
  pred : Array[Array[Int32]],
  nb : Int32,
) -> Unit {
  let inloop = Array::make(nb, false)
  for x in nodes {
    inloop[x] = true
  }
  let work : Array[Int32] = []
  work.push(tail)
  while work.length() > 0 {
    let x = work[work.length() - 1]
    let _ = work.pop()
    if !inloop[x] {
      inloop[x] = true
      nodes.push(x)
      for p in pred[x] {
        work.push(p)
      }
    }
  }
}

///|
/// True when `v` is `u` or an ancestor of `u` in the DFS tree.
fn is_ancestor(par : Array[Int32], u : Int32, v : Int32) -> Bool {
  let mut x = u
  let mut steps = 0
  while x >= 0 && steps <= par.length() {
    if x == v {
      return true
    }
    x = par[x]
    steps = steps + 1
  }
  false
}

///|
/// Ascending insertion sort. Loops and their node sets are small (a function
/// rarely has more than a handful), and a stable, allocation-free sort keeps the
/// output byte-identical across backends — which `check.sh` compares.
fn sort_ints(xs : Array[Int32]) -> Unit {
  let mut i = 1
  while i < xs.length() {
    let v = xs[i]
    let mut j = i
    while j > 0 && xs[j - 1] > v {
      xs[j] = xs[j - 1]
      j = j - 1
    }
    xs[j] = v
    i = i + 1
  }
}

///|
/// Sort loops by header so that `L0`, `L1`, … in the output name the same loop
/// on every run and on every backend.
fn sort_loops(
  header : Array[Int32],
  nodes : Array[Array[Int32]],
  tails : Array[Array[Int32]],
) -> Unit {
  let mut i = 1
  while i < header.length() {
    let h = header[i]
    let ns = nodes[i]
    let ts = tails[i]
    let mut j = i
    while j > 0 && header[j - 1] > h {
      header[j] = header[j - 1]
      nodes[j] = nodes[j - 1]
      tails[j] = tails[j - 1]
      j = j - 1
    }
    header[j] = h
    nodes[j] = ns
    tails[j] = ts
    i = i + 1
  }
}

// --- the public graph -----------------------------------------------------

///|
/// One basic block: a half-open range of real instruction indices.
pub struct Block {
  first : Int32
  end : Int32
  /// Successor blocks. `Cfg::exit` stands for "leaves the function".
  succ : Array[Int32]
  pred : Array[Int32]
  /// False for blocks that only a dead branch can reach, e.g. the code after
  /// an unconditional `br`.
  reachable : Bool
  /// Immediate dominator, -1 for the entry and for unreachable blocks.
  idom : Int32
}

///|
/// A natural loop: one header, its body, and the back edges that close it.
pub struct Loop {
  header : Int32
  /// Sorted block indices, header included.
  nodes : Array[Int32]
  /// Sorted source blocks of the back edges.
  tails : Array[Int32]
}

///|
/// An edge that makes the graph irreducible.
pub struct IrreducibleEdge {
  from : Int32
  to : Int32
}

///|
/// The control-flow graph of one function.
///
/// `exit` is a virtual block one past the last real one: `return`, a branch to
/// the function's label, and falling off the end all point at it. It has no
/// instructions, so it takes no part in the analysis — but keeping it explicit
/// means "this function can return here" is an edge like any other, instead of a
/// missing successor that each consumer has to special-case.
pub struct Cfg {
  ops : Array[InstrRef]
  blocks : Array[Block]
  entry : Int32
  exit : Int32
  loops : Array[Loop]
  reducible : Bool
  bad_edges : Array[IrreducibleEdge]
}

///|
pub fn Cfg::block_count(self : Cfg) -> Int32 {
  self.blocks.length()
}

///|
pub fn Cfg::edge_count(self : Cfg) -> Int32 {
  let mut n = 0
  for b in self.blocks {
    n = n + b.succ.length()
  }
  n
}

///|
/// True when some block is reachable only through a dead branch. `info` reports
/// it because a decompiled function with dead code is worth looking at by hand.
pub fn Cfg::unreachable_count(self : Cfg) -> Int32 {
  let mut n = 0
  for b in self.blocks {
    if !b.reachable {
      n = n + 1
    }
  }
  n
}

///|
/// Deepest loop nesting, counting containment between natural loops.
pub fn Cfg::max_loop_depth(self : Cfg) -> Int32 {
  let mut best = 0
  let mut i = 0
  while i < self.loops.length() {
    let mut depth = 0
    let mut j = 0
    while j < self.loops.length() {
      // A natural loop whose header lies inside another loop is nested in it.
      // The size comparison excludes a loop from counting itself.
      if i != j &&
        contains_int(self.loops[j].nodes, self.loops[i].header) &&
        self.loops[i].nodes.length() < self.loops[j].nodes.length() {
        depth = depth + 1
      }
      j = j + 1
    }
    if depth > best {
      best = depth
    }
    i = i + 1
  }
  best
}

///|
fn contains_int(xs : Array[Int32], x : Int32) -> Bool {
  let mut found = false
  for y in xs {
    if y == x {
      found = true
    }
  }
  found
}

///|
fn push_uniq(xs : Array[Int32], x : Int32) -> Unit {
  if !contains_int(xs, x) {
    xs.push(x)
  }
}

///|
/// True for instructions that end a basic block: control does not simply
/// continue at the next instruction.
///
/// `if` is included even though it is not a jump: it has two successors, so the
/// instruction after it starts a block that has two predecessors.
fn splits_block(i : Instr) -> Bool {
  match i {
    Unreachable | Br(_) | BrIf(_) | BrTable(_, _) | Return | If(_) => true
    _ => false
  }
}

///|
/// Turn a layout into blocks, edges, and the analysis of those edges.
///
/// Block boundaries are the classic leader set: the first instruction; anything
/// a branch can target; anything after a terminator; every arm start and every
/// construct end. No other instruction can be a leader, which is why a block is
/// a *maximal* run and the block count is a property of the code rather than of
/// this implementation.
fn build_cfg(l : Layout) -> Cfg {
  let n = l.total
  let lead = Array::make(n + 1, false)
  lead[0] = true
  lead[n] = true
  let mut i = 0
  while i < n {
    if splits_block(l.ops[i].instr) {
      lead[i + 1] = true
    }
    i = i + 1
  }
  let mut c = 1
  while c < l.kind.length() {
    lead[l.open[c]] = true
    lead[l.close[c]] = true
    if l.else_at[c] >= 0 {
      lead[l.else_at[c]] = true
    }
    c = c + 1
  }
  i = 0
  while i < n {
    match l.ops[i].instr {
      Br(d) => lead[l.target_of(i, d)] = true
      BrIf(d) => lead[l.target_of(i, d)] = true
      BrTable(ls, d) => {
        for x in ls {
          lead[l.target_of(i, x)] = true
        }
        lead[l.target_of(i, d)] = true
      }
      _ => ()
    }
    i = i + 1
  }
  let first : Array[Int32] = []
  let bend : Array[Int32] = []
  let mut p = 0
  while p < n {
    if lead[p] {
      let mut q = p + 1
      while q < n && !lead[q] {
        q = q + 1
      }
      first.push(p)
      bend.push(q)
      p = q
    } else {
      // Unreachable by construction: blocks start at leaders and end at the
      // next one, so no instruction between them can be skipped.
      p = p + 1
    }
  }
  let nb = first.length()
  let exit = nb
  let block_of = Array::make(n + 1, exit)
  let mut b = 0
  while b < nb {
    let mut k = first[b]
    while k < bend[b] {
      block_of[k] = b
      k = k + 1
    }
    b = b + 1
  }
  let succ : Array[Array[Int32]] = []
  b = 0
  while b < nb {
    let last = bend[b] - 1
    let out : Array[Int32] = []
    match l.ops[last].instr {
      Br(d) => push_uniq(out, block_of[l.target_of(last, d)])
      BrIf(d) => {
        push_uniq(out, block_of[l.target_of(last, d)])
        push_uniq(out, block_of[l.fallthrough(last)])
      }
      BrTable(ls, d) => {
        for x in ls {
          push_uniq(out, block_of[l.target_of(last, x)])
        }
        push_uniq(out, block_of[l.target_of(last, d)])
      }
      Return => push_uniq(out, exit)
      // A trap: the block ends here and nothing is reachable through it.
      Unreachable => ()
      If(_) => {
        let ci = l.opened[last]
        push_uniq(out, block_of[l.open[ci]])
        let alt = if l.else_at[ci] >= 0 { l.else_at[ci] } else { l.close[ci] }
        push_uniq(out, block_of[alt])
      }
      _ => push_uniq(out, block_of[l.fallthrough(last)])
    }
    succ.push(out)
    b = b + 1
  }
  // The exit block has no instructions and no successors, so it contributes
  // nothing to dominators or loops; dropping it from the analysis keeps every
  // index inside `0..<nb`.
  let gsucc : Array[Array[Int32]] = []
  b = 0
  while b < nb {
    let out : Array[Int32] = []
    for x in succ[b] {
      if x != exit {
        out.push(x)
      }
    }
    gsucc.push(out)
    b = b + 1
  }
  let g = analyze_graph(nb, gsucc)
  let blocks : Array[Block] = []
  b = 0
  while b < nb {
    blocks.push({
      first: first[b],
      end: bend[b],
      succ: succ[b],
      pred: g.pred[b],
      reachable: g.reachable[b],
      idom: g.idom[b],
    })
    b = b + 1
  }
  let loops : Array[Loop] = []
  let mut li = 0
  while li < g.header.length() {
    loops.push({ header: g.header[li], nodes: g.nodes[li], tails: g.tails[li], })
    li = li + 1
  }
  let bad : Array[IrreducibleEdge] = []
  li = 0
  while li < g.bad_from.length() {
    bad.push({ from: g.bad_from[li], to: g.bad_to[li], })
    li = li + 1
  }
  {
    ops: l.ops,
    blocks,
    entry: 0,
    exit,
    loops,
    reducible: g.reducible,
    bad_edges: bad,
  }
}

///|
/// Build the CFG of a decoded body, or `None` when the body cannot support one:
/// either its decode stopped early (SIMD/atomics), or its brackets do not
/// balance.
pub fn cfg_of_body(body : DecodedBody) -> Cfg? {
  if !body.is_complete() {
    return None
  }
  match build_layout(body.instrs) {
    None => None
    Some(l) => Some(build_cfg(l))
  }
}

///|
/// Build the CFG of one defined function.
pub fn cfg_of_func(m : Module, idx : Int32) -> Cfg? raise ReadFail {
  cfg_of_body(decode_func(m, idx))
}

// --- rendering ------------------------------------------------------------

///|
/// `b3`, or `exit` for the virtual block.
fn block_name(id : Int32, exit : Int32) -> String {
  if id == exit {
    "exit"
  } else {
    "b\{id}"
  }
}

///|
fn render_ids(xs : Array[Int32], exit : Int32) -> String {
  if xs.length() == 0 {
    return "-"
  }
  let b = StringBuilder()
  let mut i = 0
  for x in xs {
    if i > 0 {
      b.write_string(" ")
    }
    b.write_string(block_name(x, exit))
    i = i + 1
  }
  b.to_string()
}

///|
fn render_nodes(xs : Array[Int32]) -> String {
  if xs.length() == 0 {
    return "-"
  }
  let b = StringBuilder()
  let mut i = 0
  for x in xs {
    if i > 0 {
      b.write_string(" ")
    }
    b.write_string("b\{x}")
    i = i + 1
  }
  b.to_string()
}

///|
/// One function's graph, in a format that diffs well: every line is either a
/// block, the dominator tree, a loop, or an irreducible edge, and nothing is
/// printed that the numbers do not already imply.
pub fn Cfg::render(self : Cfg) -> String {
  let b = StringBuilder()
  b.write_string(
    "  blocks \{self.blocks.length()}  edges \{self.edge_count()}  loops \{self.loops.length()}  reducible ",
  )
  b.write_string(if self.reducible { "yes" } else { "no" })
  b.write_string("\n")
  if self.blocks.length() == 0 {
    // An empty body: `func ... end`. No blocks, nothing to say, and saying it
    // is better than an empty section that looks like a missing feature.
    return b.to_string()
  }
  let mut i = 0
  while i < self.blocks.length() {
    let blk = self.blocks[i]
    let span = "\{blk.first}..\{blk.end}"
    b.write_string(
      "  \{pad_right("b\{i}", 4)} ops \{pad_right(span, 10)} succ ",
    )
    b.write_string(render_ids(blk.succ, self.exit))
    if !blk.reachable {
      b.write_string("  (unreachable)")
    }
    b.write_string("\n")
    i = i + 1
  }
  let tree = StringBuilder()
  let mut shown = 0
  i = 1
  while i < self.blocks.length() {
    let blk = self.blocks[i]
    if blk.reachable && blk.idom >= 0 {
      if shown > 0 {
        tree.write_string("  ")
      }
      tree.write_string("b\{i}<-b\{blk.idom}")
      shown = shown + 1
    }
    i = i + 1
  }
  if shown > 0 {
    b.write_string("  idom \{tree.to_string()}\n")
  }
  i = 0
  while i < self.loops.length() {
    let lp = self.loops[i]
    b.write_string(
      "  loop L\{i} header b\{lp.header}  nodes \{render_nodes(lp.nodes)}",
    )
    b.write_string("  tails \{render_nodes(lp.tails)}\n")
    i = i + 1
  }
  for e in self.bad_edges {
    b.write_string(
      "  irreducible edge b\{e.from}->b\{e.to}: b\{e.to} does not dominate b\{e.from}\n",
    )
  }
  b.to_string()
}

///|
/// Structural summary of every function in the module.
pub struct CfgStats {
  bodies : Int32
  /// Bodies that could not be analysed: partial decode or unbalanced brackets.
  skipped : Int32
  blocks : Int32
  edges : Int32
  loops : Int32
  max_loop_depth : Int32
  reducible : Int32
  irreducible : Int32
  /// One line per irreducible function, so the count is never a mystery.
  notes : Array[String]
}

///|
pub fn cfg_stats(m : Module) -> CfgStats raise ReadFail {
  let mut bodies = 0
  let mut skipped = 0
  let mut blocks = 0
  let mut edges = 0
  let mut loops = 0
  let mut depth = 0
  let mut reducible = 0
  let mut irreducible = 0
  let notes : Array[String] = []
  let mut idx = 0
  while idx < m.func_count() {
    if idx >= m.imported_func_count() {
      bodies = bodies + 1
      match cfg_of_func(m, idx) {
        None => skipped = skipped + 1
        Some(c) => {
          blocks = blocks + c.block_count()
          edges = edges + c.edge_count()
          loops = loops + c.loops.length()
          let d = c.max_loop_depth()
          if d > depth {
            depth = d
          }
          if c.reducible {
            reducible = reducible + 1
          } else {
            irreducible = irreducible + 1
            notes.push(
              "  f\{idx} \{m.func_label(idx)}: \{c.bad_edges.length()} irreducible edge(s)",
            )
          }
        }
      }
    }
    idx = idx + 1
  }
  {
    bodies,
    skipped,
    blocks,
    edges,
    loops,
    max_loop_depth: depth,
    reducible,
    irreducible,
    notes,
  }
}

///|
/// One aligned `label  value` line, matching the column layout of
/// `disasm --stats`.
fn stat_line(label : String, value : String) -> String {
  pad_right(label, 16) + value + "\n"
}

///|
/// The CFG section of `disasm --stats`.
pub fn cfg_summary_text(m : Module) -> String raise ReadFail {
  let s = cfg_stats(m)
  let b = StringBuilder()
  b.write_string(stat_line("blocks", "\{s.blocks}"))
  b.write_string(stat_line("edges", "\{s.edges}"))
  b.write_string(stat_line("loops", "\{s.loops}"))
  b.write_string(stat_line("loop depth", "\{s.max_loop_depth}"))
  b.write_string(stat_line("reducible", "\{s.reducible} of \{s.bodies} bodies"))
  b.write_string(stat_line("irreducible", "\{s.irreducible}"))
  if s.skipped > 0 {
    b.write_string(stat_line("skipped", "\{s.skipped}"))
  }
  for n in s.notes {
    b.write_string("\{n}\n")
  }
  b.to_string()
}

///|
/// Full CFG listing: every function, in index order.
pub fn cfg_text(m : Module, path : String) -> String raise ReadFail {
  let b = StringBuilder()
  b.write_string(";; moonlift cfg — \{path}\n")
  b.write_string(
    ";; blocks are ranges of real instructions; 'end' and 'else' close a range and are never a block\n",
  )
  let mut idx = 0
  while idx < m.func_count() {
    if idx >= m.imported_func_count() {
      let body = decode_func(m, idx)
      b.write_string(
        "\nfunc \{idx} \{m.func_label(idx)}\{render_signature(m.func_type(idx))}\n",
      )
      match cfg_of_body(body) {
        Some(c) => b.write_string(c.render())
        None => {
          let why = if body.is_complete() {
            "brackets do not balance"
          } else {
            body.stop_note()
          }
          b.write_string("  skipped: \{why}\n")
        }
      }
    }
    idx = idx + 1
  }
  b.to_string()
}

// --- Result-returning wrappers --------------------------------------------

///|
pub fn cfg_text_result(m : Module, path : String) -> DecodeResult[String] {
  attempt(() => cfg_text(m, path))
}

///|
pub fn cfg_summary_result(m : Module) -> DecodeResult[String] {
  attempt(() => cfg_summary_text(m))
}
