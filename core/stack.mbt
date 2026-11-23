///|
/// Typed stack simulation: from decoded instructions to expressions.
///
/// Everything before this stage treats the operand stack as an opaque thing that
/// happens to have a height. This stage gives it *types*, which buys two
/// things that the previous stages could not provide:
///
/// 1. **Validation.** `i32.add` on two `f32` operands decodes fine (S3 checks
///    structure, not types) but is caught here, with the byte offset of the
///    offending instruction. This closes the gap `BOUNDARY.md` §4.10 recorded.
/// 2. **Expression recovery.** `local.get 0; local.get 1; i32.add; local.set 2`
///    becomes one statement `local 2 = i32.add(local 0, local 1)` instead of
///    four. That is what makes the output look like source rather than like a
///    disassembly.
///
/// ## The one thing that is easy to get wrong
///
/// Deferring an expression to the point where it is *consumed* reorders it past
/// every instruction in between. Two of those reorderings change the meaning of
/// the program, and both are real, not hypothetical:
///
/// - A pending `local.get 0` is read *later*, so an intervening `local.set 0`
///   changes the value that gets read. (`local.get 0; ...; local.set 0; ...`)
/// - A pending `i32.load` is read *later*, so an intervening `i32.store` to the
///   same address changes the value that gets read.
///
/// Both are handled by spilling the affected pending value into a temporary
/// *before* the instruction that would clobber it. Those spills are counted
/// separately from the ones that are merely forced by evaluation order (a call
/// result, which must not be moved at all), because the hazard ones are exactly
/// the places where a naive expression-tree decompiler would emit wrong code.
///
/// A third reordering is *not* allowed to happen at all: a call executes where
/// it appears, so its result is materialised immediately rather than carried on
/// the stack. This costs a temporary per call site and keeps every other
/// position in the block free to be an expression.

// --- expressions ----------------------------------------------------------

///|
/// A value-producing expression.
///
/// `EParam` is how a value that arrives from a predecessor is represented: the
/// i-th slot of the block's entry stack. Naming it as a parameter rather than
/// trying to inline the predecessor's expression is what keeps a block's
/// analysis local — and it is also literally what the value is, once the
/// structurer turns the graph back into structured code.
pub enum Expr {
  EConst(ConstVal)
  ELocal(Int32)
  EGlobal(Int32)
  ETemp(Int32)
  EParam(Int32)
  ELoad(MemOp, Expr)
  EBin(ValType, BinKind, Expr, Expr)
  EUn(ValType, UnKind, Expr)
  EConv(ValType, ValType, ConvMode, Expr)
  ECall(Int32, Array[Expr])
  /// A call through the module's function table: the type index the
  /// instruction names, the index expression popped off the stack, and the
  /// arguments. Kept apart from `ECall` because the callee is a *value* here,
  /// so code generation has to route it through a dispatcher instead of naming
  /// a function.
  ECallIndirect(Int32, Expr, Array[Expr])
  /// then-value, else-value, condition.
  ESelect(Expr, Expr, Expr)
  EMemorySize
  EMemoryGrow(Expr)
}

///|
/// True when the expression reads local `i` anywhere inside it.
///
/// Recursive on purpose: a pending `i32.load(local 0)` is invalidated by
/// `local.set 0` just as surely as a pending `local 0` is, because the *address*
/// is what gets recomputed later.
fn expr_mentions(e : Expr, l : Int32, g : Int32) -> Bool {
  match e {
    EConst(_) | ETemp(_) | EParam(_) | EMemorySize => false
    ELocal(j) => j == l
    EGlobal(k) => k == g
    ELoad(_, a) => expr_mentions(a, l, g)
    EBin(_, _, a, b) => expr_mentions(a, l, g) || expr_mentions(b, l, g)
    EUn(_, _, a) => expr_mentions(a, l, g)
    EConv(_, _, _, a) => expr_mentions(a, l, g)
    ECall(_, args) => args_mention(args, l, g)
    ECallIndirect(_, i, args) =>
      expr_mentions(i, l, g) || args_mention(args, l, g)
    ESelect(a, b, c) =>
      expr_mentions(a, l, g) || expr_mentions(b, l, g) || expr_mentions(c, l, g)
    EMemoryGrow(a) => expr_mentions(a, l, g)
  }
}

///|
/// The two reference kinds are searched by one walk with a sentinel in the slot
/// that does not apply: `-1` can never be a real index, so an arm that compares
/// against it is always false.
fn expr_mentions_local(e : Expr, i : Int32) -> Bool {
  expr_mentions(e, i, -1)
}

///|
fn expr_mentions_global(e : Expr, i : Int32) -> Bool {
  expr_mentions(e, -1, i)
}

///|
fn args_mention(xs : Array[Expr], l : Int32, g : Int32) -> Bool {
  let mut found = false
  for x in xs {
    if expr_mentions(x, l, g) {
      found = true
    }
  }
  found
}

///|
fn args_read_any_global(xs : Array[Expr]) -> Bool {
  let mut found = false
  for x in xs {
    if expr_reads_any_global(x) {
      found = true
    }
  }
  found
}

///|
fn args_read_memory(xs : Array[Expr]) -> Bool {
  let mut found = false
  for x in xs {
    if expr_reads_memory(x) {
      found = true
    }
  }
  found
}

///|
/// True when the expression reads any global. Used before a call, which may
/// write any of them.
fn expr_reads_any_global(e : Expr) -> Bool {
  match e {
    EGlobal(_) => true
    EConst(_) | ELocal(_) | ETemp(_) | EParam(_) | EMemorySize => false
    ELoad(_, a) => expr_reads_any_global(a)
    EBin(_, _, a, b) => expr_reads_any_global(a) || expr_reads_any_global(b)
    EUn(_, _, a) => expr_reads_any_global(a)
    EConv(_, _, _, a) => expr_reads_any_global(a)
    ECall(_, args) => {
      let mut found = false
      for x in args {
        if expr_reads_any_global(x) {
          found = true
        }
      }
      found
    }
    ECallIndirect(_, i, args) =>
      expr_reads_any_global(i) || args_read_any_global(args)
    ESelect(a, b, c) =>
      expr_reads_any_global(a) ||
      expr_reads_any_global(b) ||
      expr_reads_any_global(c)
    EMemoryGrow(a) => expr_reads_any_global(a)
  }
}

