;; shared_tab_a.wat — one of two modules that import the same function table.
;;
;; A table is an externval in 1.0, so two modules can import one table and the
;; element segment of either module fills slots the other can then call through.
;; `shared_tab_a` is the writer: its element segment puts `$answer` in slot 0.
;;
;; The pair is built so that a per-module function index gives a wrong *number*
;; rather than a compile error: A's function 0 returns 42, B's function 0 returns
;; 7, and they both sit at index 0 of their own module. Only a package-wide index
;; space keeps them apart.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (type $ret (func (result i32)))

  (import "env" "tab" (table 2 2 funcref))

  ;; Function 0 of this module: the target the shared table points at.
  (func $answer (result i32)
    i32.const 42)

  (elem (i32.const 0) $answer)

  ;; A's own indirect call through the shared table: also 42, in A's dispatcher.
  (func (export "a_slot0") (result i32)
    i32.const 0
    call_indirect (type $ret)))
