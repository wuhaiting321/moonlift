///|
/// Section-level decoding: file header, section framing, and the twelve core
/// sections of the MVP binary format.
///
/// This file does **not** decode instructions. A function body is stored as its
/// raw byte range plus its local declarations, and the instruction stream is
/// decoded in stage S3. The split is what makes `moonlift info` useful on
/// modules the decompiler will later refuse: structure can be reported without
/// understanding a single opcode.
///
/// Failure policy: every parser raises `ReadFail(Diag)` with an absolute byte
/// offset. Nothing here returns a half-built module or "best effort" data —
/// either the module is structurally valid and fully decoded, or the caller gets
/// one diagnostic that names a byte.

///|
/// Upper bound on locals per function. The spec has no limit, but a corrupt
/// `(count, type)` pair can claim four billion locals; refusing above this keeps
/// memory bounded without rejecting anything a real compiler emits.
const MAX_LOCALS : Int32 = 100_000

///|
/// Read a vector length and refuse counts that cannot possibly fit in the bytes
/// remaining in the section.
///
/// Without this, a single flipped byte in a count field turns into a
/// multi-gigabyte allocation and the process dies with no diagnostic. With it,
/// the same byte produces `E005` pointing at the count field.
fn vec_count(
  r : Reader,
  min_item_bytes : Int32,
  what : String,
) -> Int32 raise ReadFail {
  let at = r.position()
  let n = r.u32_leb().reinterpret_as_int()
  if n < 0 {
    fail_at(at, E005BadSection, "\{what} count is negative after decoding")
  }
  if min_item_bytes > 0 {
    let capacity = r.remaining() / min_item_bytes
    if n > capacity {
      fail_at(
        at,
        E005BadSection,
        "\{what} count \{n} cannot fit in the \{r.remaining()} bytes left",
      )
    }
  }
  n
}

///|
/// Bounds check that always carries the offset of the index field itself.
fn check_index(
  at : Int32,
  idx : Int32,
  limit : Int32,
  what : String,
) -> Unit raise ReadFail {
  if idx < 0 || idx >= limit {
    fail_at(at, E008BadIndex, "\{what} index \{idx} is outside 0..\{limit}")
  }
}

///|
/// One value type. Rejections name the proposal that would make the type legal,
/// because "unsupported" alone does not tell a user how to rebuild their module.
fn read_valtype(r : Reader) -> ValType raise ReadFail {
  let at = r.position()
  match r.u8().to_uint() {
    0x7FU => I32
    0x7EU => I64
    0x7DU => F32
    0x7CU => F64
    0x7BU => V128
    0x70U =>
      fail_at(
        at,
        E101Gc,
        "funcref value type needs the reference-types proposal",
      )
    0x6FU =>
      fail_at(
        at,
        E101Gc,
        "externref value type needs the reference-types proposal",
      )
    other =>
      fail_at(
        at,
        E007BadType,
        "value type 0x\{hex_u8(other)} is not i32/i64/f32/f64",
      )
  }
}

///|
fn read_valtype_vec(r : Reader, what : String) -> Array[ValType] raise ReadFail {
  let n = vec_count(r, 1, what)
  let out : Array[ValType] = []
  let mut i = 0
  while i < n {
    out.push(read_valtype(r))
    i = i + 1
  }
  out
}

///|
/// Limits, shared by tables and memories. Flags encode three orthogonal things:
/// 0x01 "has max", 0x02 "shared", 0x04 "64-bit index"; the two proposals we
/// refuse are reported by name.
fn read_limits(r : Reader) -> Limits raise ReadFail {
  let at = r.position()
  match r.u8().to_uint() {
    0x00U => Limits::new(r.u32_leb(), 0U, false)
    0x01U => {
      let min = r.u32_leb()
      let max = r.u32_leb()
      if max < min {
        fail_at(at, E005BadSection, "limits max \{max} is below min \{min}")
      }
      Limits::new(min, max, true)
    }
    0x02U | 0x03U =>
      fail_at(at, E103Threads, "shared table/memory needs the threads proposal")
    0x04U | 0x05U =>
      fail_at(at, E106MultiMemory, "64-bit limits need the memory64 proposal")
    other =>
      fail_at(at, E005BadSection, "limits flag 0x\{hex_u8(other)} is invalid")
  }
}

