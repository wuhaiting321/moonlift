///|
/// Tests for the merged-package emitter.
///
/// The interesting part is not that two modules can be written into one
/// directory: it is that their top-level names cannot collide, and that the one
/// type the emitter generates keeps a legal MoonBit spelling (`m0_` for values,
/// `M0_` for types). Both are pure functions of the modules, so they are pinned
/// here rather than in `script/merge.sh`, which needs a real compiler and a real
/// `Memory`.

///|
/// A module that imports one memory and defines one function.
///
/// Import section: one entry, `env.mem`, kind 2 (memory), limits `min=1`.
/// Code section: `local.get 0; end`, so the function is trivially structurable.
fn memory_importer() -> Module raise ReadFail {
  decode(
    cat([
      header(),
      // type: (i32) -> i32
      b"\x01\x06\x01\x60\x01\x7f\x01\x7f",
      // import: 1 entry, "env" "mem" memory, limits 0 1
      b"\x02\x0c\x01\x03env\x03mem\x02\x00\x01",
      // function: one function, type 0
      b"\x03\x02\x01\x00",
      // export "peek" as func 0
      b"\x07\x08\x01\x04peek\x00\x00",
      // code: no locals, local.get 0, end
      b"\x0a\x06\x01\x04\x00\x20\x00\x0b",
    ]),
  )
}

///|
/// The text of one file in a report.
fn file_of(files : Array[GenFile], name : String) -> String {
  for f in files {
    if f.name == name {
      return f.text
    }
  }
  ""
}

///|
test "one module keeps the names every doc shows" {
  // The single-module path must stay byte-identical: no `m0_`, no `M0_`, and no
  // `all.mbt`. `script/check.sh` compares generated packages against expectations
  // written for this spelling.
  let r = emit_package_multi([memory_importer()])
  assert_eq(r.prefixes.length(), 1)
  assert_eq(r.prefixes[0], "")
  let body = file_of(r.files, "module.mbt")
  assert_true(body.contains("pub struct MoonliftExterns {"))
  assert_true(body.contains("pub fn moonlift_bind(e : MoonliftExterns)"))
  assert_false(body.contains("m0_"))
  assert_false(file_of(r.files, "all.mbt") != "")
}

///|
test "two modules are prefixed, and the type prefix is upper-case" {
  let r = emit_package_multi([memory_importer(), memory_importer()])
  assert_eq(r.prefixes.length(), 2)
  assert_eq(r.prefixes[0], "m0_")
  assert_eq(r.prefixes[1], "m1_")
  let body = file_of(r.files, "module.mbt")
  // Values carry `m{i}_`; the struct carries `M{i}_`, because MoonBit type names
  // start upper-case and `m0_MoonliftExterns` would not parse.
  assert_true(body.contains("pub struct M0_MoonliftExterns {"))
  assert_true(body.contains("pub struct M1_MoonliftExterns {"))
  assert_true(body.contains("pub fn m0_moonlift_bind(e : M0_MoonliftExterns)"))
  assert_true(body.contains("pub fn m1_moonlift_bind(e : M1_MoonliftExterns)"))
  // The import field is named the same in both records: one object fills both.
  assert_true(
    body.contains("pub struct M0_MoonliftExterns {\n  env_mem : Memory\n}"),
  )
  assert_true(
    body.contains("pub struct M1_MoonliftExterns {\n  env_mem : Memory\n}"),
  )
  // Names that would otherwise collide.
  assert_true(body.contains("pub fn m0___ml_mem() -> Memory"))
  assert_true(body.contains("pub fn m1___ml_mem() -> Memory"))
}

///|
test "one instantiation entry point calls every module in order" {
  let r = emit_package_multi([
    memory_importer(),
    memory_importer(),
    memory_importer(),
  ])
  let all = file_of(r.files, "all.mbt")
  assert_true(all.contains("pub fn moonlift_init_all() -> Unit {"))
  let body = all.find("m0_moonlift_init()").unwrap_or(-1)
  let mid = all.find("m1_moonlift_init()").unwrap_or(-1)
  let last = all.find("m2_moonlift_init()").unwrap_or(-1)
  assert_true(body >= 0 && mid > body && last > mid)
}

