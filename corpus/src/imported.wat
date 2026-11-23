;; imported.wat — the other three import kinds, and segments placed through them.
;;
;; Purpose: WebAssembly 1.0 lets a module import memory, table and global as well
;; as functions. A decompiler that only accepts function imports cannot compile a
;; module assembled from parts — which is most real output, because the memory and
;; the table are usually linked in from the host (`--import-memory`), and PIC
;; output places its data segments at a `global.get` of `__memory_base`.
;;
;; The module is built so that a wrong assumption is visible in a value, not just
;; in a compile error:
;;   - `(data (global.get $base) "XY")` lands at the host-supplied base, so
;;     `loadbase` reads 'X' whichever base the host picks, and `load0` reads 'a'
;;     only when the base is not 0.
;;   - `(elem (global.get $base) $double)` fills table[base], so `viabase` finds a
;;     function there at any base, and finds an empty slot when asked about index
;;     0 with a non-zero base.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (type $u (func (param i32) (result i32)))

  (import "env" "mem" (memory 1 2))
  (import "env" "tbl" (table 8 8 funcref))
  (import "env" "base" (global $base i32))
  (import "env" "bump" (global $bump (mut i32)))
  (import "env" "host_add" (func $host_add (param i32 i32) (result i32)))

  (func $double (type $u) (i32.mul (local.get 0) (i32.const 2)))
  (func $neg (type $u) (i32.sub (i32.const 0) (local.get 0)))

  ;; A constant-offset element segment, so the two paths (constant and
  ;; global) both appear in one module.
  (elem (i32.const 2) $double $neg)
  (elem (global.get $base) $double)

  (data (i32.const 0) "abc")
  (data (global.get $base) "XY")

  (func (export "load0") (result i32) (i32.load8_u (i32.const 0)))

  (func (export "loadbase") (result i32) (i32.load8_u (global.get $base)))

  (func (export "bump1") (result i32)
    (global.set $bump (i32.add (global.get $bump) (i32.const 1)))
    (global.get $bump))

  (func (export "viabase") (param i32) (result i32)
    (call_indirect (type $u)
      (i32.const 5)
      (i32.add (global.get $base) (local.get 0))))

  (func (export "memsize") (result i32) (memory.size))

  (func (export "hostcall") (param i32 i32) (result i32)
    (call $host_add (local.get 0) (local.get 1))))