///|
/// True when the expression reads linear memory.
///
/// Only `ELoad` counts. A `call` cannot appear here — it is materialised into a
/// temporary the moment it is decoded — which is why this predicate is enough to
/// decide whether a pending value is invalidated by a store.
fn expr_reads_memory(e : Expr) -> Bool {
  match e {
    ELoad(_, _) => true
    EConst(_) | ELocal(_) | EGlobal(_) | ETemp(_) | EParam(_) | EMemorySize =>
      false
    EBin(_, _, a, b) => expr_reads_memory(a) || expr_reads_memory(b)
    EUn(_, _, a) => expr_reads_memory(a)
    EConv(_, _, _, a) => expr_reads_memory(a)
    ECall(_, args) => {
      let mut found = false
      for x in args {
        if expr_reads_memory(x) {
          found = true
        }
      }
      found
    }
    ECallIndirect(_, i, args) => expr_reads_memory(i) || args_read_memory(args)
    ESelect(a, b, c) =>
      expr_reads_memory(a) || expr_reads_memory(b) || expr_reads_memory(c)
    EMemoryGrow(a) => expr_reads_memory(a)
  }
}

///|
/// True when evaluating the expression more than once would be observable.
/// Only used by `drop`, which elides a discarded pure expression entirely.
fn expr_has_effect(e : Expr) -> Bool {
  match e {
    ECall(_, _) | ECallIndirect(_, _, _) | EMemoryGrow(_) => true
    EConst(_) | ELocal(_) | EGlobal(_) | ETemp(_) | EParam(_) | EMemorySize =>
      false
    ELoad(_, a) => expr_has_effect(a)
    EBin(_, _, a, b) => expr_has_effect(a) || expr_has_effect(b)
    EUn(_, _, a) => expr_has_effect(a)
    EConv(_, _, _, a) => expr_has_effect(a)
    ESelect(a, b, c) =>
      expr_has_effect(a) || expr_has_effect(b) || expr_has_effect(c)
  }
}

// --- statements -----------------------------------------------------------

///|
/// One recovered statement.
///
/// A block's statement list is *straight-line*: it contains no control flow
/// except the terminator, which is why the terminator is a statement too. The
/// branch targets are block indices in the CFG rather than wasm label depths, so
/// the structurer (S6) can consume these without re-deriving anything.
pub enum Stmt {
  /// `local 3 = e`
  SLocal(Int32, Expr)
  /// `global 1 = e`
  SGlobal(Int32, Expr)
  /// `t4 = e`, a value that had to be materialised.
  STemp(Int32, Expr)
  /// `i32.store offset=4(addr, value)`
  SStore(MemOp, Expr, Expr)
  /// An expression evaluated for its side effect, with its result discarded.
  SEval(Expr)
  /// The block ends by testing `cond` and choosing between its two successors.
  SIf(Expr)
  /// `br 0 (v0)` — depth plus the values transferred to the target.
  SBr(Int32, Array[Expr])
  /// `br_if 0 (v0) if (cond)`
  SBrIf(Int32, Array[Expr], Expr)
  /// `br_table [0 1] default 2 (v0) if (idx)`
  SBrTable(Array[Int32], Int32, Array[Expr], Expr)
  /// `return (v0)`
  SReturn(Array[Expr])
  /// `unreachable`
  SUnreachable
}

// --- the simulation environment -------------------------------------------

///|
/// Everything an instruction needs to know about the module it lives in.
///
/// Built once per function instead of passing `Module` into the simulator: the
/// simulator then has no way to reach a table that is not in here, which makes
/// its dependencies visible in one place — the same reason `BodyCtx` exists for
/// the decoder.
pub struct FuncEnv {
  /// Parameters followed by declared locals, expanded to one entry per index.
  locals : Array[ValType]
  globals : Array[ValType]
  /// This function's result types.
  results : Array[ValType]
  /// Signature of every callable function, in the unified index space.
  funcs : Array[FuncType]
  /// The module's whole type section, because `call_indirect` names a type by
  /// index rather than carrying a signature.
  types : Array[FuncType]
  has_memory : Bool
  has_table : Bool
}

///|
pub fn func_env(m : Module, idx : Int32) -> FuncEnv {
  let locals : Array[ValType] = []
  let results : Array[ValType] = []
  match m.func_type(idx) {
    Some(t) => {
      for p in t.params {
        locals.push(p)
      }
      for r in t.results {
        results.push(r)
      }
    }
    None => ()
  }
  match m.code_of(idx) {
    Some(c) =>
      for d in c.locals {
        let n = d.count.reinterpret_as_int()
        let mut k = 0
        while k < n {
          locals.push(d.ty)
          k = k + 1
        }
      }
    None => ()
  }
  let globals : Array[ValType] = []
  for g in m.globals {
    globals.push(g.ty)
  }
  let funcs : Array[FuncType] = []
  let mut i = 0
  while i < m.func_count() {
    match m.func_type(i) {
      Some(t) => funcs.push(t)
      // The decoder rejected out-of-range indices already; an empty signature
      // here can never be called, so it only has to exist.
      None => funcs.push(FuncType::new([], []))
    }
    i = i + 1
  }
  {
    locals,
    globals,
    results,
    funcs,
    types: m.types,
    has_memory: m.memories.length() > 0,
    has_table: m.tables.length() > 0,
  }
}

///|
/// Type equality, written out because `ValType` has no derived `Eq` in this
/// codebase and comparing by hand keeps the reason visible: two types are equal
/// iff they are the same constructor.
fn ty_eq(a : ValType, b : ValType) -> Bool {
  match (a, b) {
    (I32, I32) => true
    (I64, I64) => true
    (F32, F32) => true
    (F64, F64) => true
    (V128, V128) => true
    _ => false
  }
}

///|
/// True when two stack shapes are identical. Used at join points, where any
/// difference is a validation error rather than something to merge.
fn same_types(a : Array[ValType], b : Array[ValType]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if !ty_eq(a[i], b[i]) {
      return false
    }
    i = i + 1
  }
  true
}

// --- results --------------------------------------------------------------

///|
/// One block, after simulation.
///
/// `entry` and `exit` are stack *shapes*: types only. The values that flow along
/// an edge are named `EParam` inside the successor, and the structurer rewrites
/// them into temps that the edge itself writes — a block that had to care about
/// its predecessor's temporaries would not be a block.
pub struct BlockStack {
  block : Int32
  entry : Array[ValType]
  exit : Array[ValType]
  /// The expressions behind `exit`, in the same order.
  ///
  /// Types alone would not be enough: the values a block passes on *are* the
  /// block's result, and a consumer that only knew their types would have to
  /// re-simulate the block to recover the expressions. Empty when the block does
  /// not fall through, because then there is no next instruction to receive
  /// them.
  exit_exprs : Array[Expr]
  /// True when control continues at the instruction after the block, i.e. the
  /// block's last instruction is not an unconditional transfer.
  falls : Bool
  stmts : Array[Stmt]
  /// The type of each temporary, in index order.
  ///
  /// Recorded rather than re-derived: the simulator knows the type at the moment
  /// it allocates a temp, and the code generator would otherwise have to infer it
  /// back from the expression — which is a type checker written twice, with the
  /// second one untested.
  temp_types : Array[ValType]
  /// Values materialised because a call or a `memory.grow` produced them.
  forced : Int32
  /// Values materialised because deferring them would have changed the result.
  hazard : Int32
  /// True for blocks no live path reaches. Their statement list is empty and
  /// their `note` says why, because silently dropping code is unauditable.
  dead : Bool
}

