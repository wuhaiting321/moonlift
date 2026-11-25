// Behavioural test for the package generated from two modules that import the
// same memory, copied in by `script/merge.sh`:
//
//   moonlift decompile corpus/good/shared_a.wasm corpus/good/shared_b.wasm -o pkg
//
// `shared_a` grows the memory and owns a data segment; `shared_b` only observes.
// Every expected value below is what a real embedder would see when it hands one
// `WebAssembly.Memory` to both modules:
//
//   a.data  at 8 = 42 (from shared_a's data segment)
//   b.pages()          = 1
//   a.grow(1)          = 1   (memory.grow answers with the *previous* size)
//   b.pages()          = 2
//   a.store(100, 7); b.peek(100) = 7
//
// The last two are the point. Each generated package carries its own copy of
// `runtime.mbt`, so `pkg_a.Memory` and `pkg_b.Memory` are different types and no
// host could pass one instance to both — the two modules would each grow a
// private memory and `b.pages()` would stay 1. In one package there is one type,
// and the assertions below are ordinary.

///|
test "one memory: a segment written by m0 is readable through m1" {
  let shared = Memory::new(1, 4)
  m0_moonlift_bind({ env_mem: shared })
  m1_moonlift_bind({ env_mem: shared })
  moonlift_init_all()
  inspect(m1_peek(8), content="42")
}

///|
test "one memory: grow in m0 is visible as size in m1" {
  let shared = Memory::new(1, 4)
  m0_moonlift_bind({ env_mem: shared })
  m1_moonlift_bind({ env_mem: shared })
  moonlift_init_all()
  inspect(m1_pages(), content="1")
  inspect(m0_grow(1), content="1")
  inspect(m1_pages(), content="2")
}

///|
test "one memory: a store in m0 is a load in m1" {
  let shared = Memory::new(1, 4)
  m0_moonlift_bind({ env_mem: shared })
  m1_moonlift_bind({ env_mem: shared })
  moonlift_init_all()
  m0_store(100, 7)
  inspect(m1_peek(100), content="7")
}

///|
test "two instances: grow in m0 leaves m1 at one page" {
  // The contrast that makes the tests above mean something: the sharing is the
  // host's choice of instance, not something the merge does behind its back.
  m0_moonlift_bind({ env_mem: Memory::new(1, 4) })
  m1_moonlift_bind({ env_mem: Memory::new(1, 4) })
  moonlift_init_all()
  inspect(m0_grow(2), content="1")
  inspect(m1_pages(), content="1")
}
