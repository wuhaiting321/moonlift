// Behavioural test for the package generated from two modules that import the
// same function table, copied in by `script/merge.sh`:
//
//   moonlift decompile corpus/good/shared_tab_a.wasm corpus/good/shared_tab_b.wasm -o pkg
//
// A table is an externval in WebAssembly 1.0, exactly like a memory: two modules
// may import one table, and the element segment of either module fills slots the
// other can then call through. `shared_tab_a` fills slot 0 with its function 0
// (which returns 42); `shared_tab_b` only calls through slot 0, and its own
// function 0 returns 7.
//
// The 42 below is the point. It is a value that exists nowhere in module 1: it is
// module 0's function, reached through the table the host handed to both. An
// implementation that keys table slots by *per-module* function index answers 7
// here — every module has an `f0` — which is why the two modules disagree on what
// function 0 returns.
//
// What a real embedder sees:
//
//   a.a_slot0()  = 42   (A's own slot, its own function)
//   b.b_slot0()  = 42   (A's function, through the shared table)
//
// `b_slot1` would read the one slot nobody filled and trap; a trap aborts the
// process, so that case lives in `script/indirect.sh` rather than here.

///|
test "one table: a slot filled by m0 is callable from m1" {
  let tab = Table::new(2)
  m0_moonlift_bind({ env_tab: tab })
  m1_moonlift_bind({ env_tab: tab })
  moonlift_init_all()
  // m0's element segment wrote its function 0 into slot 0, as a package-wide
  // index — the same array is visible from both accessors.
  inspect(m0_table().get(0), content="0")
  inspect(m1_table().get(0), content="0")
  inspect(m0_a_slot0(), content="42")
  inspect(m1_b_slot0(), content="42")
}

///|
test "one table: the slot nobody filled stays null" {
  let tab = Table::new(2)
  m0_moonlift_bind({ env_tab: tab })
  m1_moonlift_bind({ env_tab: tab })
  moonlift_init_all()
  inspect(m1_table().get(1), content="-1")
}

///|
test "two tables: m1's own table is not filled by m0's segment" {
  // The contrast that makes the test above mean something: the sharing is the
  // host's choice of table, not something the merge does behind its back. m1
  // still compiles and its own table is empty, so calling through slot 0 here
  // would trap — which is the correct behaviour for an unshared table.
  m0_moonlift_bind({ env_tab: Table::new(2) })
  m1_moonlift_bind({ env_tab: Table::new(2) })
  moonlift_init_all()
  inspect(m0_table().get(0), content="0")
  inspect(m1_table().get(0), content="-1")
  inspect(m0_a_slot0(), content="42")
}