///|
/// One function, after simulation.
pub struct FuncStack {
  idx : Int32
  blocks : Array[BlockStack]
  /// Number of temporaries allocated, i.e. the size of the generated function's
  /// scratch area.
  temps : Int32
  forced : Int32
  hazard : Int32
  /// Non-empty when the body could not be analysed at all: a partial decode, an
  /// unbalanced bracket structure, or a signature the subset cannot express.
  skipped : String
  /// Set when the body is valid wasm but uses a construct outside the subset.
  /// Distinct from `skipped` because it is a *decision*, and S7 turns it into a
  /// per-function refusal rather than a hard error.
  refusal : Diag?
}

///|
/// A block no live path reaches. Its statement list is empty on purpose: the
/// code there cannot be generated, and inventing statements for it would suggest
/// it can.
fn dead_stack(b : Int32) -> BlockStack {
  {
    block: b,
    entry: [],
    exit: [],
    exit_exprs: [],
    falls: false,
    stmts: [],
    temp_types: [],
    forced: 0,
    hazard: 0,
    dead: true,
  }
}

///|
fn skipped_stack(idx : Int32, why : String) -> FuncStack {
  {
    idx,
    blocks: [],
    temps: 0,
    forced: 0,
    hazard: 0,
    skipped: why,
    refusal: None,
  }
}

// --- the simulator --------------------------------------------------------

///|
/// One value on the operand stack.
pub struct Slot {
  expr : Expr
  ty : ValType
}

///|
/// Mutable simulation state for one block.
priv struct Sim {
  stack : Array[Slot]
  stmts : Array[Stmt]
  /// Type of each allocated temp, indexed by temp id.
  types : Array[ValType]
  mut temps : Int32
  mut forced : Int32
  mut hazard : Int32
}

///|
fn Sim::new() -> Sim {
  { stack: [], stmts: [], types: [], temps: 0, forced: 0, hazard: 0, }
}

///|
fn Sim::height(self : Sim) -> Int32 {
  self.stack.length()
}

///|
fn Sim::push(self : Sim, e : Expr, t : ValType) -> Unit {
  self.stack.push({ expr: e, ty: t, })
}

///|
/// Pop one value, requiring a specific type.
fn Sim::pop(
  self : Sim,
  at : Int32,
  want : ValType,
  what : String,
) -> Expr raise ReadFail {
  if self.stack.length() == 0 {
    fail_at(
      at,
      E011BadStack,
      "\{what} needs \{want.name()} but the operand stack is empty",
    )
  }
  let top = self.stack[self.stack.length() - 1]
  if !ty_eq(top.ty, want) {
    fail_at(
      at,
      E011BadStack,
      "\{what} needs \{want.name()} but the stack has \{top.ty.name()}",
    )
  }
  let _ = self.stack.pop()
  top.expr
}

///|
/// Pop one value of any type, for the instructions that accept several.
fn Sim::pop_any(self : Sim, at : Int32, what : String) -> Slot raise ReadFail {
  if self.stack.length() == 0 {
    fail_at(
      at,
      E011BadStack,
      "\{what} pops a value but the operand stack is empty",
    )
  }
  let top = self.stack[self.stack.length() - 1]
  let _ = self.stack.pop()
  top
}

///|
/// Pop and type-check `n` values, returning them in *source* order (the first
/// element is the deepest, i.e. the one pushed first).
///
/// The reversal matters: everything downstream writes arguments left to right,
/// and a function call whose arguments are reversed is a bug that type-checks
/// whenever the parameters happen to share a type.
fn Sim::pop_n(
  self : Sim,
  at : Int32,
  wants : Array[ValType],
  what : String,
) -> Array[Expr] raise ReadFail {
  let out : Array[Expr] = []
  let mut k = wants.length() - 1
  while k >= 0 {
    out.push(self.pop(at, wants[k], what))
    k = k - 1
  }
  let rev : Array[Expr] = []
  let mut j = out.length() - 1
  while j >= 0 {
    rev.push(out[j])
    j = j - 1
  }
  rev
}

///|
/// Drop values until the stack is `n` deep. A branch discards its frame, and
/// `Array` has no in-place truncate, so the discard is explicit here.
fn cut_stack(s : Sim, n : Int32) -> Unit {
  while s.stack.length() > n {
    let _ = s.stack.pop()
  }
}

///|
/// Re-push a branch's payload so it survives in the block's exit stack.
///
/// Without this the block's exit expressions are empty (or, worse, a bare type
/// marker), and an edge that has to hand the values to its successor has
/// nothing to say. The payloads themselves are the only correct answer: they are
/// the expressions the branch transfers, evaluated where the branch is.
fn push_payload(s : Sim, wants : Array[ValType], vals : Array[Expr]) -> Unit {
  let n = wants.length()
  let mut k = 0
  while k < n && k < vals.length() {
    s.push(vals[k], wants[k])
    k = k + 1
  }
  // A type the branch does not carry (a multi-value loop whose params the
  // simulator cannot name) still has to occupy the slot, or the block's exit
  // shape would disagree with the destination's entry shape.
  while k < n {
    s.push(EParam(0), wants[k])
    k = k + 1
  }
}

///|
/// Materialise `e` into a fresh temporary and push it.
fn Sim::spill(self : Sim, e : Expr, t : ValType) -> Unit {
  let id = self.temps
  self.temps = self.temps + 1
  self.types.push(t)
  self.forced = self.forced + 1
  self.stmts.push(STemp(id, e))
  self.push(ETemp(id), t)
}

///|
/// Materialise every pending value that mentions local `i`.
///
/// Called *before* the assignment, not after, and in bottom-to-top order so the
/// spills themselves stay in the order the values were produced.
fn Sim::sink_local(self : Sim, i : Int32) -> Unit {
  let mut k = 0
  while k < self.stack.length() {
    let s = self.stack[k]
    if expr_mentions_local(s.expr, i) {
      let id = self.temps
      self.temps = self.temps + 1
      self.types.push(s.ty)
      self.hazard = self.hazard + 1
      self.stmts.push(STemp(id, s.expr))
      self.stack[k] = { expr: ETemp(id), ty: s.ty, }
    }
    k = k + 1
  }
}

///|
/// Materialise every pending value that reads global `i`, before it is written.
fn Sim::sink_global(self : Sim, i : Int32) -> Unit {
  let mut k = 0
  while k < self.stack.length() {
    let s = self.stack[k]
    if expr_mentions_global(s.expr, i) {
      let id = self.temps
      self.temps = self.temps + 1
      self.types.push(s.ty)
      self.hazard = self.hazard + 1
      self.stmts.push(STemp(id, s.expr))
      self.stack[k] = { expr: ETemp(id), ty: s.ty, }
    }
    k = k + 1
  }
}

