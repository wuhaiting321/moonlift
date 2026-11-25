;; alias.wat — one external cell, two import entries, and the reads that prove it.
;;
;; Purpose: WebAssembly 1.0 resolves an import by `(module, name)`, not by index.
;; A module may therefore import `env.counter` twice and get two global indices
;; that name *one* external cell: a write through the first is visible through
;; the second. That is the "shared instance" the spec means, and it is the case a
;; decompiler loses when it turns each import entry into an object of its own.
;;
;; The module is built so a broken alias shows up in a value: `bump` writes `$a`
;; and returns `$b`, `poke` writes `$b` and returns `$a`. If the two indices are
;; two cells, both functions answer with the value the caller passed in instead
;; of the incremented one.
;;
;; `$copy` covers the other half of instantiation: a defined global may be
;; initialised from an *immutable* imported one (a mutable global is rejected in
;; a constant expression by 1.0), and it has to take the value bound at init, not
;; the zero the stand-in happened to hold.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (import "env" "counter" (global $a (mut i32)))
  (import "env" "counter" (global $b (mut i32)))
  (import "env" "base" (global $base i32))

  (func (export "bump") (result i32)
    global.get $a
    i32.const 1
    i32.add
    global.set $a
    global.get $b)

  (func (export "peek") (result i32)
    global.get $b)

  (func (export "poke") (param i32) (result i32)
    local.get 0
    global.set $b
    global.get $a)

  (global $copy i32 (global.get $base))

  (func (export "copy") (result i32)
    global.get $copy))
