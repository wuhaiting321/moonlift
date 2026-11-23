// MoonBit source generation from the recovered structure.
//
// This layer turns the tree built by `struct.mbt` into text a MoonBit compiler
// accepts. It decides nothing about control flow — that is already decided, and
// deciding it twice would mean two places to get it wrong — it chooses *names*
// and *spelling*:
//
// | wasm | MoonBit |
// |---|---|
// | `i32` / `i64` / `f32` / `f64` | `Int` / `Int64` / `Float` / `Double` |
// | local `i` | `l{i}` |
// | temp `k` of a block | `t{k}`, or `t{k}_{n}` when two blocks disagree on its type |
// | global `i` | `g{i}.val` |
// | `i32.load offset=4` | `mem.load_i32((a + 4))` — the offset folded into the address |
// | `i32.div_s` | `i32_div_s(a, b)` — a helper, because MoonBit and wasm disagree |
// | `i32.add` | `(a + b)` — an operator, because they agree |
//
// The rule behind the last two rows: an operator where the semantics was
// *measured* to match, a named helper where it was measured not to. Every helper
// lives in `runtime/runtime.mbt`, which is copied into the output and compiled by
// this repository's own gate, so a helper that does not exist cannot ship.

///|
/// One file of generated output.
pub struct GenFile {
  name : String
  text : String
}

///|
/// What a decompilation produced: the files, plus what could not be translated.
///
/// The refusals are data, not messages, so the CLI can report them and the
/// differential harness can decide what to skip.
pub struct GenReport {
  files : Array[GenFile]
  /// Functions emitted, by index.
  emitted : Array[Int32]
  /// Functions refused, with the diagnostic that refused them.
  refused : Array[(Int32, Diag)]
  /// Functions skipped (partial decode), with the reason.
  skipped : Array[(Int32, String)]
  exports : Int32
  memory_pages : Int32
  data_bytes : Int32
  globals : Int32
  imports : Int32
}

///|
/// Everything the renderer needs about one function.
priv struct Emit {
  m : Module
  env : FuncEnv
  fs : FuncStack
  names : Names
  /// How many of `env.locals` arrived as parameters. Locals past that point have
  /// no `p{i}` spelling at all.
  np : Int32
  /// Which locals the body writes. A wasm parameter that is never written is
  /// used as the parameter itself; one that is written needs a mutable copy,
  /// because MoonBit has no mutable parameters.
  assigned : Array[Bool]
  /// Which locals the emitted text reads. A local that is written but never read
  /// is named `_l3`, which is how MoonBit is told the value is deliberately
  /// unused — true of a wasm local whose only remaining purpose was a spill slot.
  reads : Array[Bool]
}

///|
/// The name a parameter is declared under.
fn Emit::pname(self : Emit, i : Int32) -> String {
  if i >= 0 && i < self.reads.length() && !self.reads[i] && !self.assigned[i] {
    "_p\{i}"
  } else {
    "p\{i}"
  }
}

///|
/// The name a local is stored under, underscored when nothing reads it.
fn Emit::lname(self : Emit, i : Int32) -> String {
  if i >= 0 && i < self.reads.length() && !self.reads[i] {
    "_l\{i}"
  } else {
    local_name(i)
  }
}

///|
/// The name a local is referred to by: the parameter itself when it is never
/// written, and the mutable copy otherwise.
fn Emit::local_of(self : Emit, i : Int32) -> String {
  // A declared local is only ever `l{i}`: there is no parameter for it to fall
  // back on, whether or not the body writes it.
  if i >= self.np {
    return self.lname(i)
  }
  if i >= 0 && i < self.assigned.length() && self.assigned[i] {
    self.lname(i)
  } else {
    self.pname(i)
  }
}

// --- spelling -------------------------------------------------------------

///|
fn ty_name(t : ValType) -> String {
  match t {
    I32 => "Int"
    I64 => "Int64"
    F32 => "Float"
    F64 => "Double"
    V128 => "Int"
  }
}

///|
fn zero_text(t : ValType) -> String {
  match t {
    I32 => "0"
    I64 => "0L"
    F32 => "0.0"
    F64 => "0.0"
    V128 => "0"
  }
}

