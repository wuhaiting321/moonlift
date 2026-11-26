// Behavioural smoke test for the package generated from `corpus/good/imported.wasm`.
//
// This file is copied into the generated package by `script/check.sh`. Every
// expected value below came from running the *original* module in Node, with the
// host the module expects (one page of memory, an eight-slot table, `base` and
// `bump` globals):
//
//   cd corpus/tools && node oracle.js ../good/imported.wasm \
//     '[["load0",[]],["loadbase",[]],["bump1",[]],["viabase",[0]]]' \
//     /tmp/impplan/calls.tsv '{"env.base":4}'
//
//   load0() = 97   loadbase() = 88   bump1() = 1   viabase(0) = 10
//
// `base = 4` is the point of the test. With the default base of 0 the two data
// segments overlap and a wrong offset still reads the right byte; with base = 4
// `load0` reads the constant segment ('a', 97) and `loadbase` reads the segment
// that moved ('X', 88), and table[4] — filled by the element segment placed at
// `base` — is the only non-empty slot `viabase(0)` can reach, since the constant
// element segment fills 2 and 3.

///|
test "the host binds the instances, and the segments follow them" {
  // Binding, not pre-filling: a fresh memory is handed over, and
  // `moonlift_init()` is what copies the module's segments into it.
  moonlift_bind({
    env_tbl: Table::new(8),
    env_mem: Memory::new(1, 2),
    env_base: Ref(4),
    env_bump: Ref(0),
  })
  moonlift_init()
  inspect(load0(), content="97")
  inspect(loadbase(), content="88")
}

///|
test "an element segment placed at an imported global fills that slot" {
  inspect(viabase(0), content="10")
}

///|
test "an imported mutable global is the module's own state" {
  inspect(bump1(), content="1")
  inspect(bump1(), content="2")
}

///|
test "the imported memory has the size the module asked for" {
  inspect(memsize(), content="1")
}
