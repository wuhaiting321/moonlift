///|
/// Tests for the `info` report.
///
/// The report is a pure function of the IR, so it can be asserted without a
/// process. These tests pin the *shape* of the output — the lines a user and the
/// check script grep for — rather than the exact padding, which would make every
/// cosmetic tweak a test failure.

///|
/// A module with one type, one function, one memory, one global and one export,
/// assembled from section literals rather than from a file.
fn sample_module() -> Module raise ReadFail {
  decode(
    cat([
      header(),
      // type: (i32) -> i32
      b"\x01\x06\x01\x60\x01\x7f\x01\x7f",
      // function: one function, type 0
      b"\x03\x02\x01\x00",
      // memory: min 1
      b"\x05\x03\x01\x00\x01",
      // global i32 = 7
      b"\x06\x06\x01\x7f\x00\x41\x07\x0b",
      // export "f" as func 0
      b"\x07\x05\x01\x01f\x00\x00",
      // code: no locals, local.get 0, end
      b"\x0a\x06\x01\x04\x00\x20\x00\x0b",
    ]),
  )
}

///|
test "report names every section and every count" {
  let m = sample_module()
  let text = report(m, "sample.wasm")
  assert_true(text.contains("file      sample.wasm"))
  assert_true(text.contains("sections  6"))
  assert_true(text.contains("functions 1 defined, 0 imported"))
  assert_true(text.contains("memories  1"))
  assert_true(text.contains("min=1, no max"))
  assert_true(text.contains("globals   1"))
  assert_true(text.contains("exports   1 (func 1)"))
  assert_true(text.contains("code      1 bodies"))
}

///|
test "report lists the function with its signature and index label" {
  let m = sample_module()
  let text = report(m, "sample.wasm")
  assert_true(text.contains("functions\n"))
  assert_true(text.contains("(i32) -> i32"))
  assert_true(text.contains("$f0"))
}

///|
test "report flags the absence of a name section" {
  let m = sample_module()
  assert_true(report(m, "sample.wasm").contains("no name section"))
}

///|
test "valid export names need no sanitising" {
  let m = sample_module()
  assert_eq(rename_count(m), 0)
}

///|
test "clip keeps short strings intact and marks long ones" {
  assert_eq(clip("abc", 8), "abc")
  assert_eq(clip("abcdefgh", 8), "abcdefgh")
  assert_eq(clip("abcdefghij", 8), "abcdef..")
}