///|
/// Materialise every pending value that reads *some* global, before a call.
fn Sim::sink_globals(self : Sim) -> Unit {
  let mut k = 0
  while k < self.stack.length() {
    let s = self.stack[k]
    if expr_reads_any_global(s.expr) {
      let id = self.temps
      self.temps = self.temps + 1
      self.types.push(s.ty)
      self.hazard = self.hazard + 1
      self.stmts.push(STemp(id, s.expr))
      self.stack[k] = { expr: ETemp(id), ty: s.ty, }
    }
    k = k + 1
  }
}

///|
/// Materialise every pending value that reads memory.
///
/// Called before a store, a call, or a `memory.grow`: all three can change what
/// a later load would observe (a write, an arbitrary side effect, or whether the
/// access traps).
fn Sim::sink_loads(self : Sim) -> Unit {
  let mut k = 0
  while k < self.stack.length() {
    let s = self.stack[k]
    if expr_reads_memory(s.expr) {
      let id = self.temps
      self.temps = self.temps + 1
      self.types.push(s.ty)
      self.hazard = self.hazard + 1
      self.stmts.push(STemp(id, s.expr))
      self.stack[k] = { expr: ETemp(id), ty: s.ty, }
    }
    k = k + 1
  }
}

// --- label handling -------------------------------------------------------

///|
/// The value types a `br depth` at instruction `at` must supply.
///
/// A branch to a `loop` supplies the loop's *parameters* — none, in the subset
/// this project accepts — while a branch to a `block` or `if` supplies its
/// results. That asymmetry is the whole difference between the two constructs,
/// and getting it backwards turns every loop exit into a loop restart.
fn branch_construct(l : Layout, at : Int32, depth : Int32) -> Int32 {
  let mut c = l.owner[at]
  let mut d = depth
  while d > 0 {
    let p = l.parent[c]
    if p < 0 {
      break
    }
    c = p
    d = d - 1
  }
  // Reaching the body construct, or running out of parents, both mean the
  // branch leaves the function: the decoder's label count makes the outermost
  // label the function's own.
  if d > 0 || c == 0 {
    -1
  } else {
    c
  }
}

///|
/// The value types a `br depth` at instruction `at` must supply.
///
/// A branch to a `loop` supplies the loop's *parameters* — none, in the subset
/// this project accepts — while a branch to a `block` or `if` supplies its
/// results. That asymmetry is the whole difference between the two constructs,
/// and getting it backwards turns every loop exit into a loop restart.
fn branch_types(
  l : Layout,
  env : FuncEnv,
  at : Int32,
  depth : Int32,
) -> Array[ValType] raise ReadFail {
  let c = branch_construct(l, at, depth)
  if c < 0 {
    return env.results
  }
  if l.kind[c] == 1 {
    return []
  }
  match l.btype[c] {
    Empty => []
    Value(t) => [t]
    TypeIdx(_) =>
      fail_at(
        at,
        E112MultiValue,
        "branch target is a block with a type index (multi-value), which is outside the subset",
      )
  }
}

///|
/// Number of values construct `c` leaves on the stack: 0 for `Empty`, 1 for a
/// single result, -1 when the block type is a type index.
fn arity_of(bt : BlockType) -> Int32 {
  match bt {
    Empty => 0
    Value(_) => 1
    TypeIdx(_) => -1
  }
}

///|
/// The constructs that start at each real instruction index.
///
/// `block` / `loop` are not instructions in the IR — they are pure structure —
/// so a construct is "entered" at its body's first instruction. Several
/// constructs can share that index (`block { block ... }`), which is harmless:
/// they open at the same stack height by definition.
fn constructs_by_open(l : Layout) -> Array[Array[Int32]] {
  let out : Array[Array[Int32]] = []
  let mut i = 0
  while i <= l.total {
    out.push([])
    i = i + 1
  }
  let mut c = 1
  while c < l.kind.length() {
    out[l.open[c]].push(c)
    c = c + 1
  }
  out
}

///|
/// The constructs that close at each real instruction index — at `close` (the
/// instruction *after* the body) and at `else` (the first instruction of the
/// other arm).
fn constructs_by_close(
  l : Layout,
) -> (Array[Array[Int32]], Array[Array[Int32]]) {
  let at_end : Array[Array[Int32]] = []
  let at_else : Array[Array[Int32]] = []
  let mut i = 0
  while i <= l.total {
    at_end.push([])
    at_else.push([])
    i = i + 1
  }
  let mut c = 1
  while c < l.kind.length() {
    at_end[l.close[c]].push(c)
    if l.else_at[c] >= 0 {
      at_else[l.else_at[c]].push(c)
    }
    c = c + 1
  }
  (at_end, at_else)
}

///|
/// True when control can fall out of the instruction. A block whose last
/// instruction is one of these does not pass its stack shape on to the next
/// instruction, so the "a construct leaves exactly its results" rule must not be
/// applied to it.
fn terminates_flow(i : Instr) -> Bool {
  match i {
    Br(_) | BrTable(_, _) | Return | Unreachable | If(_) => true
    _ => false
  }
}

// --- one block ------------------------------------------------------------