///|
/// A constant expression: exactly one constant instruction followed by `end`.
///
/// Parsed properly rather than by scanning for the `end` byte, because a
/// `i32.const` payload can contain 0x0B and a naive scan would then cut the
/// expression in the wrong place.
fn read_const_expr(r : Reader) -> ConstExpr raise ReadFail {
  let at = r.position()
  let op = r.u8().to_uint()
  let value = if op == 0x41U {
    I32Const(r.s32_leb())
  } else if op == 0x42U {
    I64Const(r.s64_leb())
  } else if op == 0x43U {
    F32Const(r.u32_le())
  } else if op == 0x44U {
    F64Const(r.u64_le())
  } else if op == 0x23U {
    GlobalGet(r.u32_leb().reinterpret_as_int())
  } else {
    fail_at(
      at,
      E006BadOpcode,
      "opcode 0x\{hex_u8(op)} is not allowed in a constant expression",
    )
  }
  let at_end = r.position()
  if r.u8().to_uint() != 0x0BU {
    fail_at(
      at_end,
      E005BadSection,
      "constant expression is not terminated by end",
    )
  }
  value
}

// --- section parsers ------------------------------------------------------

///|
fn parse_type_section(
  r : Reader,
  types : Array[FuncType],
) -> Unit raise ReadFail {
  let n = vec_count(r, 3, "type")
  let mut i = 0
  while i < n {
    let at = r.position()
    let form = r.u8().to_uint()
    if form != 0x60U {
      fail_at(at, E007BadType, "type form 0x\{hex_u8(form)} is not 0x60 (func)")
    }
    let params = read_valtype_vec(r, "parameter")
    let results = read_valtype_vec(r, "result")
    types.push(FuncType::new(params, results))
    i = i + 1
  }
}

///|
fn parse_import_section(
  r : Reader,
  imports : Array[ImportedFunc],
  types : Array[FuncType],
  tables : Array[Table],
  memories : Array[Memory],
  globals : Array[Global],
  counts : ImportCounts,
) -> Unit raise ReadFail {
  let n = vec_count(r, 4, "import")
  let mut i = 0
  while i < n {
    let module_name = r.name()
    let field_name = r.name()
    let at_kind = r.position()
    let kind = r.u8().to_uint()
    if kind == 0x00U {
      let at_idx = r.position()
      let type_idx = r.u32_leb().reinterpret_as_int()
      check_index(at_idx, type_idx, types.length(), "type")
      imports.push({ module_name, field_name, type_idx, })
    } else if kind == 0x01U {
      read_reftype(r)
      let limits = read_limits(r)
      counts.tables = counts.tables + 1
      tables.push({ limits, })
    } else if kind == 0x02U {
      let limits = read_limits(r)
      counts.memories = counts.memories + 1
      memories.push({ limits, })
    } else if kind == 0x03U {
      let ty = read_valtype(r)
      let at = r.position()
      let flag = r.u8().to_uint()
      let mutable = match flag {
        0x00U => false
        0x01U => true
        _ =>
          fail_at(
            at,
            E005BadSection,
            "global mutability flag is invalid in an import",
          )
      }
      counts.globals = counts.globals + 1
      globals.push({ ty, mutable, init: zero_const(ty), imported: true, })
    } else {
      fail_at(
        at_kind,
        E005BadSection,
        "import kind is invalid: only func, table, memory and global exist",
      )
    }
    i = i + 1
  }
}

