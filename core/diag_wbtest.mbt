///|
/// White-box tests for the diagnostic layer.
///
/// They live in `_wbtest.mbt` on purpose: constructing nullary enum variants
/// from *another* package is rejected by this toolchain ("read-only type"), so
/// taxonomy invariants are asserted here, inside `core`.
///
/// Guards against accidental renumbering — `BOUNDARY.md` and the CLI quote
/// these tags verbatim, so a silent change would be a breaking change.
test "error tags are unique and well formed" {
  let codes = all_codes()
  assert_eq(codes.length(), 19)
  let seen : Array[String] = []
  for c in codes {
    let tag = c.tag()
    assert_eq(tag.length(), 4)
    assert_false(seen.contains(tag))
    seen.push(tag)
  }
  assert_eq(codes[0].tag(), "E001")
  assert_eq(codes[17].tag(), "E108")
}

///|
test "every code has a non-empty hint that is not generic" {
  for c in all_codes() {
    assert_true(c.hint().length() > 10)
  }
}

///|
test "diag renders with byte offset" {
  let d = Diag::new(E004BadLeb128, 137, "LEB128 sequence of 5 bytes")
  assert_eq(d.render(), "E004 at byte 137: LEB128 sequence of 5 bytes")
  assert_true(d.render_verbose().contains("hint: corrupt length"))
}

///|
test "malformed vs unsupported classification" {
  assert_eq(E002BadMagic.kind(), "malformed input")
  assert_eq(E010BadData.kind(), "malformed input")
  assert_eq(E101Gc.kind(), "unsupported construct")
  assert_eq(E108Irreducible.kind(), "unsupported construct")
}