///|
test "exports keep their published name behind the prefix" {
  let r = emit_package_multi([memory_importer(), memory_importer()])
  let exports = file_of(r.files, "exports.mbt")
  assert_true(exports.contains("pub fn m0_peek("))
  assert_true(exports.contains("pub fn m1_peek("))
}

///|
test "the package files are written once, not per module" {
  let r = emit_package_multi([memory_importer(), memory_importer()])
  let mut mod_seen = 0
  let mut pkg_seen = 0
  for f in r.files {
    if f.name == "moon.mod" {
      mod_seen = mod_seen + 1
    }
    if f.name == "moon.pkg" {
      pkg_seen = pkg_seen + 1
    }
  }
  assert_eq(mod_seen, 1)
  assert_eq(pkg_seen, 1)
}

///|
/// A module that imports `env.tab (table 2)`, defines `$answer` (function 0, which
/// returns the constant in `code`) and `a_slot0` (function 1, `call_indirect` on
/// slot 0), and — when `with_elem` — fills slot 0 with function 0.
///
/// Type: `() -> i32`. Import: one table, min 2.
fn table_importer(code : Bytes, with_elem : Bool) -> Module raise ReadFail {
  let parts : Array[Bytes] = [
    header(),
    // type: () -> i32
    b"\x01\x05\x01\x60\x00\x01\x7f",
    // import: 1 entry, "env" "tab" table funcref min=2
    b"\x02\x0d\x01\x03env\x03tab\x01\x70\x00\x02",
    // function: two functions, both type 0
    b"\x03\x03\x02\x00\x00",
    // export "a_slot0" as func 1
    b"\x07\x0b\x01\x07a_slot0\x00\x01",
  ]
  if with_elem {
    // element: table 0, offset 0, funcs [0]
    parts.push(b"\x09\x07\x01\x00\x41\x00\x0b\x01\x00")
  }
  parts.push(code)
  decode(cat(parts))
}

///|
/// Code section: `$answer` returns 42, `a_slot0` calls indirect slot 0.
fn code_42() -> Bytes {
  b"\x0a\x0e\x02\x04\x00\x41\x2a\x0b\x07\x00\x41\x00\x11\x00\x00\x0b"
}

///|
/// Code section: `$answer` returns 7 (the value module 1's own function 0 has).
fn code_7() -> Bytes {
  b"\x0a\x0e\x02\x04\x00\x41\x07\x0b\x07\x00\x41\x00\x11\x00\x00\x0b"
}

///|
test "a shared table numbers functions across the package, not per module" {
  // Two modules, same table, same signature. Module 0 fills slot 0 with its
  // function 0 (42); module 1 calls through slot 0 and its own function 0
  // returns 7. A per-module index would answer 7 — the bug `shared_tab_*` exists
  // to catch. The arms below are the mechanism: module 1's dispatcher has to
  // name module 0's function.
  let r = emit_package_multi([
    table_importer(code_42(), true),
    table_importer(code_7(), false),
  ])
  let body = file_of(r.files, "module.mbt")
  // Module 0's element segment writes a package-wide index; its own is 0.
  assert_true(body.contains("t.set(at0 + 0, 0)"))
  // Module 0's arms: its own 0/1, then module 1's 2/3.
  assert_true(body.contains("    0 => m0_f0()"))
  assert_true(body.contains("    2 => m1_f0()"))
  // Module 1's arms start at 2 (module 0 has two functions), and reach back.
  assert_true(body.contains("    3 => m1_f1()"))
  assert_true(body.contains("    1 => m0_f1()"))
}

///|
test "one module keeps local table indices" {
  // The single-module path: base 0, no siblings, so the slot holds exactly the
  // index the wasm wrote and the arms are the module's own functions.
  let r = emit_package_multi([table_importer(code_42(), true)])
  let body = file_of(r.files, "module.mbt")
  assert_true(body.contains("t.set(at0 + 0, 0)"))
  assert_true(body.contains("    1 => f1()"))
  assert_false(body.contains("m0_"))
}