///|
/// Simulate one block and return its statements.
///
/// `bases[c]` is written here, when the simulator reaches a construct's first
/// instruction: that is the only point at which the stack height *is* the
/// construct's base, and it is recorded once because a construct opens exactly
/// once. Every `end` check then reads it instead of recomputing a height that
/// no longer exists.
fn run_block(
  l : Layout,
  env : FuncEnv,
  g : Cfg,
  b : Int32,
  entry : Array[ValType],
  bases : Array[Int32],
  opens : Array[Array[Int32]],
  closes_end : Array[Array[Int32]],
  closes_else : Array[Array[Int32]],
) -> BlockStack raise ReadFail {
  let blk = g.blocks[b]
  let s = Sim::new()
  let mut k = 0
  while k < entry.length() {
    s.push(EParam(k), entry[k])
    k = k + 1
  }
  let mut i = blk.first
  while i < blk.end {
    let at = l.ops[i].offset
    // A construct whose body starts here opens at the current height.
    for c in opens[i] {
      bases[c] = s.height()
    }
    match l.ops[i].instr {
      Nop => ()
      Unreachable => {
        s.stmts.push(SUnreachable)
        return finish(s, b, entry, false)
      }
      // Structure, never an instruction in `l.ops`: kept in the match so that a
      // future IR change fails to compile rather than silently doing nothing.
      Block(_) | Loop(_) | End | Else => ()
      If(bt) => {
        let cond = s.pop(at, I32, "if")
        s.stmts.push(SIf(cond))
        if arity_of(bt) < 0 {
          fail_at(
            at,
            E112MultiValue,
            "'if' has a type index as its block type, which is outside the subset",
          )
        }
      }
      Br(d) => {
        let wants = branch_types(l, env, i, d)
        let vals = s.pop_n(at, wants, "br")
        if branch_construct(l, i, d) < 0 {
          // `br` past the outermost label *is* a return; emitting it as one
          // keeps the generated code from containing a label nobody encloses.
          s.stmts.push(SReturn(vals))
        } else {
          s.stmts.push(SBr(d, vals))
        }
        // A branch discards everything below the transferred values.
        let base = branch_base(l, i, d, bases)
        cut_stack(s, base)
        push_payload(s, wants, vals)
        return finish(s, b, entry, false)
      }
      BrIf(d) => {
        let cond = s.pop(at, I32, "br_if")
        let wants = branch_types(l, env, i, d)
        let vals = peek_n(s, at, wants, "br_if")
        s.stmts.push(SBrIf(d, vals, cond))
      }
      BrTable(ls, d) => {
        let idx = s.pop(at, I32, "br_table")
        let wants = branch_types(l, env, i, d)
        for x in ls {
          let w = branch_types(l, env, i, x)
          if !same_types(w, wants) {
            fail_at(
              at,
              E011BadStack,
              "br_table targets disagree: default needs \{wants.length()} value(s), label \{x} needs \{w.length()}",
            )
          }
        }
        let vals = peek_n(s, at, wants, "br_table")
        s.stmts.push(SBrTable(ls, d, vals, idx))
        let base = branch_base(l, i, d, bases)
        cut_stack(s, base)
        push_payload(s, wants, vals)
        return finish(s, b, entry, false)
      }
      Return => {
        let vals = s.pop_n(at, env.results, "return")
        s.stmts.push(SReturn(vals))
        // The exit block's shape is the function's results, so a return edge
        // reports that shape rather than the (now empty) local stack. Without
        // this, every `return` would look like it disagreed with the
        // fall-through off the end of the body.
        cut_stack(s, 0)
        push_payload(s, env.results, vals)
        return finish(s, b, entry, false)
      }
      Call(f) => {
        let ft = callee_type(env, at, f)
        if ft.results.length() > 1 {
          fail_at(
            at,
            E112MultiValue,
            "call returns \{ft.results.length()} values; multi-value is outside the subset",
          )
        }
        let args = s.pop_n(at, ft.params, "call")
        s.sink_loads()
        // The callee may write any global as well as any memory.
        s.sink_globals()
        let e = ECall(f, args)
        if ft.results.length() == 0 {
          s.stmts.push(SEval(e))
        } else {
          s.spill(e, ft.results[0])
        }
      }
      CallIndirect(t) => {
        if !env.has_table {
          fail_at(
            at,
            E008BadIndex,
            "call_indirect needs a table, and the module declares none",
          )
        }
        let ft = type_at(env, at, t)
        if ft.results.length() > 1 {
          fail_at(
            at,
            E112MultiValue,
            "call_indirect returns \{ft.results.length()} values; multi-value is outside the subset",
          )
        }
        // The index sits on top of the arguments, so it is popped first. The
        // target is unknown here, which is why this is not just `Call`: the
        // generated code has to look the function up and check its type at run
        // time, exactly as the wasm engine would.
        let idx = s.pop(at, I32, "call_indirect")
        let args = s.pop_n(at, ft.params, "call_indirect")
        // The callee is not known, so it may write memory and any global.
        s.sink_loads()
        s.sink_globals()
        let e = ECallIndirect(t, idx, args)
        if ft.results.length() == 0 {
          s.stmts.push(SEval(e))
        } else {
          s.spill(e, ft.results[0])
        }
      }
      Drop => {
        let v = s.pop_any(at, "drop")
        if expr_has_effect(v.expr) {
          s.stmts.push(SEval(v.expr))
        }
      }
      Select => {
        let cond = s.pop(at, I32, "select")
        let b2 = s.pop_any(at, "select")
        let a2 = s.pop_any(at, "select")
        if !ty_eq(a2.ty, b2.ty) {
          fail_at(
            at,
            E011BadStack,
            "select operands differ: \{a2.ty.name()} and \{b2.ty.name()}",
          )
        }
        s.push(ESelect(a2.expr, b2.expr, cond), a2.ty)
      }
      LocalGet(x) => {
        let t = local_type(env, at, x)
        s.push(ELocal(x), t)
      }
      LocalSet(x) => {
        let t = local_type(env, at, x)
        let v = s.pop(at, t, "local.set")
        s.sink_local(x)
        s.stmts.push(SLocal(x, v))
      }
      LocalTee(x) => {
        let t = local_type(env, at, x)
        let v = s.pop(at, t, "local.tee")
        s.sink_local(x)
        s.stmts.push(SLocal(x, v))
        s.push(ELocal(x), t)
      }
      GlobalGet(x) => {
        let t = global_type(env, at, x)
        s.push(EGlobal(x), t)
      }
      GlobalSet(x) => {
        let t = global_type(env, at, x)
        let v = s.pop(at, t, "global.set")
        s.sink_global(x)
        s.stmts.push(SGlobal(x, v))
      }
      Mem(op) => {
        require_memory(env, at)
        if op.store {
          let v = s.pop(at, op.ty, "store")
          let addr = s.pop(at, I32, "store")
          s.sink_loads()
          s.stmts.push(SStore(op, addr, v))
        } else {
          let addr = s.pop(at, I32, op.mnemonic())
          s.push(ELoad(op, addr), op.ty)
        }
      }
      MemorySize => {
        require_memory(env, at)
        s.push(EMemorySize, I32)
      }
      MemoryGrow => {
        require_memory(env, at)
        let n = s.pop(at, I32, "memory.grow")
        s.sink_loads()
        s.spill(EMemoryGrow(n), I32)
      }
      Const(c) => s.push(EConst(c), c.ty())
      Un(t, kind) => {
        let a = s.pop(at, t, "unary operator")
        s.push(EUn(t, kind, a), t)
      }
      Bin(t, kind) => {
        let rhs = s.pop(at, t, bin_mnemonic(t, kind))
        let lhs = s.pop(at, t, bin_mnemonic(t, kind))
        let out = if kind.is_comparison() { I32 } else { t }
        s.push(EBin(t, kind, lhs, rhs), out)
      }
      Conv(to, from, mode) => {
        // `reinterpret` is the one conversion that does not change the bit
        // pattern; every other one is a numeric conversion or a truncation.
        let a = s.pop(at, from, "\{to.name()}.\{mode.suffix(from)}")
        s.push(EConv(to, from, mode, a), to)
      }
      Misc(_) =>
        fail_at(
          at,
          E109BulkMemory,
          "bulk-memory operations copy passive segments, which do not survive decompilation",
        )
    }
    i = i + 1
  }
  // The block fell through. If it also ends exactly at a construct boundary, the
  // stack above that construct's base must be exactly its results — this is the
  // rule that makes the two arms of `if (result i32)` agree, and it is the
  // reason `bases[]` is worth recording at all.
  //
  // A block ending in an unconditional transfer never reaches here (it returned
  // above); `if` falls through the check because its two successors receive the
  // stack, not the next instruction.
  if blk.end > blk.first && !terminates_flow(l.ops[blk.end - 1].instr) {
    check_boundary(l, at_of(l, blk), s, blk.end, closes_end, bases)
    check_boundary(l, at_of(l, blk), s, blk.end, closes_else, bases)
  }
  finish(s, b, entry, true)
}