///|
/// How many imports of each non-function kind were seen. Filled by the section
/// parser, because it is the only place that sees the kind byte: the arrays it
/// appends to cannot tell an imported table from a declared one afterwards.
priv struct ImportCounts {
  mut tables : Int32
  mut memories : Int32
  mut globals : Int32
}

///|
/// The constant an imported global holds before the host sets it.
fn zero_const(ty : ValType) -> ConstExpr {
  match ty {
    I32 => I32Const(0)
    I64 => I64Const(0L)
    F32 => F32Const(0U)
    F64 => F64Const(0UL)
    V128 => I32Const(0)
  }
}

///|
fn parse_function_section(
  r : Reader,
  func_types : Array[Int32],
  types : Array[FuncType],
) -> Unit raise ReadFail {
  let n = vec_count(r, 1, "function")
  let mut i = 0
  while i < n {
    let at = r.position()
    let type_idx = r.u32_leb().reinterpret_as_int()
    check_index(at, type_idx, types.length(), "type")
    func_types.push(type_idx)
    i = i + 1
  }
}

///|
/// The element type of a table. WebAssembly 1.0 has exactly one, `funcref`,
/// encoded as 0x70; 0x6F is `externref`, which arrived with reference types.
fn read_reftype(r : Reader) -> Unit raise ReadFail {
  let at = r.position()
  let elem = r.u8().to_uint()
  if elem == 0x6FU {
    fail_at(at, E101Gc, "externref table needs the reference-types proposal")
  }
  if elem != 0x70U {
    fail_at(
      at,
      E007BadType,
      "table element type is not funcref (1.0 has no other reference type)",
    )
  }
}

///|
/// The table section. 1.0 allows at most one table in the whole module, counted
/// across imports and declarations, so a second one is a bulk-memory or
/// reference-types module: as much a boundary as multi-memory, and named here
/// rather than silently ignored while table 0 is emitted.
fn parse_table_section(
  r : Reader,
  tables : Array[Table],
) -> Unit raise ReadFail {
  let at = r.position()
  let n = vec_count(r, 3, "table")
  if tables.length() + n > 1 {
    fail_at(
      at,
      E106MultiMemory,
      "module declares more than one table (1.0 allows at most one)",
    )
  }
  let mut i = 0
  while i < n {
    read_reftype(r)
    let limits = read_limits(r)
    tables.push({ limits, })
    i = i + 1
  }
}

///|
fn parse_memory_section(
  r : Reader,
  memories : Array[Memory],
) -> Unit raise ReadFail {
  let at = r.position()
  let n = vec_count(r, 1, "memory")
  if memories.length() + n > 1 {
    fail_at(
      at,
      E106MultiMemory,
      "module declares more than one memory (multi-memory proposal)",
    )
  }
  let mut i = 0
  while i < n {
    let limits = read_limits(r)
    memories.push({ limits, })
    i = i + 1
  }
}

///|
/// What a constant expression is allowed to read, in 1.0.
///
/// `global.get` there may name an *imported* global only, it must be immutable,
/// and its type must be the one the position needs. All three rules exist for the
/// same reason: a segment offset has to be the same at every instantiation, and
/// only an imported immutable global has that property. A module that breaks the
/// rule is invalid, not unsupported, so this is an `E0xx` and not an `E1xx`.
fn check_const_global(
  e : ConstExpr,
  globals : Array[Global],
  imported : Int32,
  want : ValType?,
  at : Int32,
) -> Unit raise ReadFail {
  match e {
    GlobalGet(i) => {
      if i < 0 || i >= globals.length() {
        fail_at(at, E008BadIndex, "global index \{i} is out of range")
      }
      if i >= imported {
        fail_at(
          at,
          E012BadConstExpr,
          "constant expression names global \{i}, which this module defines itself",
        )
      }
      let g = globals[i]
      if g.mutable {
        fail_at(
          at,
          E012BadConstExpr,
          "global \{i} is mutable, and a constant expression reads only immutable globals",
        )
      }
      match want {
        Some(t) =>
          if !vt_eq(g.ty, t) {
            fail_at(
              at,
              E012BadConstExpr,
              "global \{i} has type \{g.ty.name()}, this position needs \{t.name()}",
            )
          }
        None => ()
      }
    }
    _ => ()
  }
}

