///|
/// Rendering of a decoded module as text.
///
/// This lives in `core` rather than in the CLI for a practical reason: the CLI
/// cannot construct enum values from another package (only match them), so any
/// formatting that needs `FuncKind` or `ValType` values must happen here. The
/// second reason is testability — the report is a pure function of the IR, so
/// the golden-output tests do not need to run a process.
///
/// Layout rules: one fact per line, fixed-width columns, no trailing spaces, and
/// every number is decimal. Deterministic output is what makes the snapshot
/// tests in `report_wbtest.mbt` worth having.

///|
fn pad_left(s : String, width : Int32) -> String {
  if s.length() >= width {
    s
  } else {
    " ".repeat(width - s.length()) + s
  }
}

///|
fn pad_right(s : String, width : Int32) -> String {
  if s.length() >= width {
    s
  } else {
    s + " ".repeat(width - s.length())
  }
}

///|
/// Shorten to `width` characters, marking the cut with `..`. Imported function
/// names are frequently longer than forty characters, and a table with ragged
/// columns is harder to scan than one with clipped names.
fn clip(s : String, width : Int32) -> String {
  if s.length() <= width {
    s
  } else if width <= 2 {
    s[:width].to_owned()
  } else {
    s[:width - 2].to_owned() + ".."
  }
}

///|
/// `name (size)` list for custom sections, e.g. `"name" (57), "producers" (42)`.
fn render_customs(customs : Array[Custom]) -> String {
  let parts : Array[String] = []
  for c in customs {
    parts.push("\"\{c.name}\" (\{c.size})")
  }
  parts.join(", ")
}

///|
/// Exports broken down by kind, skipping kinds with no entries.
fn render_export_breakdown(m : Module) -> String {
  if m.exports.length() == 0 {
    return "none"
  }
  let parts : Array[String] = []
  let funcs = m.export_count(FuncKind)
  if funcs > 0 {
    parts.push("func \{funcs}")
  }
  let tables = m.export_count(TableKind)
  if tables > 0 {
    parts.push("table \{tables}")
  }
  let mems = m.export_count(MemoryKind)
  if mems > 0 {
    parts.push("memory \{mems}")
  }
  let globals = m.export_count(GlobalKind)
  if globals > 0 {
    parts.push("global \{globals}")
  }
  parts.join(", ")
}