///|
/// Offset of a block's last instruction, for diagnostics at a boundary where
/// there is no instruction to point at.
fn at_of(l : Layout, blk : Block) -> Int32 {
  if blk.end > blk.first {
    l.ops[blk.end - 1].offset
  } else {
    0
  }
}

///|
/// Validate the height at a construct boundary.
fn check_boundary(
  l : Layout,
  at : Int32,
  s : Sim,
  end : Int32,
  table : Array[Array[Int32]],
  bases : Array[Int32],
) -> Unit raise ReadFail {
  for c in table[end] {
    let base = bases[c]
    let arity = arity_of(l.btype[c])
    // `base < 0` means the construct opened in dead code, and `arity < 0` means
    // its type index was already refused by `branch_types`. Neither is a
    // boundary this function can check.
    if base >= 0 && arity >= 0 && s.height() != base + arity {
      fail_at(
        at,
        E011BadStack,
        "construct ends with \{s.height() - base} value(s) above its base but declares \{arity}",
      )
    }
  }
}

///|
/// Pop the values a branch transfers and package the block result.
fn finish(
  s : Sim,
  b : Int32,
  entry : Array[ValType],
  falls : Bool,
) -> BlockStack {
  let exit : Array[ValType] = []
  let exprs : Array[Expr] = []
  for x in s.stack {
    exit.push(x.ty)
    exprs.push(x.expr)
  }
  {
    block: b,
    entry,
    exit,
    exit_exprs: exprs,
    falls,
    stmts: s.stmts,
    temp_types: s.types,
    forced: s.forced,
    hazard: s.hazard,
    dead: false,
  }
}

///|
/// The stack height a branch restores: the target construct's base. A branch
/// leaves the frame, so everything above that base is discarded.
fn branch_base(
  l : Layout,
  at : Int32,
  depth : Int32,
  bases : Array[Int32],
) -> Int32 {
  let c = branch_construct(l, at, depth)
  if c < 0 {
    return 0
  }
  let b = bases[c]
  if b < 0 {
    0
  } else {
    b
  }
}

///|
/// `br_if` and `br_table` do not pop their values: the fall-through keeps them.
/// So the values are *checked* here and left on the stack.
fn peek_n(
  s : Sim,
  at : Int32,
  wants : Array[ValType],
  what : String,
) -> Array[Expr] raise ReadFail {
  if s.height() < wants.length() {
    fail_at(
      at,
      E011BadStack,
      "\{what} needs \{wants.length()} value(s) but the stack has \{s.height()}",
    )
  }
  let out : Array[Expr] = []
  let mut k = 0
  while k < wants.length() {
    let idx = s.height() - wants.length() + k
    let slot = s.stack[idx]
    if !ty_eq(slot.ty, wants[k]) {
      fail_at(
        at,
        E011BadStack,
        "\{what} needs \{wants[k].name()} at operand \{k + 1} but the stack has \{slot.ty.name()}",
      )
    }
    out.push(slot.expr)
    k = k + 1
  }
  out
}

///|
fn local_type(env : FuncEnv, at : Int32, i : Int32) -> ValType raise ReadFail {
  if i < 0 || i >= env.locals.length() {
    fail_at(at, E008BadIndex, "local \{i} is out of range")
  }
  env.locals[i]
}

///|
fn global_type(env : FuncEnv, at : Int32, i : Int32) -> ValType raise ReadFail {
  if i < 0 || i >= env.globals.length() {
    fail_at(at, E008BadIndex, "global \{i} is out of range")
  }
  env.globals[i]
}

///|
fn callee_type(env : FuncEnv, at : Int32, f : Int32) -> FuncType raise ReadFail {
  if f < 0 || f >= env.funcs.length() {
    fail_at(at, E008BadIndex, "function \{f} is out of range")
  }
  env.funcs[f]
}

///|
fn require_memory(env : FuncEnv, at : Int32) -> Unit raise ReadFail {
  if !env.has_memory {
    fail_at(
      at,
      E008BadIndex,
      "the module declares no memory, but this instruction indexes one",
    )
  }
}

///|
/// The signature `call_indirect` names by type index.
///
/// A bad index is a malformed input, not an unsupported feature, and saying so
/// is more useful than a generic refusal.
fn type_at(env : FuncEnv, at : Int32, t : Int32) -> FuncType raise ReadFail {
  if t < 0 || t >= env.types.length() {
    fail_at(at, E008BadIndex, "type index \{t} is out of range")
  }
  env.types[t]
}

// --- one function ---------------------------------------------------------

///|
/// Analyse one defined function.
///
/// `Err` means the body is *malformed* — the operand stack does not type-check.
/// A function that is merely outside the subset comes back as `Ok` with
/// `refusal` set, because that is a decision about generation, not a verdict on
/// the input. The distinction is the same one the decoder makes between a bad
/// opcode and an unsupported one.
pub fn analyze_func(m : Module, idx : Int32) -> Result[FuncStack, Diag] {
  let body = match attempt(() => decode_func(m, idx)) {
    Ok(b) => b
    Err(d) => return Err(d)
  }
  if !body.is_complete() {
    return Ok(skipped_stack(idx, body.stop_note()))
  }
  let l = match build_layout(body.instrs) {
    None => return Ok(skipped_stack(idx, "brackets do not balance"))
    Some(l) => l
  }
  let env = func_env(m, idx)
  // A v128 local or parameter cannot be generated, and there is no point
  // pretending otherwise: the whole function is refused, at the signature.
  match m.func_type(idx) {
    Some(t) =>
      if t.has_unsupported_type() {
        return Ok(
          refused_stack(
            idx,
            Diag::new(
              E102Simd,
              0,
              "the signature uses v128, which has no MoonBit representation",
            ),
          ),
        )
      } else if t.results.length() > 1 {
        // The emitter prints a single MoonBit result. Silently returning only
        // `vs[0]` would make `scan_reads` think the other values are read and
        // leave a live variable behind — and, worse, it would be a wrong answer
        // wearing a clean compile. Refuse at the signature instead.
        return Ok(
          refused_stack(
            idx,
            Diag::new(
              E112MultiValue,
              0,
              "the function returns \{t.results.length()} values; multi-value is outside the subset",
            ),
          ),
        )
      }
    None => ()
  }
  let mut k = 0
  while k < env.locals.length() {
    if !env.locals[k].is_generatable() {
      return Ok(
        refused_stack(
          idx,
          Diag::new(
            E102Simd,
            0,
            "local \{k} is v128, which has no MoonBit representation",
          ),
        ),
      )
    }
    k = k + 1
  }
  match analyze_blocks(l, env, build_cfg(l)) {
    Err(d) =>
      if d.code.is_malformed() {
        Err(d)
      } else {
        Ok(refused_stack(idx, d))
      }
    Ok(blocks) =>
      Ok({
        idx,
        blocks,
        temps: block_temps(blocks),
        forced: sum_forced(blocks),
        hazard: sum_hazard(blocks),
        skipped: "",
        refusal: None,
      })
  }
}

