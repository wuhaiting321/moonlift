// Deciding what to compare: which exports to call, and with what.
//
// The plan is data, not behaviour: `verify` writes it out and `script/verify.sh`
// feeds it to Node, which runs the *original* module and produces the expected
// values. Keeping the choice of arguments in MoonBit (rather than in the shell
// script) means the plan is deterministic, reproducible and testable, and it is
// the same on every backend.

///|
/// One call the harness should make.
pub struct PlannedCall {
  /// The export under the name the generated package uses (sanitised).
  name : String
  /// The export as the wasm module published it. Different from `name` when the
  /// original is a MoonBit keyword (`guard` → `e_guard`), and the reference
  /// engine only knows this one.
  wasm_name : String
  /// Result type, `i32` / `i64` / `f32` / `f64`. Empty when there is no result.
  ret : String
  /// The argument list as MoonBit source, e.g. `1, 2L, (0.5 : Float)`.
  mb_args : String
  /// The same arguments as JSON numbers, e.g. `1,2,0.5`. No brackets.
  js_args : String
}

///|
/// One imported memory, table or global, in the shape the reference engine has
/// to supply.
///
/// The generated package materialises these imports itself, so this exists for
/// one consumer only: `corpus/tools/oracle.js`, which cannot instantiate the
/// original without a host. A host object of the wrong size is not a
/// behavioural difference, it is a `LinkError` — and a `LinkError` reported as
/// "the decompiler disagrees" would be the worst possible bug in a differential
/// test.
pub struct HostImport {
  /// `memory`, `table` or `global`.
  kind : String
  /// `i32`, `i64`, `f32`, `f64` for a global, `funcref` for a table.
  ty : String
  /// Declared minimum: pages for a memory, slots for a table.
  min : Int32
  /// Declared maximum, or 65536 when the module sets none.
  max : Int32
  /// Whether a global import is mutable. Always false for memory and table.
  mutable_ : Bool
}

///|
pub struct CallPlan {
  calls : Array[PlannedCall]
  /// Exports nothing will be compared for, with the reason.
  skipped : Array[(String, String)]
  /// Whether the module has a `start` section, which the harness has to run
  /// before using the module (wasm runs it at instantiation).
  has_start : Bool
  /// Whether the harness has to call `moonlift_init()` at all: true when there
  /// is a `start` section, and also when a data or element segment is placed at
  /// a `global.get` — those are laid down there, because only the host knows the
  /// value, and wasm lays them down at instantiation whether or not `start`
  /// exists.
  needs_init : Bool
  /// The non-function imports, so the reference engine can build a host.
  host : Array[HostImport]
}

// --- argument pools -------------------------------------------------------
//
// Fixed values, not random ones: a failure has to be reproducible from the
// report alone, and a random seed that is printed but not re-runnable is worse
// than no randomness at all. The set is chosen so that each one is a boundary
// for some operator — zero, ±1, a value with both halves set, the i32 extremes,
// and the `MIN / -1` pair that traps.
//
// Every i64 value is exactly representable as a double, because that is how the
// harness hands it to Node. A value beyond 2^53 would reach `WebAssembly` rounded
// and the comparison would fail for a reason that has nothing to do with the
// decompiler.

///|
/// `(MoonBit literal, JSON number)` for one value.
type Pooled = (String, String)

///|
/// The closed pool, or its first few entries when the reference implementation
/// cannot be trusted to finish.
///
/// `--small` exists because a call that does not return is a fact about the
/// *original*, not about the decompiler: `fib.wasm`'s `fib` is exponential, so
/// `fib(255)` runs forever and the harness would hang on a call whose only
/// problem is the size of its argument. Cutting the pool down keeps those
/// fixtures comparable instead of excluded.
fn pool(t : ValType, small : Bool) -> Array[Pooled] {
  let all = full_pool(t)
  if !small {
    return all
  }
  let n = if all.length() < 5 { all.length() } else { 5 }
  let out : Array[Pooled] = []
  let mut i = 0
  while i < n {
    out.push(all[i])
    i = i + 1
  }
  out
}

///|
fn full_pool(t : ValType) -> Array[Pooled] {
  match t {
    I32 =>
      [
        ("0", "0"),
        ("1", "1"),
        ("2", "2"),
        ("3", "3"),
        ("7", "7"),
        ("-1", "-1"),
        ("-7", "-7"),
        ("255", "255"),
        ("-2147483648", "-2147483648"),
        ("2147483647", "2147483647"),
      ]
    I64 =>
      [
        ("0L", "0"),
        ("1L", "1"),
        ("-1L", "-1"),
        ("7L", "7"),
        ("-2147483648L", "-2147483648"),
        ("4294967296L", "4294967296"),
        ("9007199254740991L", "9007199254740991"),
      ]
    // A `Float` literal needs its type written down: `0.5` alone is a `Double`
    // and would not type-check against a `Float` parameter.
    F32 =>
      [
        ("(0.0 : Float)", "0"),
        ("(1.0 : Float)", "1"),
        ("(-1.0 : Float)", "-1"),
        ("(0.5 : Float)", "0.5"),
        ("(-2.25 : Float)", "-2.25"),
        ("(1024.5 : Float)", "1024.5"),
      ]
    F64 =>
      [
        ("0.0", "0"),
        ("1.0", "1"),
        ("-1.0", "-1"),
        ("0.5", "0.5"),
        ("-2.25", "-2.25"),
        ("1024.5", "1024.5"),
      ]
    V128 => []
  }
}

