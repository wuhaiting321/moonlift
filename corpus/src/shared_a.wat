;; One of two modules that import the same memory.
;;
;; `shared_a` owns a data segment and the `memory.grow`; `shared_b` only
;; observes. Decompiled together they become one MoonBit package, so the host
;; can hand both the *same* `Memory` — which is what makes `grow` in A visible
;; through `size` in B, as it is in a real wasm embedder.
(module
  (import "env" "mem" (memory 1 4))

  ;; 42, little-endian, at address 8. Copying this into the shared memory at
  ;; instantiation is what `shared_b` reads back.
  (data (i32.const 8) "\2a\00\00\00")

  ;; memory.grow returns the *previous* size in pages, or -1.
  (func (export "grow") (param $n i32) (result i32)
    local.get $n
    memory.grow)

  ;; A write B can see: same instance, so the byte is there for `peek`.
  (func (export "store") (param $addr i32) (param $v i32)
    local.get $addr
    local.get $v
    i32.store8))
