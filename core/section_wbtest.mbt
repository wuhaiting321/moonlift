///|
/// White-box tests for section decoding.
///
/// Inputs are built byte by byte rather than loaded from `corpus/`, so that each
/// test states exactly which field it is exercising. The `corpus/` fixtures are
/// covered separately by `script/check.sh`, which runs the real CLI over every
/// file — that catches integration mistakes this file cannot.
///
/// Every rejection test asserts both the error code **and** the byte offset,
/// because "rejected" without a location is not a usable diagnostic.
fn cat(parts : Array[Bytes]) -> Bytes {
  let a : Array[Byte] = []
  for p in parts {
    let mut i = 0
    while i < p.length() {
      a.push(p[i])
      i = i + 1
    }
  }
  Bytes::from_array(a[:])
}

///|
fn bytes_of(a : Array[Byte]) -> Bytes {
  Bytes::from_array(a[:])
}

///|
/// Unsigned LEB128, the only encoding the tests need for lengths and counts.
fn leb(n : Int32) -> Bytes {
  let out : Array[Byte] = []
  let mut v = n
  while true {
    let chunk = v & 0x7F
    v = v >> 7
    if v == 0 {
      out.push(chunk.to_byte())
      break
    }
    out.push((chunk | 0x80).to_byte())
  }
  bytes_of(out)
}

///|
fn header() -> Bytes {
  b"\x00\x61\x73\x6d\x01\x00\x00\x00"
}

///|
fn section(id : Int32, payload : Bytes) -> Bytes {
  cat([bytes_of([id.to_byte()]), leb(payload.length()), payload])
}

///|
fn module_of(parts : Array[Bytes]) -> Bytes {
  let all : Array[Bytes] = [header()]
  for p in parts {
    all.push(p)
  }
  cat(all)
}

///|
fn catch_decode(f : () -> Unit raise ReadFail) -> Diag {
  try {
    f()
    Diag::new(E001Truncated, -1, "no error was raised")
  } catch {
    ReadFail(d) => d
  }
}

///|
/// Decode and expect failure; returns the diagnostic for assertions.
fn expect_fail(data : Bytes) -> Diag {
  catch_decode(() => decode(data) |> ignore)
}

// --- happy paths ----------------------------------------------------------

///|
test "header only is a valid empty module" {
  let m = decode(header())
  assert_eq(m.size(), 8)
  assert_eq(m.sections.length(), 0)
  assert_eq(m.types.length(), 0)
  assert_eq(m.func_count(), 0)
  assert_true(!m.has_start)
}

///|
test "one section of each kind is decoded into the IR" {
  let type_sec = section(
    1,
    cat([
      // two types: () -> () and (i32) -> i32
      b"\x02", b"\x60\x00\x00", b"\x60\x01\x7f\x01\x7f",
    ]),
  )
  let import_sec = section(2, cat([b"\x01", b"\x03env", b"\x01f", b"\x00\x00"]))
  let func_sec = section(3, b"\x01\x01")
  let table_sec = section(4, b"\x01\x70\x00\x01")
  let mem_sec = section(5, b"\x01\x00\x01")
  let global_sec = section(6, b"\x01\x7f\x00\x41\x07\x0b")
  let export_sec = section(
    7,
    cat([b"\x02", b"\x01g\x00\x01", b"\x03mem\x02\x00"]),
  )
  let start_sec = section(8, b"\x00")
  // element: active, table 0, offset 0, functions [1]
  let elem_sec = section(9, cat([b"\x01", b"\x00\x41\x00\x0b", b"\x01\x01"]))
  // body: no locals, i32.const 1, end
  let code_sec = section(10, cat([b"\x01", b"\x04", b"\x00\x41\x01\x0b"]))
  let data_sec = section(11, cat([b"\x01", b"\x00\x41\x00\x0b", b"\x033ab"]))
  let data = module_of([
    type_sec, import_sec, func_sec, table_sec, mem_sec, global_sec, export_sec, start_sec,
    elem_sec, code_sec, data_sec,
  ])
  let m = decode(data)
  assert_eq(m.types.length(), 2)
  assert_eq(m.types[1].signature(), "(i32) -> i32")
  assert_eq(m.imported_func_count(), 1)
  assert_eq(m.defined_func_count(), 1)
  assert_eq(m.func_count(), 2)
  assert_eq(m.func_label(0), "env.f")
  assert_eq(signature_of(m.func_type(1)), "(i32) -> i32")
  assert_eq(m.tables.length(), 1)
  assert_eq(m.tables[0].limits.render(), "min=1, no max")
  assert_eq(m.memories.length(), 1)
  assert_eq(m.globals.length(), 1)
  assert_eq(m.globals[0].init.render(), "i32.const 7")
  assert_eq(m.exports.length(), 2)
  assert_eq(m.export_count(FuncKind), 1)
  assert_eq(m.export_count(MemoryKind), 1)
  assert_true(m.has_start)
  assert_eq(m.start_func, 0)
  assert_eq(m.elems.length(), 1)
  assert_eq(m.elems[0].funcs.length(), 1)
  assert_eq(m.codes.length(), 1)
  assert_eq(m.codes[0].body.length(), 3)
  assert_eq(m.data_bytes(), 3)
  assert_eq(m.sections.length(), 11)
}