///|
fn type_name_text(t : ValType) -> String {
  match t {
    I32 => "i32"
    I64 => "i64"
    F32 => "f32"
    F64 => "f64"
    V128 => "v128"
  }
}

///|
/// The most arguments a planned call may take.
///
/// Four is a judgement, not a limit of the tool: the plan is a cartesian product
/// and its size is the product of the pools, so a five-argument function would
/// spend the whole budget on one export.
let max_plan_args : Int32 = 4

///|
/// The calls to make for one signature, at most `limit` of them.
///
/// Two series, because one of them alone is bad at this corpus. The first walks
/// the diagonal: argument `k` of call `t` is value `t mod pool_k`. The second
/// holds the first argument at a fixed non-zero value and lets the rest run.
///
/// A pure odometer — last argument fastest — spends its whole budget on the row
/// where every other argument is zero, and the fixtures here are accumulators:
/// `arith`'s `$i32_bin` runs every binary operator in sequence, so with `a = 0`
/// it reaches `div_s` by zero on the fourth operator and every call in the row
/// traps. The diagonal moves the arguments together and gets past that; the
/// anchored rows then cover the off-diagonal combinations, which is where a
/// division by something other than the dividend shows up.
fn calls_for(
  ft : FuncType,
  limit : Int32,
  small : Bool,
) -> Array[(String, String)] {
  let n = ft.params.length()
  if n == 0 {
    return [("", "")]
  }
  let pools : Array[Array[Pooled]] = []
  let mut widest = 1
  for p in ft.params {
    let pool_p = pool(p, small)
    if pool_p.length() > widest {
      widest = pool_p.length()
    }
    pools.push(pool_p)
  }
  let combos : Array[Array[Int32]] = []
  // Series 1: the diagonal.
  let mut t = 0
  while t < widest {
    let idx : Array[Int32] = []
    let mut k = 0
    while k < n {
      idx.push(t % pools[k].length())
      k = k + 1
    }
    combos.push(idx)
    t = t + 1
  }
  // Series 2: the first argument anchored away from zero, the rest counting.
  for anchor in [1, 4, 5, 9] {
    if combos.length() >= limit {
      break
    }
    if anchor >= pools[0].length() {
      continue
    }
    let idx : Array[Int32] = Array::make(n, 0)
    idx[0] = anchor
    let mut done = false
    while !done && combos.length() < limit {
      combos.push(idx.copy())
      let mut j = n - 1
      let mut carry = true
      while carry && j >= 1 {
        idx[j] = idx[j] + 1
        if idx[j] < pools[j].length() {
          carry = false
        } else {
          idx[j] = 0
          j = j - 1
        }
      }
      if carry || n == 1 {
        done = true
      }
    }
  }
  let out : Array[(String, String)] = []
  let mut c = 0
  while c < combos.length() && out.length() < limit {
    let mb = StringBuilder()
    let js = StringBuilder()
    let mut k = 0
    while k < n {
      if k > 0 {
        mb.write_string(", ")
        js.write_string(",")
      }
      let pair = pools[k][combos[c][k]]
      mb.write_string(pair.0)
      js.write_string(pair.1)
      k = k + 1
    }
    out.push((mb.to_string(), js.to_string()))
    c = c + 1
  }
  out
}

///|
fn contains_index(xs : Array[Int32], x : Int32) -> Bool {
  let mut found = false
  for y in xs {
    if y == x {
      found = true
    }
  }
  found
}

