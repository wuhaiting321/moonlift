///|
/// Textual rendering of decoded instructions.
///
/// Two purposes, deliberately in one module because they must agree:
///
/// - `disassemble` is the human listing. It exists so that a person can see what
///   the decoder understood without recompiling the tool.
/// - `disassemble_ops` is the *machine* listing: one instruction per line, in
///   decode order. `script/verify_decode.js` compares it against wabt's
///   `wasm2wat` output instruction by instruction, which turns "we think the
///   opcode tables are right" into a number.
///
/// Both are pure functions of the IR, so the snapshot tests need no process.

///|
/// Two spaces per nesting level, as `.wat` convention has it.
fn indent(level : Int32) -> String {
  " ".repeat(level * 2)
}

///|
/// `(param i32 i32) (result i32)` — the part after the function name.
fn render_signature(t : FuncType?) -> String {
  let b = StringBuilder()
  match t {
    None => ()
    Some(ft) => {
      if ft.params.length() > 0 {
        b.write_string(" (param")
        for p in ft.params {
          b.write_string(" \{p.name()}")
        }
        b.write_string(")")
      }
      if ft.results.length() > 0 {
        b.write_string(" (result")
        for r in ft.results {
          b.write_string(" \{r.name()}")
        }
        b.write_string(")")
      }
    }
  }
  b.to_string()
}

///|
/// `(local i32 x3 i64)`. The binary format stores locals as `(count, type)`
/// runs, so printing the run count is closer to the truth than expanding it.
fn render_locals(code : Code) -> String {
  if code.locals.length() == 0 {
    return ""
  }
  let b = StringBuilder()
  b.write_string(" (local")
  for l in code.locals {
    b.write_string(" \{l.ty.name()}")
    if l.count > 1 {
      b.write_string(" x\{l.count}")
    }
  }
  b.write_string(")")
  b.to_string()
}

///|
/// Full `.wat`-style listing of every function in the module.
pub fn disassemble(m : Module, path : String) -> String raise ReadFail {
  let b = StringBuilder()
  b.write_string(";; moonlift disasm — \{path}\n")
  b.write_string(
    ";; \{m.imported_func_count()} imported, \{m.defined_func_count()} defined\n",
  )
  let mut idx : Int32 = 0
  while idx < m.func_count() {
    if idx < m.imported_func_count() {
      b.write_string(
        "\n;; import \{idx}: \{m.func_label(idx)}\{render_signature(m.func_type(idx))}\n",
      )
    } else {
      let sig = render_signature(m.func_type(idx))
      let locals = match m.code_of(idx) {
        Some(c) => render_locals(c)
        None => ""
      }
      b.write_string("\nfunc \{idx} \{m.func_label(idx)}\{sig}\{locals}\n")
      let body = decode_func(m, idx)
      // Start at one: the body sits inside the `func` header, as in `.wat`.
      let mut level : Int32 = 1
      for r in body.instrs {
        let close = match r.instr {
          End => true
          Else => true
          _ => false
        }
        if close && level > 0 {
          level = level - 1
        }
        b.write_string("\{indent(level)}\{r.instr.render()}\n")
        let open = match r.instr {
          Block(_) | Loop(_) | If(_) | Else => true
          _ => false
        }
        if open {
          level = level + 1
        }
      }
      if !body.is_complete() {
        b.write_string("\{indent(level)};; \{body.stop_note()}\n")
      }
    }
    idx = idx + 1
  }
  b.to_string()
}

///|
/// One instruction per line, prefixed by its function index: `12  i32.add`.
///
/// No indentation and no comments on purpose — a consumer that has to strip
/// decoration before comparing is a consumer that will compare the wrong thing.
pub fn disassemble_ops(m : Module) -> String raise ReadFail {
  let b = StringBuilder()
  b.write_string("; functions \{m.func_count()}\n")
  let mut idx : Int32 = 0
  while idx < m.func_count() {
    if idx >= m.imported_func_count() {
      let body = decode_func(m, idx)
      for r in body.instrs {
        b.write_string("\{idx} \{r.instr.render()}\n")
      }
      if !body.is_complete() {
        b.write_string("\{idx} ;partial \{body.stop_note()}\n")
      }
    }
    idx = idx + 1
  }
  b.to_string()
}

///|
/// Per-module decoding statistics: the numbers quoted in the README and in the
/// competition submission.
///
/// Two groups, decode and control flow. They are printed together because a
/// reader asking "how big is this module" wants both halves — the instruction
/// count says how much code there is, the block/loop count says how tangled it
/// is — and because keeping them one command means one invocation in
/// `demo.sh`.
pub fn disassemble_stats(m : Module) -> String raise ReadFail {
  let mut bodies : Int32 = 0
  let mut instrs : Int32 = 0
  let mut partial : Int32 = 0
  let mut max_nesting : Int32 = 0
  let notes : Array[String] = []
  let mut idx : Int32 = 0
  while idx < m.func_count() {
    if idx >= m.imported_func_count() {
      let body = decode_func(m, idx)
      bodies = bodies + 1
      instrs = instrs + body.len()
      let mut level : Int32 = 0
      for r in body.instrs {
        match r.instr {
          End => level = level - 1
          Block(_) | Loop(_) | If(_) => {
            level = level + 1
            if level > max_nesting {
              max_nesting = level
            }
          }
          _ => ()
        }
      }
      if !body.is_complete() {
        partial = partial + 1
        notes.push("  f\{idx} \{m.func_label(idx)}: \{body.stop_note()}")
      }
    }
    idx = idx + 1
  }
  let b = StringBuilder()
  b.write_string("bodies          \{bodies}\n")
  b.write_string("instructions    \{instrs}\n")
  b.write_string("max nesting     \{max_nesting}\n")
  b.write_string("partial bodies  \{partial}\n")
  for n in notes {
    b.write_string("\{n}\n")
  }
  // The control-flow block. Aggregate numbers only: `disasm --cfg` prints the
  // graphs themselves, and duplicating them here would make `--stats` unreadable
  // on the real 20 KB artifact.
  b.write_string(cfg_summary_text(m))
  // And the typed-stack block, for the same reason.
  b.write_string(stack_summary_text(m))
  b.to_string()
}

// --- Result-returning wrappers -------------------------------------------
//
// The CLI prints a diagnostic and moves on; it never wants an exception to
// escape. These three wrappers are the entire surface the CLI uses, which keeps
// the `raise`-based entry points available for tests and for embedding.

///|
pub fn disasm_text(m : Module, path : String) -> DecodeResult[String] {
  attempt(() => disassemble(m, path))
}

///|
pub fn disasm_ops_text(m : Module) -> DecodeResult[String] {
  attempt(() => disassemble_ops(m))
}

///|
pub fn disasm_stats_text(m : Module) -> DecodeResult[String] {
  attempt(() => disassemble_stats(m))
}