///|
test "name section supplies labels and survives without one" {
  // type () -> (); function 0; code: nop-less empty body with just `end`
  let type_sec = section(1, b"\x01\x60\x00\x00")
  let func_sec = section(3, b"\x01\x00")
  let code_sec = section(10, cat([b"\x01", b"\x02", b"\x00\x0b"]))
  // custom "name" with one subsection (id 1) mapping func 0 -> "renamed"
  let name_payload = cat([
    b"\x04name", b"\x01", b"\x0a", b"\x01", b"\x00", b"\x07renamed",
  ])
  let custom_sec = section(0, name_payload)
  let m = decode(module_of([type_sec, func_sec, custom_sec, code_sec]))
  assert_eq(m.func_label(0), "renamed")
  assert_eq(m.customs.length(), 1)
  assert_eq(m.customs[0].name, "name")
  // A module without the section falls back to an index label.
  let bare = decode(module_of([type_sec, func_sec, code_sec]))
  assert_eq(bare.func_label(0), "$f0")
}

///|
test "a malformed name section is ignored, not fatal" {
  let type_sec = section(1, b"\x01\x60\x00\x00")
  let func_sec = section(3, b"\x01\x00")
  let code_sec = section(10, cat([b"\x01", b"\x02", b"\x00\x0b"]))
  // subsection claims 8 bytes of function names but contains 1
  let bad_names = section(0, cat([b"\x04name", b"\x01", b"\x08", b"\x01"]))
  let m = decode(module_of([type_sec, func_sec, bad_names, code_sec]))
  assert_eq(m.func_label(0), "$f0")
  assert_eq(m.customs.length(), 1)
}

///|
test "the data count section is allowed between element and code" {
  let type_sec = section(1, b"\x01\x60\x00\x00")
  let func_sec = section(3, b"\x01\x00")
  let elem_sec = section(9, b"\x00")
  let count_sec = section(12, b"\x01")
  let code_sec = section(10, cat([b"\x01", b"\x02", b"\x00\x0b"]))
  // A memory, so that the data segment has somewhere to go: since the 11-23
  // revision a segment without its container is rejected rather than silently
  // emitted against an object that does not exist.
  let mem_sec = section(5, b"\x01\x00\x01")
  let data_sec = section(11, cat([b"\x01", b"\x00\x41\x00\x0b", b"\x01z"]))
  let m = decode(
    module_of([
      type_sec, func_sec, mem_sec, elem_sec, count_sec, code_sec, data_sec,
    ]),
  )
  assert_true(m.has_data_count)
  assert_eq(m.data_count, 1)
}

