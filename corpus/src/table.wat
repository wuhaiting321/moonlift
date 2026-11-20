;; table.wat — function table, element segment, indirect calls.
;;
;; Purpose: `call_indirect` needs the type immediate decoded, a table index
;; validated, and an element segment that maps indices to functions. It is the
;; only construct where a wrong decoded index still compiles but calls the
;; wrong function, so it needs its own fixture.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (type $unary (func (param i32) (result i32)))

  (table $dispatch 4 4 funcref)
  (elem (i32.const 0) $inc $dec $dbl)

  (func $inc (type $unary)
    local.get 0
    i32.const 1
    i32.add)

  (func $dec (type $unary)
    local.get 0
    i32.const 1
    i32.sub)

  (func $dbl (type $unary)
    local.get 0
    i32.const 2
    i32.mul)

  (func $apply (export "apply") (param $sel i32) (param $x i32) (result i32)
    local.get $x
    local.get $sel
    call_indirect (type $unary))

  ;; Indirect call whose result is immediately consumed by another operation,
  ;; so the decoder cannot assume a call is always a statement.
  (func $apply_chain (export "apply_chain") (param i32) (result i32)
    local.get 0
    i32.const 0
    call_indirect (type $unary)
    i32.const 1
    call_indirect (type $unary)
    i32.const 2
    call_indirect (type $unary))

  ;; Direct call to a local function, for the call-graph edge.
  (func $twice (export "twice") (param i32) (result i32)
    local.get 0
    call $inc
    call $inc))