///|
/// `ValType` does not implement `Eq`, so comparison is spelled out. It is also
/// the only place that has to know the set is closed.
fn vt_eq(a : ValType, b : ValType) -> Bool {
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
fn func_name(idx : Int32) -> String {
  "f\{idx}"
}

///|
fn local_name(i : Int32) -> String {
  "l\{i}"
}

// --- names ----------------------------------------------------------------

///|
/// The names a generated function uses.
///
/// Temps are numbered per block by the analysis, so the same number means
/// different things in different blocks. They are merged here: the first type a
/// number is seen with claims `t{k}`, and a later block that uses the same number
/// for a different type gets `t{k}_{n}`. In practice a function has one type per
/// temp number and the suffix never appears — but it has to be *possible*,
/// because the alternative is a program that does not compile for a reason the
/// decompiler caused.
priv struct Names {
  /// Per temp number: the type it is currently declared as, or "" when unused.
  ty : Array[String]
  /// Per temp number: the name it is currently declared as.
  name : Array[String]
  /// Per temp number: how many conflicting declarations have been made.
  extra : Array[Int32]
  /// `let mut ...` lines, in the order they were needed.
  decls : Array[String]
  /// Per temp number: whether the emitted text reads it. A temp that is only
  /// written is a spill slot whose value nothing wanted; it gets `_t{k}` so the
  /// generated file builds without an unused-variable warning.
  reads : Array[Bool]
}

///|
fn new_names(n : Int32, reads : Array[Bool]) -> Names {
  let k = if n < 1 { 1 } else { n }
  let r = Array::make(k, false)
  let mut i = 0
  while i < reads.length() && i < k {
    r[i] = reads[i]
    i = i + 1
  }
  {
    ty: Array::make(k, ""),
    name: Array::make(k, ""),
    extra: Array::make(k, 0),
    decls: [],
    reads: r,
  }
}

///|
/// The base name of temp `id`: `t3` when something reads it, `_t3` when nothing
/// does.
fn Names::base(self : Names, id : Int32) -> String {
  if id >= 0 && id < self.reads.length() && !self.reads[id] {
    "_t\{id}"
  } else {
    "t\{id}"
  }
}

///|
fn Names::bind(self : Names, id : Int32, t : ValType) -> String {
  let want = ty_name(t)
  if id < 0 || id >= self.ty.length() {
    // A temp number past what the analysis reported would be a bug in the
    // analysis rather than in the input. Naming it keeps the output compilable so
    // the bug shows up as a wrong value instead of a build error.
    return self.base(id)
  }
  if self.ty[id] == want {
    return self.name[id]
  }
  if self.ty[id] == "" {
    let nm = self.base(id)
    self.ty[id] = want
    self.name[id] = nm
    self.decls.push("let mut \{nm} : \{want} = \{zero_text(t)}")
    return self.name[id]
  }
  let n = self.extra[id] + 1
  self.extra[id] = n
  let fresh = "\{self.base(id)}_\{n}"
  self.ty[id] = want
  self.name[id] = fresh
  self.decls.push("let mut \{fresh} : \{want} = \{zero_text(t)}")
  fresh
}

///|
fn Names::of(self : Names, id : Int32) -> String {
  if id >= 0 && id < self.name.length() && self.name[id] != "" {
    self.name[id]
  } else {
    self.base(id)
  }
}

// --- export names ---------------------------------------------------------

///|
/// Words that already mean something in a generated package, so an export may not
/// keep its name verbatim. A wasm export called `match` is legal and a MoonBit
/// function called `match` is not.
fn reserved_word(s : String) -> Bool {
  let words : Array[String] = [
    "let", "mut", "fn", "if", "else", "while", "for", "in", "match", "type", "struct",
    "enum", "trait", "impl", "pub", "priv", "return", "break", "continue", "true",
    "false", "and", "or", "not", "as", "is", "test", "async", "try", "catch", "throw",
    "raise", "suberror", "const", "extern", "newtype", "with", "where", "init", "derive",
    "default", "guard", "self", "mem", "brk", "trap", "ignore", "abort", "f", "l",
    "t", "g",
  ]
  let mut found = false
  for w in words {
    if w == s {
      found = true
    }
  }
  found
}

///|
/// A MoonBit function name derived from a wasm export name.
///
/// Anything that is not `[A-Za-z0-9]` becomes `_` and runs of those collapse, so
/// `_M0FP...` keeps its shape and `my-func` becomes `my_func`. Leading digits and
/// reserved words get an `e_` prefix rather than being dropped: a wrapper that is
/// missing is a function the caller cannot reach.
fn sanitize(s : String) -> String {
  let b = StringBuilder()
  let mut prev_us = false
  for ch in s {
    let ok = if ch >= 'a' && ch <= 'z' {
      true
    } else if ch >= 'A' && ch <= 'Z' {
      true
    } else if ch >= '0' && ch <= '9' {
      true
    } else {
      false
    }
    if ok {
      b.write_char(ch)
      prev_us = false
    } else if !prev_us {
      b.write_char('_')
      prev_us = true
    }
  }
  let mut out = b.to_string()
  if out == "" {
    out = "e"
  }
  let mut lead_digit = false
  for ch in out {
    if ch >= '0' && ch <= '9' {
      lead_digit = true
    }
    break
  }
  if lead_digit {
    out = "e_" + out
  }
  if reserved_word(out) {
    out = "e_" + out
  }
  out
}

// --- memory operations ----------------------------------------------------

///|
/// The `Memory` method for a load or store. The width and the sign come from the
/// encoding, not from the value type: `i32.load8_s` is a one-byte signed load
/// that produces an `Int`.
fn mem_method(op : MemOp) -> String {
  let base = if op.store { "store" } else { "load" }
  let v = match op.ty {
    I32 => "i32"
    I64 => "i64"
    F32 => "f32"
    F64 => "f64"
    V128 => "i32"
  }
  if vt_eq(op.ty, F32) || vt_eq(op.ty, F64) {
    // Float accesses have exactly one width; there is no `f32.load8`.
    return "\{base}_\{v}"
  }
  let native = if vt_eq(op.ty, I32) { 32 } else { 64 }
  if op.width * 8 == native {
    return "\{base}_\{v}"
  }
  let suffix = if op.store { "" } else if op.signed { "s" } else { "u" }
  "\{base}_\{v}_\{op.width * 8}\{suffix}"
}

///|
/// `addr` with the static offset folded in, so the generated code shows one
/// address expression instead of a helper call with a hidden `+ 4`.
fn addr_text(a : String, offset : UInt32) -> String {
  if offset == 0U {
    a
  } else {
    "(\{a} + \{offset.reinterpret_as_int()})"
  }
}

// --- expressions ----------------------------------------------------------

///|
fn const_text(cv : ConstVal) -> String {
  match cv {
    I32V(v) => v.to_string()
    I64V(v) => "\{v}L"
    // Floats are emitted as their bits and reinterpreted rather than as decimal
    // literals: a literal would have to survive a printer, and the one thing a
    // decompiler must not do is change a NaN payload or the sign of a zero while
    // formatting.
    F32V(bits) => "Float::reinterpret_from_int(\{bits.reinterpret_as_int()})"
    F64V(bits) =>
      "Int64::reinterpret_as_double(\{bits.reinterpret_as_int64()}L)"
  }
}

///|
/// The operator for a binary operation, or `""` when there is none.
fn bin_symbol(k : BinKind) -> String {
  match k {
    Eq => "=="
    Ne => "!="
    LtS => "<"
    GtS => ">"
    LeS => "<="
    GeS => ">="
    Add => "+"
    Sub => "-"
    Mul => "*"
    // Only reachable for floats: an integer division always goes through a
    // helper, so the symbol is never used for one.
    DivS => "/"
    And => "&"
    Or => "|"
    Xor => "^"
    _ => ""
  }
}

///|
/// The helper that implements an integer binary operation MoonBit does not share,
/// or `""` when the operator is enough.
fn bin_helper(t : ValType, k : BinKind) -> String {
  let p = if vt_eq(t, I32) { "i32" } else { "i64" }
  let name = match k {
    DivS => "div_s"
    DivU => "div_u"
    RemS => "rem_s"
    RemU => "rem_u"
    Shl => "shl"
    ShrS => "shr_s"
    ShrU => "shr_u"
    Rotl => "rotl"
    Rotr => "rotr"
    Min => "min_s"
    Max => "max_s"
    LtU => "lt_u"
    GtU => "gt_u"
    LeU => "le_u"
    GeU => "ge_u"
    _ => ""
  }
  if name == "" {
    ""
  } else {
    "\{p}_\{name}"
  }
}

///|
/// A method receiver cannot be a bare integer literal. MoonBit reads
/// `63.to_int64()` as the float `63.` followed by an identifier, which is a
/// parse error rather than a conversion. Parenthesise literals only; an
/// identifier or an already-parenthesised expression is left as it is, so the
/// generated code stays readable everywhere else.
fn recv(x : String) -> String {
  match x.get_char(0) {
    Some(c) => {
      let n = c.to_int()
      if (n >= 48 && n <= 57) || n == 45 {
        "(\{x})"
      } else {
        x
      }
    }
    None => x
  }
}

///|
fn conv_text(
  from : ValType,
  to : ValType,
  mode : ConvMode,
  x : String,
) -> String {
  let is_f32_from = vt_eq(from, F32)
  let is_f32_to = vt_eq(to, F32)
  let is_i32_from = vt_eq(from, I32)
  let dst = if vt_eq(to, I32) { "i32" } else { "i64" }
  let src = if is_f32_from { "f32" } else { "f64" }
  let fdst = if is_f32_to { "f32" } else { "f64" }
  let src_i = if is_i32_from { "i32" } else { "i64" }
  match mode {
    Wrap => "(\{recv(x)}.to_int())"
    ExtendS => "(\{recv(x)}.to_int64())"
    ExtendU => "i64_extend_i32_u(\{x})"
    Demote => "Float::from_double(\{x})"
    Promote => "(\{recv(x)}.to_double())"
    Reinterpret =>
      if is_f32_from {
        "(\{recv(x)}.reinterpret_as_int())"
      } else if is_f32_to {
        "Float::reinterpret_from_int(\{x})"
      } else if vt_eq(from, F64) {
        "(\{recv(x)}.reinterpret_as_int64())"
      } else {
        "Int64::reinterpret_as_double(\{x})"
      }
    ConvertS =>
      if is_f32_to {
        if is_i32_from {
          "Float::from_int(\{x})"
        } else {
          "Float::from_int64(\{x})"
        }
      } else if is_i32_from {
        "(\{recv(x)}.to_double())"
      } else {
        "(\{recv(x)}.to_double())"
      }
    // The suffix names the *source* integer type: `f64.convert_i32_u` is
    // `f64_convert_i32_u`, and using the destination there would produce a
    // function that does not exist.
    ConvertU => "\{fdst}_convert_\{src_i}_u(\{x})"
    TruncS => "\{dst}_trunc_\{src}_s(\{x})"
    TruncU => "\{dst}_trunc_\{src}_u(\{x})"
    TruncSatS => "\{dst}_trunc_sat_\{src}_s(\{x})"
    TruncSatU => "\{dst}_trunc_sat_\{src}_u(\{x})"
  }
}

///|
/// True when an expression produces a MoonBit `Bool` rather than an `Int`.
///
/// wasm has no boolean type: a comparison leaves an i32 on the stack, and that
/// i32 can be stored, returned or added. MoonBit's comparison operators produce
/// `Bool`, so the two spellings are not interchangeable and the emitter has to
/// know which side of the boundary it is on:
///
/// * in a condition (`if`, `match`, `select`) the `Bool` is what is wanted, and
///   `cond_text` uses it directly, which is what makes the output readable;
/// * anywhere else the value has to be an `Int`, so `expr_text` converts it back
///   with `if ... { 1 } else { 0 }`.
fn is_bool_expr(e : Expr) -> Bool {
  match e {
    EBin(_, k, _, _) =>
      match k {
        Eq | Ne | LtS | GtS | LeS | GeS | LtU | GtU | LeU | GeU => true
        _ => false
      }
    EUn(_, Eqz, _) => true
    _ => false
  }
}

///|
/// An expression in a position that wants a `Bool`.
fn Emit::cond(self : Emit, e : Expr) -> String {
  if is_bool_expr(e) {
    // Straight through: this is the case that makes `if a < b {` readable.
    self.expr_raw(e)
  } else {
    "(\{self.expr(e)} != 0)"
  }
}

///|
fn Emit::expr(self : Emit, e : Expr) -> String {
  if is_bool_expr(e) {
    // An i32 that came from a comparison, used where a number is wanted.
    let c = self.cond(e)
    return "(if \{c} { 1 } else { 0 })"
  }
  self.expr_raw(e)
}

///|
fn Emit::expr_raw(self : Emit, e : Expr) -> String {
  match e {
    EConst(cv) => const_text(cv)
    ELocal(i) => self.local_of(i)
    EGlobal(i) => "g\{i}.val"
    ETemp(k) => self.names.of(k)
    EParam(k) => "in\{k}"
    ELoad(op, a) =>
      "mem.\{mem_method(op)}(\{addr_text(self.expr(a), op.offset)})"
    EBin(t, k, a, b) => {
      let x = self.expr(a)
      let y = self.expr(b)
      let h = if vt_eq(t, F32) || vt_eq(t, F64) {
        let bits = if vt_eq(t, F32) { "f32" } else { "f64" }
        match k {
          Min => "\{bits}_min"
          Max => "\{bits}_max"
          Copysign => "\{bits}_copysign"
          _ => ""
        }
      } else {
        bin_helper(t, k)
      }
      if h != "" {
        "\{h}(\{x}, \{y})"
      } else {
        "(\{x} \{bin_symbol(k)} \{y})"
      }
    }
    EUn(t, k, a) => {
      let x = self.expr(a)
      match k {
        Eqz => "(\{x} == 0)"
        Clz =>
          if vt_eq(t, I64) {
            "i64_clz(\{x})"
          } else {
            "(\{recv(x)}.clz())"
          }
        Ctz =>
          if vt_eq(t, I64) {
            "i64_ctz(\{x})"
          } else {
            "(\{recv(x)}.ctz())"
          }
        Popcnt =>
          if vt_eq(t, I64) {
            "i64_popcnt(\{x})"
          } else {
            "(\{recv(x)}.popcnt())"
          }
        Abs =>
          if vt_eq(t, F32) {
            "f32_abs(\{x})"
          } else if vt_eq(t, F64) {
            "f64_abs(\{x})"
          } else if vt_eq(t, I64) {
            "(\{recv(x)}.abs())"
          } else {
            // `i32.abs` of MIN is MIN in wasm — it wraps, it does not trap — and
            // the subtraction says so.
            "(if \{x} < 0 { 0 - \{x} } else { \{x} })"
          }
        Neg =>
          if vt_eq(t, F32) {
            "f32_neg(\{x})"
          } else if vt_eq(t, F64) {
            "f64_neg(\{x})"
          } else {
            "(-\{x})"
          }
        Ceil => "(\{recv(x)}.ceil())"
        Floor => "(\{recv(x)}.floor())"
        Trunc => "(\{recv(x)}.trunc())"
        Nearest =>
          if vt_eq(t, F32) {
            "f32_nearest(\{x})"
          } else {
            "f64_nearest(\{x})"
          }
        Sqrt => "(\{recv(x)}.sqrt())"
        Extend8S =>
          if vt_eq(t, I64) {
            "i64_extend8_s(\{x})"
          } else {
            "i32_extend8_s(\{x})"
          }
        Extend16S =>
          if vt_eq(t, I64) {
            "i64_extend16_s(\{x})"
          } else {
            "i32_extend16_s(\{x})"
          }
        Extend32S => "i64_extend32_s(\{x})"
      }
    }
    // The IR stores the conversion as (to, from) — see `s.push(EConv(to, from, ...))`
    // in the simulator — which is the opposite of how it reads best here.
    EConv(to, from, mode, a) => conv_text(from, to, mode, self.expr(a))
    ECall(f, args) => {
      let b = StringBuilder()
      // Imported functions are separate: they are not part of the module, and the
      // generated `host.mbt` names them `h{i}` so that a reader can see which
      // calls leave the module.
      if f < self.m.imported_func_count() {
        b.write_string("h\{f}(")
      } else {
        b.write_string("\{func_name(f)}(")
      }
      let mut first = true
      for a in args {
        if !first {
          b.write_string(", ")
        }
        b.write_string(self.expr(a))
        first = false
      }
      b.write_string(")")
      b.to_string()
    }
    // The callee is not known until run time, so the call goes through the
    // dispatcher generated for this type index: it bounds-checks the index,
    // rejects an uninitialised slot, checks the signature, and only then calls.
    ECallIndirect(t, i, args) => {
      let b = StringBuilder()
      b.write_string("__ml_indirect_t\{t}(")
      b.write_string(self.expr(i))
      for a in args {
        b.write_string(", ")
        b.write_string(self.expr(a))
      }
      b.write_string(")")
      b.to_string()
    }
    ESelect(a, b, c) =>
      "(if \{self.cond(c)} { \{self.expr(a)} } else { \{self.expr(b)} })"
    EMemorySize => "mem.size()"
    EMemoryGrow(a) => "mem.grow(\{self.expr(a)})"
  }
}

// --- statements -----------------------------------------------------------

///|
fn Emit::stmt(self : Emit, s : Stmt, blk : Int32) -> String {
  match s {
    SLocal(i, e) => "\{self.lname(i)} = \{self.expr(e)}"
    SGlobal(i, e) => "g\{i}.val = \{self.expr(e)}"
    STemp(k, e) => {
      let t = temp_ty(self.fs, blk, k)
      "\{self.names.bind(k, t)} = \{self.expr(e)}"
    }
    SStore(op, a, v) =>
      "mem.\{mem_method(op)}(\{addr_text(self.expr(a), op.offset)}, \{self.expr(v)})"
    SEval(e) => "ignore(\{self.expr(e)})"
    // The structurer pulls `if` conditions out of the statement list and turns
    // them into the opening of the two arms; one that survives is a condition
    // nothing could recover, and the comment says so rather than pretending.
    SIf(e) => "// if (\{self.expr(e)})"
    SBr(_, _) | SBrIf(_, _, _) | SBrTable(_, _, _, _) =>
      // Every branch becomes a `break`, a `continue` or a `brk` write. One that
      // reaches here means the walker missed a construct; trapping beats
      // emitting a `continue` that leaves the wrong loop.
      "trap(\"unstructured branch survived structuring\")"
    SReturn(vs) =>
      if vs.length() == 0 {
        "return"
      } else {
        "return \{self.expr(vs[0])}"
      }
    SUnreachable => "trap(\"unreachable\")"
  }
}

///|
/// The type the analysis recorded for temp `k` of block `b`.
///
/// Per block, not per function: temp numbers restart in every block, so the same
/// number can be an `Int` in one block and an `Int64` in the next. A number the
/// block never declared falls back to `Int` — that would be an analysis bug, and
/// it shows up as a wrong value rather than as a build error.
fn temp_ty(fs : FuncStack, b : Int32, k : Int32) -> ValType {
  if b < 0 || b >= fs.blocks.length() {
    return I32
  }
  let ts = fs.blocks[b].temp_types
  if k < 0 || k >= ts.length() {
    I32
  } else {
    ts[k]
  }
}

// --- control flow ---------------------------------------------------------

///|
/// True when something inside `n` leaves the loop it is in — a `break` or an
/// unwind — without counting what a *nested* loop's `break` does, because that
/// one only leaves the nested loop.
fn exits_loop(n : Node) -> Bool {
  match n {
    NBreak | NUnwind(_) => true
    NSeq(xs) => any_exits(xs)
    NWhileBrk(_, xs) => any_exits(xs)
    NWhileLoop(_, xs) => any_exits(xs)
    NIf(_, a, b) => any_exits(a) || any_exits(b)
    NSwitch(_, arms, dflt) => {
      let mut any = exits_loop(dflt)
      for a in arms {
        if exits_loop(a) {
          any = true
        }
      }
      any
    }
    _ => false
  }
}

///|
fn any_exits(xs : Array[Node]) -> Bool {
  let mut any = false
  for x in xs {
    if exits_loop(x) {
      any = true
    }
  }
  any
}

///|
/// True when control cannot reach the end of this node.
///
/// Used to stop emitting: the structurer leaves a guard after a construct whose
/// body already returned or broke, which is correct but unreachable, and an
/// unreachable statement is a warning in every build of the generated package.
/// Dropping it changes nothing observable — it is unreachable by construction —
/// and it keeps the output clean enough to read.
fn terminal(n : Node) -> Bool {
  match n {
    NReturn(_) | NTrap | NBreak | NContinue | NUnwind(_) | NSwitch(_, _, _) =>
      match n {
        NSwitch(_, arms, dflt) => {
          let mut all = terminal(dflt)
          for a in arms {
            if !terminal(a) {
              all = false
            }
          }
          all
        }
        _ => true
      }
    // `while true` never ends on its own; it ends when something inside breaks
    // out. A body that always returns, continues or unwinds, and that breaks
    // nowhere, leaves no way out at all — and nothing after the loop is
    // reachable. Only that case is claimed here, because the other direction is
    // the one that would silently drop live code.
    NWhileBrk(_, xs) | NWhileLoop(_, xs) => seq_terminal(xs) && !any_exits(xs)
    NSeq(xs) =>
      if xs.length() == 0 {
        false
      } else {
        terminal(xs[xs.length() - 1])
      }
    NIf(_, a, b) => {
      let mut all = a.length() > 0 && b.length() > 0
      if a.length() > 0 {
        if !terminal(a[a.length() - 1]) {
          all = false
        }
      }
      if b.length() > 0 {
        if !terminal(b[b.length() - 1]) {
          all = false
        }
      }
      all
    }
    _ => false
  }
}

///|
fn seq_terminal(xs : Array[Node]) -> Bool {
  if xs.length() == 0 {
    false
  } else {
    terminal(xs[xs.length() - 1])
  }
}

// --- what the emitted text reads ------------------------------------------

// Two questions get the same answer from this walk: is a name ever *read*, and
// therefore does it need its real name rather than an underscore-prefixed one.
//
// The walk stops where the emitter stops — after a node control cannot leave —
// so a read in code that never gets printed does not count. Counting one is what
// leaves an unused declaration in the output; missing one is an unbound name.
// The tree is the same one the emitter walks, so walking it the same way keeps
// the two ends agreeing.

///|
fn scan_reads(n : Node, locals : Array[Bool], temps : Array[Bool]) -> Unit {
  match n {
    NSeq(xs) => scan_reads_seq(xs, locals, temps)
    NWhileBrk(_, xs) => scan_reads_seq(xs, locals, temps)
    NWhileLoop(_, xs) => scan_reads_seq(xs, locals, temps)
    NLeaf(stmts, _) =>
      for s in stmts {
        scan_stmt(s, locals, temps)
      }
    NIf(c, a, b) => {
      scan_expr(c, locals, temps)
      scan_reads_seq(a, locals, temps)
      scan_reads_seq(b, locals, temps)
    }
    NSwitch(idx, arms, dflt) => {
      scan_expr(idx, locals, temps)
      for a in arms {
        scan_reads(a, locals, temps)
      }
      scan_reads(dflt, locals, temps)
    }
    NReturn(vs) => scan_exprs(vs, locals, temps)
    NAssign(_, _, e) => scan_expr(e, locals, temps)
    NUnwind(_)
    | NContinue
    | NBreak
    | NTrap
    | NGuard(_, _)
    | NBrkReset
    | NEdge(_, _)
    | NComment(_) => ()
  }
}

///|
/// The nodes of a sequence that the emitter actually prints, which is all of
/// them up to the first one control cannot leave.
///
/// Every analysis below walks through this, for the same reason: a declaration
/// or a `mut` that only the dropped tail of a sequence needed is a warning in the
/// generated file, and `moon check` on the output has to stay clean.
fn live_nodes(xs : Array[Node]) -> Array[Node] {
  let out : Array[Node] = []
  let mut i = 0
  let mut done = false
  while i < xs.length() && !done {
    out.push(xs[i])
    if terminal(xs[i]) {
      done = true
    }
    i = i + 1
  }
  out
}

///|
fn scan_reads_seq(
  xs : Array[Node],
  locals : Array[Bool],
  temps : Array[Bool],
) -> Unit {
  for x in live_nodes(xs) {
    scan_reads(x, locals, temps)
  }
}

///|
fn scan_stmt(s : Stmt, locals : Array[Bool], temps : Array[Bool]) -> Unit {
  match s {
    // `SLocal(i, e)` *writes* `i`; only the right-hand side is a read.
    SLocal(_, e) | SGlobal(_, e) | SEval(e) | SIf(e) | STemp(_, e) =>
      scan_expr(e, locals, temps)
    SStore(_, a, v) => {
      scan_expr(a, locals, temps)
      scan_expr(v, locals, temps)
    }
    SBr(_, vs) | SReturn(vs) => scan_exprs(vs, locals, temps)
    SBrIf(_, vs, c) => {
      scan_expr(c, locals, temps)
      scan_exprs(vs, locals, temps)
    }
    SBrTable(_, _, vs, c) => {
      scan_expr(c, locals, temps)
      scan_exprs(vs, locals, temps)
    }
    SUnreachable => ()
  }
}

///|
fn scan_exprs(
  xs : Array[Expr],
  locals : Array[Bool],
  temps : Array[Bool],
) -> Unit {
  for x in xs {
    scan_expr(x, locals, temps)
  }
}

///|
fn scan_expr(e : Expr, locals : Array[Bool], temps : Array[Bool]) -> Unit {
  match e {
    ELocal(i) => if i >= 0 && i < locals.length() { locals[i] = true }
    ETemp(t) => if t >= 0 && t < temps.length() { temps[t] = true }
    ELoad(_, a) => scan_expr(a, locals, temps)
    EBin(_, _, a, b) => {
      scan_expr(a, locals, temps)
      scan_expr(b, locals, temps)
    }
    EUn(_, _, a) => scan_expr(a, locals, temps)
    EConv(_, _, _, a) => scan_expr(a, locals, temps)
    ECall(_, args) => scan_exprs(args, locals, temps)
    ECallIndirect(_, i, args) => {
      scan_expr(i, locals, temps)
      scan_exprs(args, locals, temps)
    }
    ESelect(a, b, c) => {
      scan_expr(a, locals, temps)
      scan_expr(b, locals, temps)
      scan_expr(c, locals, temps)
    }
    EMemoryGrow(a) => scan_expr(a, locals, temps)
    EConst(_) | EGlobal(_) | EParam(_) | EMemorySize => ()
  }
}

///|
fn Emit::seq(self : Emit, xs : Array[Node], level : Int32) -> String {
  let b = StringBuilder()
  let mut i = 0
  let mut done = false
  while i < xs.length() && !done {
    let x = xs[i]
    b.write_string(self.node(x, level))
    if terminal(x) {
      done = true
    }
    i = i + 1
  }
  b.to_string()
}

///|
fn Emit::node(self : Emit, n : Node, level : Int32) -> String {
  let pad = indent(level)
  let b = StringBuilder()
  match n {
    NSeq(xs) => b.write_string(self.seq(xs, level))
    NLeaf(stmts, blk) => {
      b.write_string("\{pad}// b\{blk}\n")
      for s in stmts {
        b.write_string("\{pad}\{self.stmt(s, blk)}\n")
      }
    }
    NWhileBrk(_, xs) => {
      b.write_string("\{pad}while true {\n")
      b.write_string(self.seq(xs, level + 1))
      if !seq_terminal(xs) {
        b.write_string("\{pad}  break\n")
      }
      b.write_string("\{pad}}\n")
    }
    NWhileLoop(c, xs) => {
      b.write_string("\{pad}while true {\n")
      b.write_string(self.seq(xs, level + 1))
      if !seq_terminal(xs) {
        b.write_string("\{pad}  if brk != \{c} { break }\n")
        b.write_string("\{pad}  brk = -1\n")
      }
      b.write_string("\{pad}}\n")
    }
    NIf(cond, a, b2) => {
      b.write_string("\{pad}if \{self.cond(cond)} {\n")
      b.write_string(self.seq(a, level + 1))
      if b2.length() > 0 {
        b.write_string("\{pad}} else {\n")
        b.write_string(self.seq(b2, level + 1))
      }
      b.write_string("\{pad}}\n")
    }
    NUnwind(c) => {
      b.write_string("\{pad}brk = \{c} // leave c\{c}\n")
      b.write_string("\{pad}break\n")
    }
    NContinue => b.write_string("\{pad}continue\n")
    NBreak => b.write_string("\{pad}break\n")
    NReturn(vs) =>
      if vs.length() == 0 {
        b.write_string("\{pad}return\n")
      } else {
        b.write_string("\{pad}return \{self.expr(vs[0])}\n")
      }
    NTrap => b.write_string("\{pad}trap(\"unreachable\")\n")
    NSwitch(idx, arms, dflt) => {
      b.write_string("\{pad}match \{self.expr(idx)} {\n")
      let mut i = 0
      for a in arms {
        b.write_string("\{pad}  \{i} => {\n")
        b.write_string(self.node(a, level + 2))
        b.write_string("\{pad}  }\n")
        i = i + 1
      }
      b.write_string("\{pad}  _ => {\n")
      b.write_string(self.node(dflt, level + 2))
      b.write_string("\{pad}  }\n\{pad}}\n")
    }
    NGuard(child, cont) => {
      b.write_string("\{pad}if brk >= 0 {\n")
      b.write_string("\{pad}  if brk == \{child} { brk = -1 }\n")
      if cont >= 0 {
        b.write_string(
          "\{pad}  else if brk == \{cont} { brk = -1; continue }\n",
        )
      }
      b.write_string("\{pad}  else { break }\n\{pad}}\n")
    }
    NBrkReset => b.write_string("\{pad}brk = -1\n")
    NAssign(t, ty, e) => {
      let name = self.names.bind(t, ty)
      b.write_string("\{pad}\{name} = \{self.expr(e)}\n")
    }
    NEdge(from, to) => b.write_string("\{pad}// edge b\{from} -> b\{to}\n")
    NComment(s) => b.write_string("\{pad}// \{s}\n")
  }
  b.to_string()
}

// --- locals ---------------------------------------------------------------

///|
/// Which locals the function actually touches.
///
/// A wasm body declares all its locals up front and often leaves half of them
/// unused — a C compiler's spill slots, or a local that a later optimisation
/// removed. Emitting a `let mut l7 : Int = 0` that nothing reads puts an unused
/// local and a warning in the generated file, so only the used ones are declared.
fn mark_locals(n : Node, used : Array[Bool]) -> Unit {
  match n {
    NSeq(xs) =>
      for x in live_nodes(xs) {
        mark_locals(x, used)
      }
    NWhileBrk(_, xs) =>
      for x in live_nodes(xs) {
        mark_locals(x, used)
      }
    NWhileLoop(_, xs) =>
      for x in live_nodes(xs) {
        mark_locals(x, used)
      }
    NIf(cond, a, b) => {
      mark_expr(cond, used)
      for x in live_nodes(a) {
        mark_locals(x, used)
      }
      for x in live_nodes(b) {
        mark_locals(x, used)
      }
    }
    NLeaf(stmts, _) =>
      for s in stmts {
        mark_stmt(s, used)
      }
    NReturn(vs) =>
      for e in vs {
        mark_expr(e, used)
      }
    NSwitch(idx, arms, dflt) => {
      mark_expr(idx, used)
      for a in arms {
        mark_locals(a, used)
      }
      mark_locals(dflt, used)
    }
    NAssign(_, _, e) => mark_expr(e, used)
    _ => ()
  }
}

///|
/// Which locals the body writes, which is what decides whether a parameter needs
/// a mutable copy.
fn assigned_locals(n : Node, set : Array[Bool]) -> Unit {
  match n {
    NSeq(xs) =>
      for x in live_nodes(xs) {
        assigned_locals(x, set)
      }
    NWhileBrk(_, xs) =>
      for x in live_nodes(xs) {
        assigned_locals(x, set)
      }
    NWhileLoop(_, xs) =>
      for x in live_nodes(xs) {
        assigned_locals(x, set)
      }
    NIf(_, a, b) => {
      for x in live_nodes(a) {
        assigned_locals(x, set)
      }
      for x in live_nodes(b) {
        assigned_locals(x, set)
      }
    }
    NLeaf(stmts, _) =>
      for s in stmts {
        match s {
          SLocal(i, _) => if i >= 0 && i < set.length() { set[i] = true }
          _ => ()
        }
      }
    NSwitch(_, arms, dflt) => {
      for a in arms {
        assigned_locals(a, set)
      }
      assigned_locals(dflt, set)
    }
    _ => ()
  }
}

///|
/// True when every path through `n` ends in a `return` statement, which is what
/// the type checker needs from the last thing in a function that has a result.
/// A diverging loop is not enough: MoonBit does not prove `while true` never
/// ends, so a body that ends that way gets an explicit `trap`.
fn ends_with_return(n : Node) -> Bool {
  match n {
    NReturn(_) => true
    NSeq(xs) => xs.length() > 0 && ends_with_return(xs[xs.length() - 1])
    NIf(_, a, b) =>
      a.length() > 0 &&
      b.length() > 0 &&
      ends_with_return(a[a.length() - 1]) &&
      ends_with_return(b[b.length() - 1])
    NSwitch(_, arms, dflt) => {
      let mut all = ends_with_return(dflt)
      for a in arms {
        if !ends_with_return(a) {
          all = false
        }
      }
      all
    }
    _ => false
  }
}

///|
fn mark_expr(e : Expr, used : Array[Bool]) -> Unit {
  match e {
    ELocal(i) => if i >= 0 && i < used.length() { used[i] = true }
    ELoad(_, a) => mark_expr(a, used)
    EBin(_, _, a, b) => {
      mark_expr(a, used)
      mark_expr(b, used)
    }
    EUn(_, _, a) => mark_expr(a, used)
    EConv(_, _, _, a) => mark_expr(a, used)
    ECall(_, args) =>
      for a in args {
        mark_expr(a, used)
      }
    ECallIndirect(_, i, args) => {
      mark_expr(i, used)
      for a in args {
        mark_expr(a, used)
      }
    }
    ESelect(a, b, c) => {
      mark_expr(a, used)
      mark_expr(b, used)
      mark_expr(c, used)
    }
    EMemoryGrow(a) => mark_expr(a, used)
    _ => ()
  }
}

///|
fn mark_stmt(s : Stmt, used : Array[Bool]) -> Unit {
  match s {
    SLocal(i, e) => {
      if i >= 0 && i < used.length() {
        used[i] = true
      }
      mark_expr(e, used)
    }
    SGlobal(_, e) | SEval(e) | SIf(e) | STemp(_, e) => mark_expr(e, used)
    SStore(_, a, v) => {
      mark_expr(a, used)
      mark_expr(v, used)
    }
    SBr(_, vs) =>
      for e in vs {
        mark_expr(e, used)
      }
    SBrIf(_, vs, c) => {
      mark_expr(c, used)
      for e in vs {
        mark_expr(e, used)
      }
    }
    SBrTable(_, _, vs, c) => {
      mark_expr(c, used)
      for e in vs {
        mark_expr(e, used)
      }
    }
    SReturn(vs) =>
      for e in vs {
        mark_expr(e, used)
      }
    SUnreachable => ()
  }
}

// --- one function ---------------------------------------------------------

///|
/// The highest temporary number the tree mentions, or -1 if it mentions none.
///
/// The scratch declarations cannot be sized from the analysis (`fs.temps`):
/// the structurer allocates its own temporaries for block-entry values, at
/// `fs.temps + block * stride + slot`, deliberately past anything the stack
/// simulation hands out. The tree is what gets printed, so the tree is what the
/// declarations are sized from — and the bound then holds no matter how the
/// numbering changes later.
fn max_temp(n : Node) -> Int32 {
  match n {
    NSeq(xs) => max_temp_list(xs)
    NWhileBrk(_, xs) => max_temp_list(xs)
    NWhileLoop(_, xs) => max_temp_list(xs)
    NLeaf(stmts, _) => max_temp_stmts(stmts)
    NIf(c, a, b) =>
      max_temp3(max_temp_expr(c), max_temp_list(a), max_temp_list(b))
    NReturn(vs) => max_temp_exprs(vs)
    NSwitch(e, arms, dflt) =>
      max_temp3(max_temp_expr(e), max_temp_list(arms), max_temp(dflt))
    NAssign(t, _, e) => max_temp2(t, max_temp_expr(e))
    NUnwind(_)
    | NContinue
    | NBreak
    | NTrap
    | NGuard(_, _)
    | NBrkReset
    | NEdge(_, _)
    | NComment(_) => -1
  }
}

///|
fn max_temp2(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn max_temp3(a : Int32, b : Int32, c : Int32) -> Int32 {
  max_temp2(max_temp2(a, b), c)
}

///|
fn max_temp_list(xs : Array[Node]) -> Int32 {
  let mut r = -1
  for x in xs {
    r = max_temp2(r, max_temp(x))
  }
  r
}

///|
fn max_temp_stmts(xs : Array[Stmt]) -> Int32 {
  let mut r = -1
  for s in xs {
    r = max_temp2(r, max_temp_stmt(s))
  }
  r
}

///|
fn max_temp_stmt(s : Stmt) -> Int32 {
  match s {
    SLocal(_, e) | SGlobal(_, e) => max_temp_expr(e)
    STemp(t, e) => max_temp2(t, max_temp_expr(e))
    SStore(_, a, v) => max_temp2(max_temp_expr(a), max_temp_expr(v))
    SEval(e) | SIf(e) => max_temp_expr(e)
    SBr(_, vs) | SReturn(vs) => max_temp_exprs(vs)
    SBrIf(_, vs, c) => max_temp2(max_temp_exprs(vs), max_temp_expr(c))
    SBrTable(_, _, vs, c) => max_temp2(max_temp_exprs(vs), max_temp_expr(c))
    SUnreachable => -1
  }
}

///|
fn max_temp_exprs(xs : Array[Expr]) -> Int32 {
  let mut r = -1
  for x in xs {
    r = max_temp2(r, max_temp_expr(x))
  }
  r
}

///|
fn max_temp_expr(e : Expr) -> Int32 {
  match e {
    ETemp(t) => t
    ELoad(_, a) => max_temp_expr(a)
    EBin(_, _, a, b) => max_temp2(max_temp_expr(a), max_temp_expr(b))
    EUn(_, _, a) => max_temp_expr(a)
    EConv(_, _, _, a) => max_temp_expr(a)
    ECall(_, args) => max_temp_exprs(args)
    ECallIndirect(_, i, args) =>
      max_temp2(max_temp_expr(i), max_temp_exprs(args))
    ESelect(a, b, c) =>
      max_temp3(max_temp_expr(a), max_temp_expr(b), max_temp_expr(c))
    EMemoryGrow(a) => max_temp_expr(a)
    EConst(_) | ELocal(_) | EGlobal(_) | EParam(_) | EMemorySize => -1
  }
}

///|
/// True when the emitted body mentions `brk`.
///
/// Tested on the tree rather than on the rendered text: the text also contains
/// the word in comments (`// brk: 3 = c3`), and a `let mut brk` that nothing
/// reads is an unused-variable warning in the generated file. The walk follows
/// the same pruning as the emitter, so it counts exactly the statements that get
/// printed.
fn uses_brk(n : Node) -> Bool {
  match n {
    NUnwind(_) | NGuard(_, _) | NBrkReset => true
    NSeq(xs) => seq_uses_brk(xs)
    NWhileBrk(_, xs) => seq_uses_brk(xs)
    NWhileLoop(_, xs) => seq_uses_brk(xs)
    NIf(_, a, b) => seq_uses_brk(a) || seq_uses_brk(b)
    NSwitch(_, arms, dflt) => {
      let mut any = uses_brk(dflt)
      for a in arms {
        if uses_brk(a) {
          any = true
        }
      }
      any
    }
    NLeaf(_, _)
    | NReturn(_)
    | NTrap
    | NContinue
    | NBreak
    | NAssign(_, _, _)
    | NEdge(_, _)
    | NComment(_) => false
  }
}

///|
fn seq_uses_brk(xs : Array[Node]) -> Bool {
  let mut any = false
  for x in live_nodes(xs) {
    if uses_brk(x) {
      any = true
    }
  }
  any
}

///|
/// `fn f3(l0 : Int, l1 : Int64) -> Int { ... }`
fn Emit::func_text(self : Emit, idx : Int32, root : Node) -> String {
  let ft = match self.m.func_type(idx) {
    Some(t) => t
    None => return ""
  }
  let nparams = ft.params.length()
  let b = StringBuilder()
  let label = self.m.func_label(idx)
  let named = if label == "" { "" } else { " `" + label + "`" }
  b.write_string("\n///|\n/// wasm function \{idx}\{named}\n")
  b.write_string("pub fn \{func_name(idx)}(")
  let mut i = 0
  while i < nparams {
    if i > 0 {
      b.write_string(", ")
    }
    // The parameter is named `p0`; a body that writes it gets a mutable `l0`
    // copy below, because MoonBit parameters are not assignable. One the body
    // never reads and never writes becomes `_p0`, which says so.
    b.write_string("\{self.pname(i)} : \{ty_name(ft.params[i])}")
    i = i + 1
  }
  b.write_string(")")
  if ft.results.length() > 0 {
    b.write_string(" -> \{ty_name(ft.results[0])}")
  } else {
    b.write_string(" -> Unit")
  }
  b.write_string(" {\n")
  // Locals after the parameters, and only those the body touches: a wasm body
  // declares all of them up front and often leaves half unused, and an unused
  // `let mut` is a warning in every build of the output.
  let used = Array::make(self.env.locals.length(), false)
  let mut k = 0
  while k < nparams {
    used[k] = true
    k = k + 1
  }
  mark_locals(root, used)
  k = 0
  while k < self.env.locals.length() {
    if k < nparams {
      if self.assigned[k] {
        b.write_string(
          "  let mut \{self.lname(k)} : \{ty_name(self.env.locals[k])} = \{self.pname(k)}\n",
        )
      }
    } else if used[k] {
      // `mut` only where something is written. A wasm local that is read but
      // never stored holds its zero initialiser for the whole body, and a `mut`
      // that nothing stores to is a warning in the generated file.
      let mw = if self.assigned[k] { "mut " } else { "" }
      b.write_string(
        "  let \{mw}\{self.lname(k)} : \{ty_name(self.env.locals[k])} = \{zero_text(self.env.locals[k])}\n",
      )
    }
    k = k + 1
  }
  let body = self.node(root, 1)
  for d in self.names.decls {
    b.write_string("  \{d}\n")
  }
  // `brk` is declared only when the emitted text mentions it. A loop whose body
  // always returns or continues never reads or writes it, and an unused local is
  // a warning.
  if uses_brk(root) {
    b.write_string("  let mut brk : Int = -1\n")
  }
  b.write_string(body)
  if ft.results.length() > 0 && !ends_with_return(root) {
    // Every path either returns or diverges, but MoonBit does not prove that a
    // `while true` never ends, so a function whose last construct is a loop needs
    // something of the result type after it. This is the same trap the original
    // would hit if control ever got there, which it cannot.
    b.write_string("  trap(\"control reached the end of \{func_name(idx)}\")\n")
  }
  b.write_string("}\n")
  b.to_string()
}

// --- module assembly ------------------------------------------------------

///|
/// The address of a constant-offset data or element segment.
///
/// Only an `i32.const` is in the subset; a segment whose offset reads a global is
/// refused by the decoder rather than guessed at here.
fn const_offset(e : ConstExpr) -> Int32 {
  match e {
    I32Const(v) => v
    _ => 0
  }
}

///|
/// One byte string literal, for `init_bytes`.
fn bytes_literal(data : Bytes) -> String {
  let b = StringBuilder()
  b.write_string("b\"")
  let mut i = 0
  while i < data.length() {
    let v = data.at(i).to_int()
    b.write_string("\\x\{hex2(v)}")
    i = i + 1
  }
  b.write_string("\"")
  b.to_string()
}

///|
fn hex2(v : Int32) -> String {
  let b = StringBuilder()
  b.write_char(hex_digit((v >> 4) & 15))
  b.write_char(hex_digit(v & 15))
  b.to_string()
}

///|
/// One hex digit as a character. A lookup rather than `Char::from_int`, because
/// the escape in the generated literal has to be lowercase and exact.
fn hex_digit(v : Int32) -> Char {
  match v {
    0 => '0'
    1 => '1'
    2 => '2'
    3 => '3'
    4 => '4'
    5 => '5'
    6 => '6'
    7 => '7'
    8 => '8'
    9 => '9'
    10 => 'a'
    11 => 'b'
    12 => 'c'
    13 => 'd'
    14 => 'e'
    _ => 'f'
  }
}

///|

///|
/// `ExternalKind` does not implement `Eq` either, and an export of a memory or a
/// global has no wrapper to generate.
fn is_func_export(k : ExternalKind) -> Bool {
  match k {
    FuncKind => true
    _ => false
  }
}

///|
/// `moon.mod` for the generated package.
fn mod_text() -> String {
  "// Generated by moonlift. Edit freely: nothing regenerates over it unless you\n" +
  "// run `moonlift decompile` again.\nname = \"moonlift/generated\"\n\nversion = \"0.1.0\"\n\n" +
  "license = \"Apache-2.0\"\n\npreferred_target = \"wasm-gc\"\n"
}

///|
/// Text that is safe inside a MoonBit string literal.
///
/// Refusal messages are written by the decoder and may contain any punctuation;
/// a stray quote or backslash would end the literal early and turn a clear
/// refusal into a syntax error in the generated file.
fn escape_text(s : String) -> String {
  let b = StringBuilder()
  for c in s {
    match c {
      '"' => b.write_string("\\\"")
      '\\' => b.write_string("\\\\")
      '\n' => b.write_string(" ")
      _ => b.write_char(c)
    }
  }
  b.to_string()
}

///|
/// A stub for a function whose body could not be decompiled.
///
/// The signature is the real one, read from the type section, and the body
/// traps with the reason. Keeping the function rather than dropping it means a
/// caller still compiles and still has the right arity: the module runs
/// everywhere except through the code that was not recovered, and it stops
/// loudly at exactly that point instead of quietly returning a wrong value.
fn stub_text(m : Module, idx : Int32, why : String) -> String {
  let ft = match m.func_type(idx) {
    Some(t) => t
    None => return ""
  }
  let b = StringBuilder()
  b.write_string(
    "\n///|\n/// wasm function \{idx}: **not decompiled**, so every call traps.\n///\n/// \{escape_text(why)}\n",
  )
  b.write_string("pub fn \{func_name(idx)}(")
  let mut k = 0
  while k < ft.params.length() {
    if k > 0 {
      b.write_string(", ")
    }
    // The signature is kept, the body is a trap: nothing here reads an argument.
    b.write_string("_p\{k} : \{ty_name(ft.params[k])}")
    k = k + 1
  }
  b.write_string(")")
  if ft.results.length() > 0 {
    b.write_string(" -> \{ty_name(ft.results[0])}")
  } else {
    b.write_string(" -> Unit")
  }
  b.write_string(
    " {\n  trap(\"f\{idx} was not decompiled: \{escape_text(why)}\")\n}\n",
  )
  b.to_string()
}

// --- the function table ----------------------------------------------------

///|
/// True when `xs` already contains `v`.
fn mem_has(xs : Array[Int32], v : Int32) -> Bool {
  let mut found = false
  for x in xs {
    if x == v {
      found = true
    }
  }
  found
}

///|
/// Every type index a `call_indirect` in the module names, in first-use order.
///
/// The scan reads decoded bodies rather than analyses on purpose: a function
/// whose body is refused still needs its dispatcher, because another function
/// can reach the same type through the table.
fn indirect_type_indices(m : Module) -> Array[Int32] {
  let out : Array[Int32] = []
  let mut idx = m.imported_func_count()
  while idx < m.func_count() {
    match attempt(() => decode_func(m, idx)) {
      Ok(body) =>
        for r in body.instrs {
          match r.instr {
            CallIndirect(t) =>
              if t >= 0 && t < m.types.length() && !mem_has(out, t) {
                out.push(t)
              }
            _ => ()
          }
        }
      Err(_) => ()
    }
    idx = idx + 1
  }
  out
}

///|
/// A signature as a reader would write it, for comments and trap messages.
fn sig_text(ft : FuncType) -> String {
  let b = StringBuilder()
  b.write_string("(")
  let mut i = 0
  while i < ft.params.length() {
    if i > 0 {
      b.write_string(", ")
    }
    b.write_string(ty_name(ft.params[i]))
    i = i + 1
  }
  b.write_string(") -> ")
  if ft.results.length() == 0 {
    b.write_string("Unit")
  } else {
    b.write_string(ty_name(ft.results[0]))
  }
  b.to_string()
}

///|
/// True when two signatures are structurally equal.
///
/// wasm compares function types structurally, not by type index: a module may
/// hold two type entries with the same signature, and a `call_indirect` naming
/// one of them accepts a function declared with the other. Grouping dispatch
/// arms by index instead would reject calls the original accepted.
fn same_sig(a : FuncType, b : FuncType) -> Bool {
  same_types(a.params, b.params) && same_types(a.results, b.results)
}

///|
/// Every function in the index space whose signature equals `ft` — the exact set
/// that a `call_indirect (type t)` may legally reach.
fn funcs_with_sig(m : Module, ft : FuncType) -> Array[Int32] {
  let out : Array[Int32] = []
  let mut f = 0
  while f < m.func_count() {
    match m.func_type(f) {
      Some(t) => if same_sig(t, ft) { out.push(f) }
      None => ()
    }
    f = f + 1
  }
  out
}

///|
/// The dispatcher for one `call_indirect` type index.
///
/// The three run-time checks wasm performs are all here, in the order the spec
/// performs them: the index must be inside the table, the slot must not be null,
/// and the function's type must equal the expected one. The last is not a
/// comparison at run time — it is the set of arms below. A function whose
/// signature differs cannot match an arm, so it reaches the trap, which is
/// exactly what the engine would raise.
fn dispatcher_text(m : Module, t : Int32) -> String {
  let ft = m.types[t]
  let b = StringBuilder()
  b.write_string(
    "\n///|\n/// `call_indirect` naming type \{t}, `\{sig_text(ft)}`.\n",
  )
  b.write_string(
    "///\n/// One arm per function whose signature is structurally equal to type \{t};\n" +
    "/// every other function index falls through to the trap. That is the wasm\n" +
    "/// type check, written as a match instead of a run-time comparison.\n",
  )
  b.write_string("pub fn __ml_indirect_t\{t}(i : Int")
  let mut k = 0
  while k < ft.params.length() {
    b.write_string(", a\{k} : \{ty_name(ft.params[k])}")
    k = k + 1
  }
  b.write_string(")")
  if ft.results.length() > 0 {
    b.write_string(" -> \{ty_name(ft.results[0])}")
  } else {
    b.write_string(" -> Unit")
  }
  b.write_string(" {\n")
  let arms = funcs_with_sig(m, ft)
  if arms.length() == 0 {
    // Still check the index and the slot: a trap for "no such signature" that
    // fired before the bounds check would hide a real out-of-range call.
    b.write_string(
      "  ignore(__ml_table_at(i))\n  trap(\"call_indirect: no function has type \{sig_text(ft)}\")\n",
    )
  } else {
    b.write_string("  match __ml_table_at(i) {\n")
    for f in arms {
      let callee = if f < m.imported_func_count() {
        "h\{f}"
      } else {
        func_name(f)
      }
      b.write_string("    \{f} => \{callee}(")
      let mut j = 0
      while j < ft.params.length() {
        if j > 0 {
          b.write_string(", ")
        }
        b.write_string("a\{j}")
        j = j + 1
      }
      b.write_string(")\n")
    }
    b.write_string(
      "    _ => trap(\"call_indirect: table[\" + i.to_string() + \"] does not have type \{sig_text(ft)}\")\n",
    )
    b.write_string("  }\n")
  }
  b.write_string("}\n")
  b.to_string()
}

///|
/// The table itself, plus the two checks every indirect call starts with.
fn table_text(m : Module) -> String {
  if m.tables.length() == 0 {
    return ""
  }
  let n = m.tables[0].limits.min.reinterpret_as_int()
  let b = StringBuilder()
  b.write_string(
    "\n// The function table. wasm indexes it with an i32 at run time, so the\n" +
    "// decompiled module holds the same table, as function indices. `-1` is a slot\n" +
    "// no element segment filled: calling through it traps, as in the original.\n",
  )
  b.write_string("pub let __ml_table : Array[Int] = build_table()\n")
  b.write_string("\n///|\nfn build_table() -> Array[Int] {\n")
  b.write_string("  let t = Array::make(\{n}, -1)\n")
  let mut i = 0
  for e in m.elems {
    let off = const_offset(e.offset)
    let len = e.funcs.length()
    b.write_string("  // element segment \{i}: table[\{off}..\{off + len}]\n")
    b.write_string("  if \{off} < 0 || \{off} + \{len} > t.length() {\n")
    b.write_string(
      "    trap(\"element segment \{i} does not fit table[0..\{n})\")\n  }\n",
    )
    let mut k = 0
    for f in e.funcs {
      b.write_string("  t[\{off + k}] = \{f}\n")
      k = k + 1
    }
    i = i + 1
  }
  b.write_string("  t\n}\n")
  b.write_string(
    "\n///|\n/// The table slot at `i`, or a trap. An index outside the table and an\n" +
    "/// uninitialised slot are the two ways `call_indirect` fails before the type\n" +
    "/// check even starts.\n",
  )
  b.write_string("pub fn __ml_table_at(i : Int) -> Int {\n")
  b.write_string(
    "  if i < 0 || i >= __ml_table.length() {\n" +
    "    trap(\"call_indirect: index \" + i.to_string() + \" is outside table[0..\" + __ml_table.length().to_string() + \")\")\n" +
    "  }\n",
  )
  b.write_string("  let f = __ml_table[i]\n")
  b.write_string(
    "  if f < 0 {\n    trap(\"call_indirect: table[\" + i.to_string() + \"] is uninitialised\")\n  }\n",
  )
  b.write_string("  f\n}\n")
  b.to_string()
}

///|
/// The file holding the memory image, the globals and the import stubs.
fn module_text(m : Module, emitted : Array[Int32]) -> String {
  let b = StringBuilder()
  b.write_string(
    "// Module-level state: the linear memory, the globals, and the stubs for\n" +
    "// functions this module imported.\n",
  )
  let _ = emitted
  if m.memories.length() > 0 {
    b.write_string(
      "\n///|\n/// The module's linear memory, with its data segments already copied in.\n",
    )
    b.write_string(
      "pub let mem : Memory = make_memory()\n\n///|\nfn make_memory() -> Memory {\n",
    )
    let lim = m.memories[0].limits
    let max_pages = if lim.has_max {
      lim.max.reinterpret_as_int()
    } else {
      65536
    }
    b.write_string(
      "  let m = Memory::new(\{lim.min.reinterpret_as_int()}, \{max_pages})\n",
    )
    for d in m.datas {
      if d.bytes.length() > 0 {
        b.write_string(
          "  m.init_bytes(\{const_offset(d.offset)}, \{bytes_literal(d.bytes)})\n",
        )
      }
    }
    b.write_string("  m\n}\n")
  }
  if m.globals.length() > 0 {
    b.write_string(
      "\n// Globals. Every one is a `Ref`, mutable or not, so that a store is\n",
    )
    b.write_string(
      "// `g3.val = ...` and a load is `g3.val` — one spelling for both.\n",
    )
    let mut i = 0
    while i < m.globals.length() {
      let g = m.globals[i]
      b.write_string(
        "pub let g\{i} : Ref[\{ty_name(g.ty)}] = Ref(\{glob_init(g)})\n",
      )
      i = i + 1
    }
  }
  if m.tables.length() > 0 {
    b.write_string(table_text(m))
    for t in indirect_type_indices(m) {
      b.write_string(dispatcher_text(m, t))
    }
  }
  let imports = m.imported_func_count()
  if imports > 0 {
    b.write_string(
      "\n// Imported functions. Each one is a stub that traps: the original called\n" +
      "// into a host, and a host has to be supplied. Replace these bodies with the\n" +
      "// real implementations to run the module.\n",
    )
    let mut i = 0
    while i < imports {
      let ft = match m.func_type(i) {
        Some(t) => t
        None => continue_i()
      }
      b.write_string("\npub fn h\{i}(")
      let mut k = 0
      while k < ft.params.length() {
        if k > 0 {
          b.write_string(", ")
        }
        b.write_string("_l\{k} : \{ty_name(ft.params[k])}")
        k = k + 1
      }
      b.write_string(")")
      if ft.results.length() > 0 {
        b.write_string(" -> \{ty_name(ft.results[0])}")
      } else {
        b.write_string(" -> Unit")
      }
      b.write_string(" {\n  trap(\"import \{i} is not implemented\")\n}\n")
      i = i + 1
    }
  }
  b.write_string(
    "\n///|\n/// What wasm does at instantiation.\n///\n" +
    "/// A module's `start` function runs when the module is instantiated, and a\n" +
    "/// MoonBit package has no instantiation step. A host therefore calls this once,\n" +
    "/// before any export. Present even when there is nothing to run, so a host\n" +
    "/// never has to ask whether it should.\n",
  )
  b.write_string("pub fn moonlift_init() -> Unit {\n")
  if m.has_start && m.start_func >= 0 {
    let callee = if m.start_func < imports {
      "h\{m.start_func}"
    } else {
      func_name(m.start_func)
    }
    b.write_string(
      "  // start section: function \{m.start_func}\n  \{callee}()\n",
    )
  }
  b.write_string("}\n")
  b.to_string()
}

///|
/// The initial value of a global, as a MoonBit expression.
fn glob_init(g : Global) -> String {
  match g.init {
    I32Const(v) => v.to_string()
    I64Const(v) => "\{v}L"
    F32Const(bits) =>
      "Float::reinterpret_from_int(\{bits.reinterpret_as_int()})"
    F64Const(bits) =>
      "Int64::reinterpret_as_double(\{bits.reinterpret_as_int64()}L)"
    _ => zero_text(g.ty)
  }
}

///|
/// The `h{i}()` call above needs a value of the right shape; this keeps the loop
/// body total without an early `return` from the file builder.
fn continue_i() -> FuncType {
  { params: [], results: [], }
}

///|
/// One wrapper per exported function, because an export is a name, not a body:
/// two exports can name the same function, and the wrapper is what makes the
/// generated module callable the way the original was.
fn exports_text(m : Module, emitted : Array[Int32]) -> String {
  let b = StringBuilder()
  b.write_string(
    "// Exports. Each one calls the generated body, so the entry points have the\n",
  )
  b.write_string("// names the original module published.\n")
  let imports = m.imported_func_count()
  let _ = emitted
  let mut n = 0
  for e in m.exports {
    if !is_func_export(e.kind) {
      continue
    }
    let ft = match m.func_type(e.index) {
      Some(t) => t
      None => continue
    }
    b.write_string("\n///|\npub fn \{sanitize(e.name)}(")
    let mut k = 0
    while k < ft.params.length() {
      if k > 0 {
        b.write_string(", ")
      }
      // The wrapper's own parameter is passed straight on, so it is always read.
      b.write_string("l\{k} : \{ty_name(ft.params[k])}")
      k = k + 1
    }
    b.write_string(")")
    if ft.results.length() > 0 {
      b.write_string(" -> \{ty_name(ft.results[0])}")
    } else {
      b.write_string(" -> Unit")
    }
    b.write_string(" {\n  ")
    if ft.results.length() > 0 {
      b.write_string("return ")
    }
    // An export of an imported function points at the import stub: the export
    // name was published by the original, so it has to exist here too.
    if e.index < imports {
      b.write_string("h\{e.index}(")
    } else {
      b.write_string("\{func_name(e.index)}(")
    }
    k = 0
    while k < ft.params.length() {
      if k > 0 {
        b.write_string(", ")
      }
      b.write_string("l\{k}")
      k = k + 1
    }
    b.write_string(")\n}\n")
    n = n + 1
  }
  b.to_string()
}

///|
/// Decompile a whole module into the files of a MoonBit package.
///
/// `runtime.mbt` is not among them: it is copied from this repository by the CLI,
/// which is the only layer that can read a file. Everything here is a pure
/// function of the module.
pub fn emit_package(m : Module) -> GenReport {
  let files : Array[GenFile] = []
  let emitted : Array[Int32] = []
  let refused : Array[(Int32, Diag)] = []
  let skipped : Array[(Int32, String)] = []
  let funcs = StringBuilder()
  funcs.write_string(
    "// Function bodies, recovered from the wasm input and structured back into\n" +
    "// `while` / `if` / `match`. Comments name the block each statement came from,\n" +
    "// so the output can be read against `moonlift disasm --struct`.\n" +
    "//\n// A function marked `not decompiled` is a stub: its signature is real, its body\n" +
    "// traps. Nothing that runs through it can silently return a wrong answer.\n",
  )
  let mut idx = m.imported_func_count()
  while idx < m.func_count() {
    match structure_func(m, idx) {
      Err(d) => {
        refused.push((idx, d))
        funcs.write_string(stub_text(m, idx, d.render()))
      }
      Ok(t) =>
        if t.skipped != "" {
          skipped.push((idx, t.skipped))
          funcs.write_string(stub_text(m, idx, t.skipped))
        } else {
          match t.refusal {
            Some(d) => {
              refused.push((idx, d))
              funcs.write_string(stub_text(m, idx, d.render()))
            }
            None =>
              match analyze_func(m, idx) {
                Err(d) => {
                  refused.push((idx, d))
                  funcs.write_string(stub_text(m, idx, d.render()))
                }
                Ok(fs) => {
                  let env = func_env(m, idx)
                  let assigned = Array::make(env.locals.length(), false)
                  assigned_locals(t.root, assigned)
                  let ntemps = max_temp(t.root) + 1
                  let treads = Array::make(
                    if ntemps < 1 {
                      1
                    } else {
                      ntemps
                    },
                    false,
                  )
                  let lreads = Array::make(env.locals.length(), false)
                  scan_reads(t.root, lreads, treads)
                  let em : Emit = {
                    m,
                    env,
                    fs,
                    names: new_names(ntemps, treads),
                    np: match m.func_type(idx) {
                      Some(ft) => ft.params.length()
                      None => 0
                    },
                    assigned,
                    reads: lreads,
                  }
                  let text = em.func_text(idx, t.root)
                  if text != "" {
                    funcs.write_string(text)
                    emitted.push(idx)
                  }
                }
              }
          }
        }
    }
    idx = idx + 1
  }
  files.push({ name: "moon.mod", text: mod_text(), })
  files.push({
    name: "moon.pkg",
    text: "// No dependencies: the generated package needs nothing\n// outside its own directory.\n",
  })
  files.push({ name: "module.mbt", text: module_text(m, emitted), })
  files.push({ name: "funcs.mbt", text: funcs.to_string(), })
  files.push({ name: "exports.mbt", text: exports_text(m, emitted), })
  let pages = if m.memories.length() > 0 {
    m.memories[0].limits.min.reinterpret_as_int()
  } else {
    0
  }
  let mut dbytes = 0
  for d in m.datas {
    dbytes = dbytes + d.bytes.length()
  }
  {
    files,
    emitted,
    refused,
    skipped,
    exports: m.export_count(FuncKind),
    memory_pages: pages,
    data_bytes: dbytes,
    globals: m.globals.length(),
    imports: m.imported_func_count(),
  }
}

///|
/// The report `decompile` prints. Everything in it is a fact about the files that
/// were just written, so a reader can tell at a glance whether the output covers
/// the module or only part of it.
pub fn gen_summary_text(
  r : GenReport,
  path : String,
  out_dir : String,
) -> String {
  let b = StringBuilder()
  b.write_string("\{path} -> \{out_dir}/\n")
  b.write_string(
    "functions  \{r.emitted.length()} emitted, \{r.refused.length()} refused, \{r.skipped.length()} skipped\n",
  )
  b.write_string("exports    \{r.exports}\n")
  b.write_string(
    "memory     \{r.memory_pages} page(s), \{r.data_bytes} data byte(s)\n",
  )
  b.write_string("globals    \{r.globals}\n")
  b.write_string("imports    \{r.imports}\n")
  let names = StringBuilder()
  for f in r.files {
    names.write_string(" \{f.name}")
  }
  names.write_string(" runtime.mbt")
  b.write_string("files     \{names.to_string()}\n")
  for (idx, d) in r.refused {
    b.write_string("  refused f\{idx}: \{d.render()}\n")
  }
  for (idx, why) in r.skipped {
    b.write_string("  skipped f\{idx}: \{why}\n")
  }
  b.write_string(
    "\nnext: cd \{out_dir} && moon check    (the emitted package depends on nothing)\n",
  )
  b.to_string()
}