///|
test "multiple results are parsed and flagged" {
  let type_sec = section(1, cat([b"\x01", b"\x60\x00\x02\x7f\x7f"]))
  let func_sec = section(3, b"\x01\x00")
  let code_sec = section(
    10,
    cat([b"\x01", b"\x06", b"\x00\x41\x01\x41\x02\x0b"]),
  )
  let m = decode(module_of([type_sec, func_sec, code_sec]))
  assert_true(m.types[0].is_multi_value())
  assert_eq(m.multi_value_func_count(), 1)
}

///|
test "v128 is recognised and marked ungeneratable" {
  let type_sec = section(1, cat([b"\x01", b"\x60\x01\x7b\x00"]))
  let func_sec = section(3, b"\x01\x00")
  let code_sec = section(10, cat([b"\x01", b"\x02", b"\x00\x0b"]))
  let m = decode(module_of([type_sec, func_sec, code_sec]))
  assert_eq(m.types[0].params[0].name(), "v128")
  assert_true(!m.types[0].params[0].is_generatable())
  assert_eq(m.unsupported_type_func_count(), 1)
}

// --- malformed input ------------------------------------------------------

///|
test "rejects a wrong magic" {
  let d = expect_fail(b"not wasm at all")
  assert_eq(d.code.tag(), "E002")
  assert_eq(d.offset, 0)
}

///|
test "rejects a version other than 1" {
  let d = expect_fail(b"\x00\x61\x73\x6d\x02\x00\x00\x00")
  assert_eq(d.code.tag(), "E003")
  assert_eq(d.offset, 4)
}

///|
test "rejects a section that claims more bytes than the file has" {
  let d = expect_fail(cat([header(), b"\x01", b"\x0a", b"\x01\x02\x03"]))
  assert_eq(d.code.tag(), "E001")
  assert_eq(d.offset, 9)
}

///|
test "rejects sections that are out of order" {
  let d = expect_fail(module_of([section(7, b"\x00"), section(1, b"\x00")]))
  assert_eq(d.code.tag(), "E005")
  assert_true(d.message.contains("out of order"))
}

///|
test "rejects a duplicated section" {
  let d = expect_fail(module_of([section(1, b"\x00"), section(1, b"\x00")]))
  assert_eq(d.code.tag(), "E005")
  assert_true(d.message.contains("out of order or duplicated"))
}

///|
test "rejects an unknown section id" {
  let d = expect_fail(module_of([section(13, b"\x00")]))
  assert_eq(d.code.tag(), "E005")
  assert_true(d.message.contains("unknown section id"))
}

///|
test "rejects a section size encoded with an overflowing LEB128" {
  let d = expect_fail(cat([header(), b"\x01", b"\x80\x80\x80\x80\x10"]))
  assert_eq(d.code.tag(), "E004")
}

///|
test "rejects a vector count that cannot fit in the section" {
  // type section: claims 200 entries, has no bytes left
  let d = expect_fail(module_of([section(1, b"\xc8\x01")]))
  assert_eq(d.code.tag(), "E005")
  assert_true(d.message.contains("cannot fit"))
}

///|
test "rejects a value type outside the subset" {
  // (param externref) needs reference types
  let d = expect_fail(
    module_of([section(1, cat([b"\x01", b"\x60\x01\x6f\x00"]))]),
  )
  assert_eq(d.code.tag(), "E101")
  assert_true(d.message.contains("externref"))
}

///|
test "rejects a table of the wrong element type" {
  let d = expect_fail(module_of([section(4, b"\x01\x6f\x00\x01")]))
  assert_eq(d.code.tag(), "E101")
}

///|
test "rejects a second memory" {
  let d = expect_fail(module_of([section(5, b"\x02\x00\x01\x00\x01")]))
  assert_eq(d.code.tag(), "E106")
}

///|
test "rejects shared limits" {
  let d = expect_fail(module_of([section(5, b"\x01\x03\x01\x01")]))
  assert_eq(d.code.tag(), "E103")
}