///|
/// Count exported names that are not representable as MoonBit identifiers.
/// Reported by `info` because the code generator has to rename them, and a user
/// comparing the report with the generated source needs to know that happened.
fn needs_rename(name : String) -> Bool {
  if name.length() == 0 {
    return true
  }
  let first = name.get_char(0).unwrap()
  let first_ok = (first >= 'a' && first <= 'z') ||
    (first >= 'A' && first <= 'Z') ||
    first == '_'
  if !first_ok {
    return true
  }
  let mut i = 1
  while i < name.length() {
    let c = name.get_char(i).unwrap()
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '_'
    if !ok {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// Number of exported names that would need sanitising in generated source.
pub fn rename_count(m : Module) -> Int32 {
  let mut n = 0
  for e in m.exports {
    if needs_rename(e.name) {
      n = n + 1
    }
  }
  n
}

///|
/// Max number of function rows printed before the table is truncated. A 5,000
/// function module is common; printing all of them buries the summary.
const MAX_FUNC_ROWS : Int32 = 28

///|
/// The `moonlift info` report.
///
/// `label` is the path the user passed; it is echoed so a report pasted into a
/// bug tracker identifies its own input.
pub fn report(m : Module, label : String) -> String {
  let b = StringBuilder()
  b.write_string("file      \{label} (\{m.size()} bytes)\n")
  b.write_string("format    WebAssembly binary, version 1 (MVP subset)\n")
  b.write_string("\nsections  \{m.sections.length()}\n")
  b.write_string(
    "  \{pad_left("id", 4)}  \{pad_right("name", 10)}  \{pad_left("offset", 8)}  \{pad_left("size", 8)}\n",
  )
  for s in m.sections {
    b.write_string(
      "  \{pad_left(s.id.to_uint().to_string(), 4)}  \{pad_right(section_name(s.id), 10)}  \{pad_left(s.offset.to_string(), 8)}  \{pad_left(s.size.to_string(), 8)}\n",
    )
  }
  b.write_string("\n")
  b.write_string("types     \{m.types.length()}\n")
  b.write_string(
    "imports   \{m.imported_func_count()} (all func; other import kinds are rejected)\n",
  )
  b.write_string(
    "functions \{m.defined_func_count()} defined, \{m.imported_func_count()} imported\n",
  )
  b.write_string("tables    \{m.tables.length()}\n")
  b.write_string("memories  \{m.memories.length()}\n")
  for mem in m.memories {
    b.write_string("            \{mem.limits.render()}\n")
  }
  b.write_string("globals   \{m.globals.length()}\n")
  b.write_string(
    "exports   \{m.exports.length()} (\{render_export_breakdown(m)})\n",
  )
  if m.has_start {
    b.write_string("start     \{m.func_label(m.start_func)}\n")
  } else {
    b.write_string("start     none\n")
  }
  b.write_string("elements  \{m.elems.length()}\n")
  b.write_string(
    "code      \{m.codes.length()} bodies, \{m.code_bytes()} bytes, max \{m.max_local_count()} locals\n",
  )
  b.write_string(
    "data      \{m.datas.length()} segments, \{m.data_bytes()} bytes\n",
  )
  b.write_string("custom    \{m.customs.length()}")
  if m.customs.length() > 0 {
    b.write_string(": \{render_customs(m.customs)}")
  }
  b.write_string("\n")
  // Function table: imports first, matching the wasm index space.
  let total = m.func_count()
  if total > 0 {
    b.write_string("\nfunctions\n")
    b.write_string(
      "  \{pad_left("#", 4)}  \{pad_right("name", 26)}  \{pad_right("signature", 32)}  \{pad_left("locals", 6)}  \{pad_left("bytes", 6)}\n",
    )
    let shown = if total > MAX_FUNC_ROWS { MAX_FUNC_ROWS } else { total }
    let mut i = 0
    while i < shown {
      let idx = i
      let label_i = clip(m.func_label(idx), 26)
      let sig = clip(signature_of(m.func_type(idx)), 32)
      let locals_s = if idx < m.imported_func_count() {
        "-"
      } else {
        match m.code_of(idx) {
          Some(c) => c.local_count.to_string()
          None => "?"
        }
      }
      let bytes_s = if idx < m.imported_func_count() {
        "-"
      } else {
        match m.code_of(idx) {
          Some(c) => c.body.length().to_string()
          None => "?"
        }
      }
      b.write_string(
        "  \{pad_left(idx.to_string(), 4)}  \{pad_right(label_i, 26)}  \{pad_right(sig, 32)}  \{pad_left(locals_s, 6)}  \{pad_left(bytes_s, 6)}\n",
      )
      i = i + 1
    }
    if total > shown {
      b.write_string("  ... \{total - shown} more functions not shown\n")
    }
  }
  // Notes: things a user has to know before trusting the next stage, and things
  // the code generator will have to handle. Empty notes are omitted rather than
  // printed as "none", so the happy path stays short.
  let notes : Array[String] = []
  let multi = m.multi_value_func_count()
  if multi > 0 {
    notes.push(
      "\{multi} signature(s) return more than one value (multi-value proposal); code generation refuses those functions with E112 and emits a trapping stub",
    )
  }
  let unsupported = m.unsupported_type_func_count()
  if unsupported > 0 {
    notes.push(
      "\{unsupported} signature(s) use v128: code generation refuses those functions instead of emitting wrong arithmetic",
    )
  }
  let v128_locals = m.unsupported_local_func_count()
  if v128_locals > 0 {
    notes.push(
      "\{v128_locals} function(s) declare v128 locals (typical of compiler memcpy helpers); code generation refuses them individually",
    )
  }
  if m.func_names.length() == 0 && m.defined_func_count() > 0 {
    notes.push(
      "no name section: function labels are indices, so decompiled output will read like $f12",
    )
  }
  let renamed = rename_count(m)
  if renamed > 0 {
    notes.push(
      "\{renamed} export name(s) are not valid MoonBit identifiers and will be sanitised",
    )
  }
  if m.elems.length() > 0 {
    notes.push(
      "\{m.elems.length()} active element segment(s): indirect calls resolve through a table at run time",
    )
  }
  if notes.length() > 0 {
    b.write_string("\nnotes\n")
    for n in notes {
      b.write_string("  - \{n}\n")
    }
  }
  b.to_string()
}