///|
/// Simulate every block of a function, in block-index order.
///
/// Index order is a topological order of the forward edges — a block's range
/// starts before every block it jumps to, except a loop back edge, which points
/// at a *lower* index — so a block's entry shape is always known from a
/// predecessor that has already been processed. That is what makes one pass
/// enough, with no fixed-point iteration.
///
/// Separate from `analyze_func` so the tests can drive it with a hand-written
/// instruction list and a hand-built environment, without fabricating a module.
fn analyze_blocks(
  l : Layout,
  env : FuncEnv,
  g : Cfg,
) -> Result[Array[BlockStack], Diag] {
  let nb = g.block_count()
  let bases = Array::make(l.kind.length(), -1)
  let opens = constructs_by_open(l)
  let (closes_end, closes_else) = constructs_by_close(l)
  // Block shapes, indexed by block; the exit pseudo-block is at `nb` and expects
  // exactly the function's results, which is what makes "the function body
  // returns the wrong type" an ordinary join-point error rather than a special
  // case at the end.
  let shape : Array[Array[ValType]] = Array::make(nb + 1, [])
  let resolved = Array::make(nb + 1, false)
  shape[nb] = env.results
  resolved[nb] = true
  let blocks : Array[BlockStack] = []
  let mut b = 0
  while b < nb {
    let blk = g.blocks[b]
    if !blk.reachable {
      blocks.push(dead_stack(b))
    } else {
      let mut picked : Array[ValType] = []
      let mut found = false
      if b == 0 {
        // The operand stack starts empty: parameters are locals, not stack
        // values. Multi-value *parameters* would change that, and they cannot
        // reach here because the signature check refuses them first.
        found = true
      } else {
        for p in blk.pred {
          if resolved[p] {
            if !found {
              picked = shape[p]
              found = true
            } else if !same_types(picked, shape[p]) {
              return Err(
                Diag::new(
                  E011BadStack,
                  l.ops[blk.first].offset,
                  "block is entered with \{render_types(picked)} and \{render_types(shape[p])} by different predecessors",
                ),
              )
            }
          }
        }
      }
      if !found {
        // Reachable per the DFS but no predecessor produced a shape: the only
        // way that happens is a predecessor that is itself dead, so treat the
        // block as dead rather than inventing a stack for it.
        blocks.push(dead_stack(b))
      } else {
        shape[b] = picked
        resolved[b] = true
        let r = attempt(() => {
          run_block(l, env, g, b, picked, bases, opens, closes_end, closes_else)
        })
        match r {
          Err(d) => return Err(d)
          Ok(bs) => {
            shape[b] = bs.exit
            blocks.push(bs)
          }
        }
      }
    }
    b = b + 1
  }
  // Every edge into the exit block must supply the function's results.
  let mut e = 0
  while e < nb {
    if contains_block(g.blocks[e].succ, nb) && resolved[e] {
      if !same_types(shape[e], env.results) {
        return Err(
          Diag::new(
            E011BadStack,
            at_of(l, g.blocks[e]),
            "the function returns \{render_types(env.results)} but b\{e} falls out with \{render_types(shape[e])}",
          ),
        )
      }
    }
    e = e + 1
  }
  Ok(blocks)
}

///|
/// Temps are per block inside `BlockStack`, but a generated function has one
/// pool for all its blocks: a temporary that is dead at the end of its block can
/// be reused by the next one. Summing is the safe upper bound and is what the
/// generated source will declare.
fn block_temps(blocks : Array[BlockStack]) -> Int32 {
  sum_forced(blocks) + sum_hazard(blocks)
}

///|
fn sum_forced(blocks : Array[BlockStack]) -> Int32 {
  let mut n = 0
  for b in blocks {
    n = n + b.forced
  }
  n
}

///|
fn sum_hazard(blocks : Array[BlockStack]) -> Int32 {
  let mut n = 0
  for b in blocks {
    n = n + b.hazard
  }
  n
}

///|
fn contains_block(xs : Array[Int32], x : Int32) -> Bool {
  let mut found = false
  for y in xs {
    if y == x {
      found = true
    }
  }
  found
}

///|
fn refused_stack(idx : Int32, d : Diag) -> FuncStack {
  {
    idx,
    blocks: [],
    temps: 0,
    forced: 0,
    hazard: 0,
    skipped: "",
    refusal: Some(d),
  }
}

// --- rendering ------------------------------------------------------------

///|
/// `[]`, `[i32]`, `[i32, f64]`.
pub fn render_types(xs : Array[ValType]) -> String {
  if xs.length() == 0 {
    return "[]"
  }
  let b = StringBuilder()
  b.write_string("[")
  let mut i = 0
  while i < xs.length() {
    if i > 0 {
      b.write_string(", ")
    }
    b.write_string(xs[i].name())
    i = i + 1
  }
  b.write_string("]")
  b.to_string()
}

///|
/// One expression, in the surface syntax the generated MoonBit will resemble.
///
/// Memory operands keep their `.wat` spelling while every other operator is
/// written as a call, because `i32.add(a, b)` says "this is a function of two
/// values" and `i32.load offset=4(addr)` says "this reads four bytes at
/// addr + 4" — and those are the two facts a reader checks first.
pub fn Expr::render(self : Expr, m : Module) -> String {
  match self {
    EConst(c) => "\{c.mnemonic()} \{c.operand()}"
    ELocal(i) => "local \{i}"
    EGlobal(i) => "global \{i}"
    ETemp(t) => "t\{t}"
    EParam(k) => "in\{k}"
    ELoad(op, a) => "\{op.mnemonic()}[\{op.operands()}](\{a.render(m)})"
    EBin(t, k, a, b) => "\{bin_mnemonic(t, k)}(\{a.render(m)}, \{b.render(m)})"
    EUn(t, k, a) => "\{t.name()}.\{k.suffix()}(\{a.render(m)})"
    EConv(to, from, mode, a) =>
      "\{to.name()}.\{mode.suffix(from)}(\{a.render(m)})"
    ECall(f, args) => "call \{m.func_label(f)}(\{render_args(args, m)})"
    ECallIndirect(t, i, args) =>
      "call_indirect[type \{t}](\{i.render(m)}, \{render_args(args, m)})"
    ESelect(a, b, c) => "select(\{a.render(m)}, \{b.render(m)}, \{c.render(m)})"
    EMemorySize => "memory.size"
    EMemoryGrow(a) => "memory.grow(\{a.render(m)})"
  }
}