///|
test "rejects a passive data segment" {
  let d = expect_fail(
    module_of([section(11, cat([b"\x01", b"\x01", b"\x04abcd"]))]),
  )
  assert_eq(d.code.tag(), "E109")
}

///|
test "rejects a body whose last byte is not end" {
  let type_sec = section(1, b"\x01\x60\x00\x00")
  let func_sec = section(3, b"\x01\x00")
  let code_sec = section(10, cat([b"\x01", b"\x02", b"\x00\x01"]))
  let d = expect_fail(module_of([type_sec, func_sec, code_sec]))
  assert_eq(d.code.tag(), "E005")
  assert_true(d.message.contains("end opcode"))
}

///|
test "rejects a body count that disagrees with the function section" {
  let type_sec = section(1, b"\x01\x60\x00\x00")
  let func_sec = section(3, b"\x01\x00")
  let d = expect_fail(module_of([type_sec, func_sec]))
  assert_eq(d.code.tag(), "E005")
  assert_true(d.message.contains("bodies"))
}

///|
test "rejects an index past the type table" {
  let d = expect_fail(module_of([section(1, b"\x00"), section(3, b"\x01\x05")]))
  assert_eq(d.code.tag(), "E008")
  assert_true(d.message.contains("type index 5"))
}

///|
test "rejects an export index past the function space" {
  let type_sec = section(1, b"\x01\x60\x00\x00")
  let func_sec = section(3, b"\x01\x00")
  let code_sec = section(10, cat([b"\x01", b"\x02", b"\x00\x0b"]))
  let export_sec = section(7, cat([b"\x01", b"\x01f\x00\x09"]))
  let d = expect_fail(module_of([type_sec, func_sec, export_sec, code_sec]))
  assert_eq(d.code.tag(), "E008")
  assert_true(d.message.contains("func index 9"))
}

///|
test "accepts the three non-function imports and keeps the index spaces apart" {
  // memory (min 1), table (min 8), global i32 immutable — all imported.
  let import_sec = section(
    2,
    cat([
      b"\x03", b"\x03env", b"\x03mem", b"\x02", b"\x00\x01", b"\x03env", b"\x03tbl",
      b"\x01", b"\x70\x00\x08", b"\x03env", b"\x04base", b"\x03", b"\x7f\x00",
    ]),
  )
  let m = decode(module_of([import_sec]))
  assert_eq(m.imported_memories, 1)
  assert_eq(m.memories.length(), 1)
  assert_eq(m.memories[0].limits.min.reinterpret_as_int(), 1)
  assert_eq(m.imported_tables, 1)
  assert_eq(m.tables.length(), 1)
  assert_eq(m.tables[0].limits.min.reinterpret_as_int(), 8)
  assert_eq(m.imported_globals, 1)
  assert_eq(m.globals.length(), 1)
  assert_true(m.globals[0].imported)
  assert_true(!m.globals[0].mutable)
}

///|
test "an imported memory counts towards the one-memory rule" {
  // imported memory, then a memory section that declares another one
  let import_sec = section(
    2,
    cat([b"\x01", b"\x03env", b"\x03mem", b"\x02", b"\x00\x01"]),
  )
  let mem_sec = section(5, b"\x01\x00\x01")
  let d = expect_fail(module_of([import_sec, mem_sec]))
  assert_eq(d.code.tag(), "E106")
  assert_true(d.message.contains("more than one memory"))
}

///|
test "rejects a second table, imported or declared" {
  let table_sec = section(4, cat([b"\x02", b"\x70\x00\x01", b"\x70\x00\x01"]))
  let d = expect_fail(module_of([table_sec]))
  assert_eq(d.code.tag(), "E106")
  assert_true(d.message.contains("more than one table"))
}

