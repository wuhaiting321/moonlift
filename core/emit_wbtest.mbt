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