///|
fn parse_global_section(
  r : Reader,
  globals : Array[Global],
) -> Unit raise ReadFail {
  // Every global already in the array came from the import section, so its
  // length is exactly the boundary a constant expression may not cross.
  let imported = globals.length()
  let n = vec_count(r, 3, "global")
  let mut i = 0
  while i < n {
    let ty = read_valtype(r)
    let at = r.position()
    let flag = r.u8().to_uint()
    let mutable = if flag == 0x00U {
      false
    } else if flag == 0x01U {
      true
    } else {
      fail_at(
        at,
        E005BadSection,
        "global mutability flag 0x\{hex_u8(flag)} is invalid",
      )
    }
    let at_init = r.position()
    let init = read_const_expr(r)
    check_const_global(init, globals, imported, Some(ty), at_init)
    globals.push({ ty, mutable, init, imported: false, })
    i = i + 1
  }
}

///|
fn parse_export_section(
  r : Reader,
  exports : Array[Export],
  func_count : Int32,
  table_count : Int32,
  memory_count : Int32,
  global_count : Int32,
) -> Unit raise ReadFail {
  let n = vec_count(r, 3, "export")
  let mut i = 0
  while i < n {
    let name = r.name()
    let at_kind = r.position()
    let raw = r.u8().to_uint()
    let at_idx = r.position()
    let index = r.u32_leb().reinterpret_as_int()
    let kind = if raw == 0x00U {
      FuncKind
    } else if raw == 0x01U {
      TableKind
    } else if raw == 0x02U {
      MemoryKind
    } else if raw == 0x03U {
      GlobalKind
    } else {
      fail_at(
        at_kind,
        E005BadSection,
        "export kind 0x\{hex_u8(raw)} is invalid",
      )
    }
    let limit = if raw == 0x00U {
      func_count
    } else if raw == 0x01U {
      table_count
    } else if raw == 0x02U {
      memory_count
    } else {
      global_count
    }
    check_index(at_idx, index, limit, kind.name())
    exports.push({ name, kind, index, })
    i = i + 1
  }
}

///|
fn parse_start_section(r : Reader, func_count : Int32) -> Int32 raise ReadFail {
  let at = r.position()
  let idx = r.u32_leb().reinterpret_as_int()
  check_index(at, idx, func_count, "start function")
  idx
}

///|
/// Element segments. Only flag 0 exists in the MVP; flags 1..7 encode passive
/// segments and element expressions, both of which are later proposals.
fn parse_element_section(
  r : Reader,
  elems : Array[Elem],
  func_count : Int32,
  table_count : Int32,
  globals : Array[Global],
  imported_globals : Int32,
) -> Unit raise ReadFail {
  let n = vec_count(r, 3, "element segment")
  let mut i = 0
  while i < n {
    let at = r.position()
    let flags = r.u32_leb().reinterpret_as_int()
    if flags != 0 {
      fail_at(
        at,
        E109BulkMemory,
        "element segment flag \{flags} needs bulk-memory / reference types",
      )
    }
    // An active segment needs a table to write into, and saying so here is what
    // keeps the promise that a rejected input never becomes a package that does
    // not compile: the emitter would otherwise reference a table it never wrote.
    // Passive segments are refused as bulk memory before this point matters.
    if table_count == 0 {
      fail_at(
        at,
        E010BadData,
        "element segment, but the module declares no table",
      )
    }
    let at_off = r.position()
    let offset = read_const_expr(r)
    check_const_global(offset, globals, imported_globals, Some(I32), at_off)
    let cnt = vec_count(r, 1, "element function")
    let funcs : Array[Int32] = []
    let mut j = 0
    while j < cnt {
      let at_f = r.position()
      let f = r.u32_leb().reinterpret_as_int()
      check_index(at_f, f, func_count, "element function")
      funcs.push(f)
      j = j + 1
    }
    elems.push({ offset, funcs, })
    i = i + 1
  }
}