///|
test "rejects a segment placed at a global the module defines itself" {
  let mem_sec = section(5, b"\x01\x00\x01")
  let global_sec = section(6, cat([b"\x01", b"\x7f\x00\x41\x00\x0b"]))
  // data segment 0, active, offset (global.get 0), one byte
  let data_sec = section(11, cat([b"\x01", b"\x00", b"\x23\x00\x0b", b"\x01a"]))
  let d = expect_fail(module_of([mem_sec, global_sec, data_sec]))
  assert_eq(d.code.tag(), "E012")
  assert_true(d.message.contains("defines itself"))
}

///|
test "rejects a segment placed at a mutable imported global" {
  let import_sec = section(
    2,
    cat([b"\x01", b"\x03env", b"\x04base", b"\x03", b"\x7f\x01"]),
  )
  let mem_sec = section(5, b"\x01\x00\x01")
  let data_sec = section(11, cat([b"\x01", b"\x00", b"\x23\x00\x0b", b"\x01a"]))
  let d = expect_fail(module_of([import_sec, mem_sec, data_sec]))
  assert_eq(d.code.tag(), "E012")
  assert_true(d.message.contains("mutable"))
}

///|
test "rejects a segment placed at an imported global of the wrong type" {
  let import_sec = section(
    2,
    cat([b"\x01", b"\x03env", b"\x04base", b"\x03", b"\x7e\x00"]),
  )
  let mem_sec = section(5, b"\x01\x00\x01")
  let data_sec = section(11, cat([b"\x01", b"\x00", b"\x23\x00\x0b", b"\x01a"]))
  let d = expect_fail(module_of([import_sec, mem_sec, data_sec]))
  assert_eq(d.code.tag(), "E012")
  assert_true(d.message.contains("needs i32"))
}

///|
test "rejects a segment section whose container does not exist" {
  // element segment, but no table
  let elem_sec = section(
    9,
    cat([b"\x01", b"\x00", b"\x41\x00\x0b", b"\x01\x00"]),
  )
  let d1 = expect_fail(module_of([elem_sec]))
  assert_eq(d1.code.tag(), "E010")
  assert_true(d1.message.contains("no table"))
  // data segment, but no memory
  let data_sec = section(11, cat([b"\x01", b"\x00", b"\x41\x00\x0b", b"\x01a"]))
  let d2 = expect_fail(module_of([data_sec]))
  assert_eq(d2.code.tag(), "E010")
  assert_true(d2.message.contains("no memory"))
}

///|
test "rejects an invalid global mutability flag" {
  let d = expect_fail(
    module_of([section(6, cat([b"\x01", b"\x7f\x02\x41\x00\x0b"]))]),
  )
  assert_eq(d.code.tag(), "E005")
  assert_true(d.message.contains("mutability"))
}

///|
test "rejects a constant expression built from a non-constant opcode" {
  // global i32 = (local.get 0): legal syntax position, illegal instruction
  let d = expect_fail(
    module_of([section(6, cat([b"\x01", b"\x7f\x00\x20\x00\x0b"]))]),
  )
  assert_eq(d.code.tag(), "E006")
  assert_true(d.message.contains("constant expression"))
}

///|
test "rejects a section whose declared size disagrees with its content" {
  // type section declares 4 bytes but only 1 entry consumes 3
  let d = expect_fail(module_of([section(1, b"\x01\x60\x00\x00\x00")]))
  assert_eq(d.code.tag(), "E005")
  assert_true(d.message.contains("were consumed"))
}

///|
test "rejects more locals than the guard allows" {
  let type_sec = section(1, b"\x01\x60\x00\x00")
  let func_sec = section(3, b"\x01\x00")
  // one local declaration of 100001 i32s
  let body = cat([b"\x01", leb(100_001), b"\x7f", b"\x0b"])
  let code_sec = section(10, cat([b"\x01", leb(body.length()), body]))
  let d = expect_fail(module_of([type_sec, func_sec, code_sec]))
  assert_eq(d.code.tag(), "E005")
  assert_true(d.message.contains("locals"))
}