///|
fn render_args(xs : Array[Expr], m : Module) -> String {
  let b = StringBuilder()
  let mut i = 0
  while i < xs.length() {
    if i > 0 {
      b.write_string(", ")
    }
    b.write_string(xs[i].render(m))
    i = i + 1
  }
  b.to_string()
}

///|
/// `(v0, v1)`, or `()` for no values.
fn render_vals(xs : Array[Expr], m : Module) -> String {
  "(" + render_args(xs, m) + ")"
}

///|
pub fn Stmt::render(self : Stmt, m : Module) -> String {
  match self {
    SLocal(i, e) => "local \{i} = \{e.render(m)}"
    SGlobal(i, e) => "global \{i} = \{e.render(m)}"
    STemp(t, e) => "t\{t} = \{e.render(m)}"
    SStore(op, a, v) =>
      "\{op.mnemonic()}[\{op.operands()}](\{a.render(m)}, \{v.render(m)})"
    SEval(e) => e.render(m)
    SIf(c) => "if (\{c.render(m)})"
    SBr(d, vs) => "br \{d} \{render_vals(vs, m)}"
    SBrIf(d, vs, c) => "br_if \{d} \{render_vals(vs, m)} if (\{c.render(m)})"
    SBrTable(ls, d, vs, c) => {
      let b = StringBuilder()
      b.write_string("br_table [")
      let mut i = 0
      for x in ls {
        if i > 0 {
          b.write_string(" ")
        }
        b.write_string("\{x}")
        i = i + 1
      }
      b.write_string("] default \{d} \{render_vals(vs, m)} if (\{c.render(m)})")
      b.to_string()
    }
    SReturn(vs) => "return \{render_vals(vs, m)}"
    SUnreachable => "unreachable"
  }
}

///|
/// One function's recovered code.
pub fn FuncStack::render(self : FuncStack, m : Module) -> String {
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
  if self.blocks.length() == 0 {
    return b.to_string()
  }
  for bs in self.blocks {
    if bs.dead {
      b.write_string("  b\{bs.block}  (unreachable)\n")
      continue
    }
    b.write_string("  b\{bs.block}  in \{render_types(bs.entry)}  out ")
    if bs.falls {
      b.write_string(render_types(bs.exit))
      if bs.exit_exprs.length() > 0 {
        b.write_string(" = \{render_vals(bs.exit_exprs, m)}")
      }
    } else {
      b.write_string("-")
    }
    let n = bs.forced + bs.hazard
    if n > 0 {
      b.write_string("  temps \{n}")
    }
    b.write_string("\n")
    for st in bs.stmts {
      b.write_string("    \{st.render(m)}\n")
    }
  }
  b.to_string()
}

// --- module-level entry points -------------------------------------------

///|
/// Full listing: every function, in index order.
pub fn stack_text(m : Module, path : String) -> String raise ReadFail {
  let b = StringBuilder()
  b.write_string(";; moonlift stack — \{path}\n")
  b.write_string(
    ";; one line per assignment; 'in' / 'out' are the operand-stack shapes at a block's edges\n",
  )
  let mut idx = 0
  while idx < m.func_count() {
    if idx >= m.imported_func_count() {
      match analyze_func(m, idx) {
        Err(d) => raise ReadFail(d)
        Ok(f) => b.write_string(f.render(m))
      }
    }
    idx = idx + 1
  }
  b.to_string()
}

///|
/// Aggregate numbers for `disasm --stats`.
pub struct StackStats {
  functions : Int32
  analysed : Int32
  skipped : Int32
  refused : Int32
  /// Functions whose every block recovered without needing a temporary.
  clean : Int32
  statements : Int32
  temps : Int32
  forced : Int32
  hazard : Int32
  notes : Array[String]
}

///|
pub fn stack_stats(m : Module) -> StackStats {
  let mut functions = 0
  let mut analysed = 0
  let mut skipped = 0
  let mut refused = 0
  let mut clean = 0
  let mut statements = 0
  let mut temps = 0
  let mut forced = 0
  let mut hazard = 0
  let notes : Array[String] = []
  let mut idx = 0
  while idx < m.func_count() {
    if idx >= m.imported_func_count() {
      functions = functions + 1
      match analyze_func(m, idx) {
        Err(d) => {
          skipped = skipped + 1
          notes.push(
            "  f\{idx} \{m.func_label(idx)}: rejected — \{d.render()}",
          )
        }
        Ok(f) =>
          if f.skipped != "" {
            skipped = skipped + 1
            notes.push(
              "  f\{idx} \{m.func_label(idx)}: skipped — \{f.skipped}",
            )
          } else {
            match f.refusal {
              Some(d) => {
                refused = refused + 1
                notes.push(
                  "  f\{idx} \{m.func_label(idx)}: refused — \{d.render()}",
                )
              }
              None => {
                analysed = analysed + 1
                temps = temps + f.temps
                forced = forced + f.forced
                hazard = hazard + f.hazard
                if f.forced + f.hazard == 0 {
                  clean = clean + 1
                }
                for bs in f.blocks {
                  statements = statements + bs.stmts.length()
                }
              }
            }
          }
      }
    }
    idx = idx + 1
  }
  {
    functions,
    analysed,
    skipped,
    refused,
    clean,
    statements,
    temps,
    forced,
    hazard,
    notes,
  }
}

///|
/// The stack section of `disasm --stats`.
pub fn stack_summary_text(m : Module) -> String {
  let s = stack_stats(m)
  let b = StringBuilder()
  b.write_string(
    stat_line("analysed", "\{s.analysed} of \{s.functions} bodies"),
  )
  b.write_string(stat_line("statements", "\{s.statements}"))
  b.write_string(stat_line("temps", "\{s.temps}"))
  b.write_string(stat_line("spill-free", "\{s.clean}"))
  b.write_string(
    stat_line(
      "spills",
      "\{s.forced + s.hazard} (\{s.forced} forced, \{s.hazard} hazard)",
    ),
  )
  if s.skipped > 0 {
    b.write_string(stat_line("skipped", "\{s.skipped}"))
  }
  if s.refused > 0 {
    b.write_string(stat_line("refused", "\{s.refused}"))
  }
  for n in s.notes {
    b.write_string("\{n}\n")
  }
  b.to_string()
}

// --- Result-returning wrappers --------------------------------------------

///|
pub fn stack_text_result(m : Module, path : String) -> DecodeResult[String] {
  attempt(() => stack_text(m, path))
}

///|
pub fn stack_summary_result(m : Module) -> DecodeResult[String] {
  Ok(stack_summary_text(m))
}