///|
/// Local declarations of one function.
fn read_locals(r : Reader) -> Array[LocalDecl] raise ReadFail {
  let n = vec_count(r, 2, "local declaration")
  let out : Array[LocalDecl] = []
  let mut total = 0
  let mut i = 0
  while i < n {
    let at = r.position()
    let count = r.u32_leb()
    let ty = read_valtype(r)
    total = total + count.reinterpret_as_int()
    if total > MAX_LOCALS {
      fail_at(
        at,
        E005BadSection,
        "function declares \{total} locals, limit is \{MAX_LOCALS}",
      )
    }
    out.push({ count, ty, })
    i = i + 1
  }
  out
}

///|
fn sum_locals(locals : Array[LocalDecl]) -> Int32 {
  let mut n = 0
  for l in locals {
    n = n + l.count.reinterpret_as_int()
  }
  n
}

///|
fn parse_code_section(
  r : Reader,
  codes : Array[Code],
  expected : Int32,
) -> Unit raise ReadFail {
  let at = r.position()
  let n = vec_count(r, 2, "code body")
  if n != expected {
    fail_at(
      at,
      E005BadSection,
      "function section declares \{expected} functions, code section has \{n} bodies",
    )
  }
  let mut i = 0
  while i < n {
    let at_size = r.position()
    let size = r.u32_leb().reinterpret_as_int()
    let body = r.slice(size)
    let locals = read_locals(body)
    let local_count = sum_locals(locals)
    let body_offset = body.position()
    let expr = body.bytes(body.remaining())
    if expr.length() == 0 {
      fail_at(at_size, E005BadSection, "function body \{i} is empty")
    }
    // A body is `instr* end`, and `end` is a single byte, so the last byte of
    // the body must be 0x0B. Cheap check that catches a wrong size field before
    // the instruction decoder ever runs.
    if expr[expr.length() - 1].to_uint() != 0x0BU {
      fail_at(
        body_offset + expr.length() - 1,
        E005BadSection,
        "function body \{i} does not end with the end opcode",
      )
    }
    codes.push({ locals, local_count, body: expr, body_offset, })
    i = i + 1
  }
}

///|
fn parse_data_section(
  r : Reader,
  datas : Array[Data],
  globals : Array[Global],
  imported_globals : Int32,
  memory_count : Int32,
) -> Unit raise ReadFail {
  let n = vec_count(r, 2, "data segment")
  let mut i = 0
  while i < n {
    let at = r.position()
    let flags = r.u32_leb().reinterpret_as_int()
    if flags == 1 {
      fail_at(at, E109BulkMemory, "passive data segment needs bulk-memory")
    }
    if flags != 0 {
      fail_at(
        at,
        E109BulkMemory,
        "data segment flag \{flags} needs bulk-memory / multi-memory",
      )
    }
    if memory_count == 0 {
      fail_at(
        at,
        E010BadData,
        "data segment, but the module declares no memory",
      )
    }
    let at_off = r.position()
    let offset = read_const_expr(r)
    check_const_global(offset, globals, imported_globals, Some(I32), at_off)
    if !offset.is_known_i32() {
      fail_at(at, E010BadData, "data segment offset is not an i32 constant")
    }
    let at_len = r.position()
    let len = r.u32_leb().reinterpret_as_int()
    let payload = r.bytes(len)
    if payload.length() != len {
      fail_at(at_len, E001Truncated, "data segment payload is truncated")
    }
    datas.push({ offset, bytes: payload, offset_pos: at_len, })
    i = i + 1
  }
}