///|
/// Which calls to make, for the exports whose body was actually emitted.
///
/// Only emitted bodies are planned: a refused function became a trapping stub,
/// and comparing a stub against a working original would report a difference that
/// is already documented rather than a bug.
pub fn plan_calls(
  m : Module,
  emitted : Array[Int32],
  per_func : Int32,
  small : Bool,
) -> CallPlan {
  let calls : Array[PlannedCall] = []
  let skipped : Array[(String, String)] = []
  let limit = if per_func < 1 { 1 } else { per_func }
  for e in m.exports {
    if !is_func_export(e.kind) {
      continue
    }
    let name = sanitize(e.name)
    if e.index < m.imported_func_count() {
      skipped.push((e.name, "export is an import"))
      continue
    }
    if !contains_index(emitted, e.index) {
      skipped.push((e.name, "body not decompiled"))
      continue
    }
    let ft = match m.func_type(e.index) {
      Some(t) => t
      None => continue
    }
    if ft.results.length() != 1 {
      skipped.push((e.name, "no single result to compare"))
      continue
    }
    if ft.params.length() > max_plan_args {
      skipped.push((e.name, "more than \{max_plan_args} parameters"))
      continue
    }
    let mut unsupported = false
    for p in ft.params {
      if vt_eq(p, V128) {
        unsupported = true
      }
    }
    if unsupported {
      skipped.push((e.name, "v128 parameter"))
      continue
    }
    let results = calls_for(ft, limit, small)
    for r in results {
      calls.push({
        name,
        wasm_name: e.name,
        ret: type_name_text(ft.results[0]),
        mb_args: r.0,
        js_args: r.1,
      })
    }
  }
  {
    calls,
    skipped,
    has_start: m.has_start,
    needs_init: m.has_start || needs_instantiation(m),
    host: host_imports(m),
  }
}

///|
/// Whether `moonlift_init()` has work to do.
///
/// Every segment counts now, not just the ones placed at a `global.get`: the
/// emitter lays them all into whatever instance is bound when init runs, because
/// an imported memory or table does not exist before `moonlift_bind()`. A module
/// with a defined memory and a constant segment therefore also needs init — the
/// package no longer copies bytes at load time.
fn needs_instantiation(m : Module) -> Bool {
  for d in m.datas {
    if d.bytes.length() > 0 {
      return true
    }
  }
  if m.elems.length() > 0 {
    return true
  }
  for g in m.globals {
    if !g.imported && offset_is_global(g.init) {
      return true
    }
  }
  false
}

///|
/// The limits a host has to meet, per imported object.
fn host_imports(m : Module) -> Array[HostImport] {
  let out : Array[HostImport] = []
  let mut i = 0
  while i < m.imported_tables {
    let l = m.tables[i].limits
    out.push({
      kind: "table",
      ty: "funcref",
      min: l.min.reinterpret_as_int(),
      max: if l.has_max {
        l.max.reinterpret_as_int()
      } else {
        65536
      },
      mutable_: false,
    })
    i = i + 1
  }
  i = 0
  while i < m.imported_memories {
    let l = m.memories[i].limits
    out.push({
      kind: "memory",
      ty: "i32",
      min: l.min.reinterpret_as_int(),
      max: if l.has_max {
        l.max.reinterpret_as_int()
      } else {
        65536
      },
      mutable_: false,
    })
    i = i + 1
  }
  i = 0
  while i < m.imported_globals {
    let g = m.globals[i]
    out.push({
      kind: "global",
      ty: g.ty.name(),
      min: 0,
      max: 0,
      mutable_: g.mutable,
    })
    i = i + 1
  }
  out
}

// --- the plan as text -----------------------------------------------------

///|
/// One line per call, tab separated: the MoonBit name, the wasm name, the result
/// type, the MoonBit arguments, the JSON arguments.
///
/// Tabs because a MoonBit argument list contains spaces (`(0.5 : Float)`) and a
/// comma-separated format would then need quoting. Two names because they differ
/// exactly when sanitising had to rename an export, and the reference engine only
/// knows the original.
///
/// The first line may be `init`, which tells the harness to run the module's
/// `start` function before the first call — wasm does that at instantiation, and
/// a MoonBit package has no instantiation step.
pub fn plan_text(p : CallPlan) -> String {
  let b = StringBuilder()
  for h in p.host {
    b.write_string(
      "host\t\{h.kind}\t\{h.ty}\t\{h.min}\t\{h.max}\t\{if h.mutable_ { "mutable" } else { "immutable" }}\n",
    )
  }
  if p.needs_init {
    b.write_string("init\t-\t-\t-\t-\n")
  }
  for c in p.calls {
    b.write_string(
      "\{c.name}\t\{c.wasm_name}\t\{c.ret}\t\{c.mb_args}\t\{c.js_args}\n",
    )
  }
  b.to_string()
}

///|
/// The human summary `verify` prints.
pub fn plan_summary_text(
  p : CallPlan,
  path : String,
  out_dir : String,
) -> String {
  let b = StringBuilder()
  b.write_string("\{path} -> \{out_dir}/\n")
  b.write_string("calls      \{p.calls.length()} planned\n")
  b.write_string(
    "start      \{if p.has_start { "yes, run moonlift_init() first" } else if p.needs_init { "none, but segments wait for moonlift_init()" } else { "none" }}\n",
  )
  if p.skipped.length() > 0 {
    b.write_string("skipped    \{p.skipped.length()} export(s)\n")
    for s in p.skipped {
      b.write_string("  \{s.0}: \{s.1}\n")
    }
  }
  b.write_string(
    "\nnext: bash script/verify.sh (it asks Node for the expected values, writes the\n",
  )
  b.write_string("      test file, and runs it)\n")
  b.to_string()
}