///|
/// Custom sections are metadata. Only `name` is interpreted, and only on a
/// best-effort basis: the spec says a malformed custom section must not
/// invalidate the module, so a failure here is swallowed rather than raised.
fn parse_custom_section(
  r : Reader,
  customs : Array[Custom],
  names : Array[FuncName],
) -> Unit raise ReadFail {
  let name = r.name()
  let payload = r.bytes(r.remaining())
  customs.push({ name, size: payload.length(), })
  if name == "name" {
    parse_name_section(Reader::new(payload), names) catch {
      ReadFail(_) => ()
    }
  }
}

///|
/// The `name` section: a sequence of `(subsection id, size, payload)` records.
/// Subsection 1 carries function names, which is what `info` prints.
fn parse_name_section(
  r : Reader,
  names : Array[FuncName],
) -> Unit raise ReadFail {
  while !r.at_end() {
    let id = r.u8().to_uint()
    let size = r.u32_leb().reinterpret_as_int()
    let sub = r.slice(size)
    if id == 1U {
      let n = vec_count(sub, 2, "function name")
      let mut i = 0
      while i < n {
        let index = sub.u32_leb().reinterpret_as_int()
        let name = sub.name()
        names.push({ index, name, })
        i = i + 1
      }
    }
  }
}

///|
/// Position of a section in the order the binary format requires.
///
/// Ids are almost, but not quite, the order: the data-count section (id 12) was
/// added with bulk memory and sits between element (9) and code (10), not after
/// data (11). Ranking it explicitly is the difference between "reject every
/// modern module" and "decode it".
fn section_rank(id : UInt32) -> Int32 {
  let n = id.reinterpret_as_int()
  if id == 12U {
    10
  } else if n <= 9 {
    n
  } else {
    n + 1
  }
}

///|
/// Section names, in the order the binary format assigns them.
pub fn section_name(id : Byte) -> String {
  match id.to_uint() {
    0x00U => "custom"
    0x01U => "type"
    0x02U => "import"
    0x03U => "function"
    0x04U => "table"
    0x05U => "memory"
    0x06U => "global"
    0x07U => "export"
    0x08U => "start"
    0x09U => "element"
    0x0AU => "code"
    0x0BU => "data"
    0x0CU => "datacount"
    other => "id\{other}"
  }
}

// --- the decoder ----------------------------------------------------------

///|
/// Decode a whole module. Raises on the first structural problem.
///
/// Section order is enforced here rather than validated afterwards: the wasm
/// grammar requires every non-custom section to appear at most once and in
/// increasing id order, and decoding in that order is what lets each parser
/// validate its indices against tables that are already complete.
pub fn decode(data : Bytes) -> Module raise ReadFail {
  let r = Reader::new(data)
  let magic = r.bytes(4)
  if magic[0].to_uint() != 0x00U ||
    magic[1].to_uint() != 0x61U ||
    magic[2].to_uint() != 0x73U ||
    magic[3].to_uint() != 0x6DU {
    fail_at(0, E002BadMagic, "not a wasm binary: missing \\0asm magic")
  }
  let at_version = r.position()
  let version = r.u32_le()
  if version != 1U {
    fail_at(
      at_version,
      E003BadVersion,
      "binary version \{version}, only version 1 is supported",
    )
  }
  let types : Array[FuncType] = []
  let imports : Array[ImportedFunc] = []
  let func_types : Array[Int32] = []
  let tables : Array[Table] = []
  let memories : Array[Memory] = []
  let globals : Array[Global] = []
  let exports : Array[Export] = []
  let elems : Array[Elem] = []
  let codes : Array[Code] = []
  let datas : Array[Data] = []
  let customs : Array[Custom] = []
  let sections : Array[SectionRef] = []
  let func_names : Array[FuncName] = []
  let counts = { tables: 0, memories: 0, globals: 0, }
  let mut start_func : Int32 = 0
  let mut has_start = false
  let mut data_count = 0
  let mut has_data_count = false
  let mut at_data_count = 0
  let mut last_id = -1
  while !r.at_end() {
    let sec_start = r.position()
    let id = r.u8()
    let sid = id.to_uint()
    let at_size = r.position()
    let size = r.u32_leb().reinterpret_as_int()
    if size > r.remaining() {
      fail_at(
        at_size,
        E001Truncated,
        "section '\{section_name(id)}' declares \{size} bytes, only \{r.remaining()} remain",
      )
    }
    if sid != 0U {
      if sid > 12U {
        fail_at(
          sec_start,
          E005BadSection,
          "unknown section id \{sid} after byte \{sec_start}",
        )
      }
      let rank = section_rank(sid)
      if rank <= last_id {
        fail_at(
          sec_start,
          E005BadSection,
          "section '\{section_name(id)}' is out of order or duplicated",
        )
      }
      last_id = rank
    }
    let body = r.slice(size)
    if sid == 0U {
      parse_custom_section(body, customs, func_names)
    } else if sid == 1U {
      parse_type_section(body, types)
    } else if sid == 2U {
      parse_import_section(
        body, imports, types, tables, memories, globals, counts,
      )
    } else if sid == 3U {
      parse_function_section(body, func_types, types)
    } else if sid == 4U {
      parse_table_section(body, tables)
    } else if sid == 5U {
      parse_memory_section(body, memories)
    } else if sid == 6U {
      parse_global_section(body, globals)
    } else if sid == 7U {
      parse_export_section(
        body,
        exports,
        imports.length() + func_types.length(),
        tables.length(),
        memories.length(),
        globals.length(),
      )
    } else if sid == 8U {
      if has_start {
        fail_at(sec_start, E005BadSection, "duplicate start section")
      }
      start_func = parse_start_section(
        body,
        imports.length() + func_types.length(),
      )
      has_start = true
    } else if sid == 9U {
      parse_element_section(
        body,
        elems,
        imports.length() + func_types.length(),
        tables.length(),
        globals,
        counts.globals,
      )
    } else if sid == 10U {
      parse_code_section(body, codes, func_types.length())
    } else if sid == 11U {
      parse_data_section(
        body,
        datas,
        globals,
        counts.globals,
        memories.length(),
      )
    } else {
      // Section 12: the data count, introduced with bulk memory. It is only a
      // number, so it is accepted as metadata. Whether the module actually uses
      // bulk-memory *instructions* is a per-function question, answered in S3.
      at_data_count = body.position()
      data_count = body.u32_leb().reinterpret_as_int()
      has_data_count = true
    }
    if !body.at_end() {
      fail_at(
        body.position(),
        E005BadSection,
        "section '\{section_name(id)}' declares \{size} bytes but \{size - body.remaining()} were consumed",
      )
    }
    sections.push({ id, offset: sec_start, size, })
  }
  if has_data_count && data_count != datas.length() {
    fail_at(
      at_data_count,
      E005BadSection,
      "data count section declares \{data_count} segments, data section has \{datas.length()}",
    )
  }
  if func_types.length() != codes.length() {
    fail_at(
      data.length(),
      E005BadSection,
      "function section declares \{func_types.length()} functions but the module has \{codes.length()} bodies",
    )
  }
  {
    size: data.length(),
    types,
    imports,
    func_types,
    tables,
    memories,
    globals,
    imported_tables: counts.tables,
    imported_memories: counts.memories,
    imported_globals: counts.globals,
    exports,
    elems,
    codes,
    datas,
    customs,
    sections,
    func_names,
    start_func,
    has_start,
    data_count,
    has_data_count,
  }
}

///|
/// `Result`-based wrapper around `decode`, for callers that want to print a
/// diagnostic and move on to the next file rather than unwind.
pub fn decode_bytes(data : Bytes) -> DecodeResult[Module] {
  attempt(() => decode(data))
}
