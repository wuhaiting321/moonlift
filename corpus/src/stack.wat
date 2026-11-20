;; stack.wat — the shapes that decide whether expression recovery is correct.
;;
;; Every function here would be *decompiled wrongly* by a decompiler that builds
;; expression trees and evaluates them at the point of use, without checking what
;; happens in between. They are small on purpose: each one isolates a single way
;; in which deferring an expression changes the meaning of the program.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (memory 1)
  (global $g (mut i32) (i32.const 5))

  (func $id (param i32) (result i32)
    local.get 0)

  ;; A read of a local that stays live across an overwrite of the same local.
  ;; `local 0` is read first and consumed last, so the assignment in between is
  ;; only harmless if the read is materialised before it.
  (func $across (export "across") (param $x i32) (result i32)
    local.get $x
    i32.const 7
    local.set $x
    local.get $x
    i32.add)

  ;; The same hazard through memory: a load that stays live across a store to
  ;; the address it read. Deferring the load past the store would return 99
  ;; instead of the value that was there.
  (func $reload (export "reload") (param $p i32) (result i32)
    local.get $p
    i32.load
    local.get $p
    i32.const 99
    i32.store)

  ;; A call executes where it appears, so its result cannot be carried on the
  ;; stack as an expression: each one costs a temporary.
  (func $forced (export "forced") (param i32) (result i32)
    local.get 0
    call $id
    call $id
    i32.const 1
    i32.add)

  ;; A discarded call result: the call still has to happen, so the expression
  ;; survives even though nothing consumes its value.
  (func $discard (export "discard") (param i32) (result i32)
    local.get 0
    call $id
    drop
    local.get 0)

  ;; `local.tee` pushes a read of the local it just wrote. That read is only
  ;; valid until the next write, and there is none, so this must *not* spill.
  (func $tee (export "tee") (param i32) (result i32)
    local.get 0
    i32.const 1
    i32.add
    local.tee 0
    local.get 0
    i32.mul)

  ;; A global read kept across a call. The callee is free to write the global,
  ;; so the read has to happen before the call — the same hazard as the local and
  ;; the load, one indirection away.
  (func $across_call (export "across_call") (param i32) (result i32)
    global.get $g
    local.get 0
    call $id
    i32.add)

  ;; A value that crosses a block boundary: the block's entry is a stack shape,
  ;; and the value it received is named as a parameter rather than inlined from
  ;; the predecessor.
  (func $across_block (export "across_block") (param i32) (result i32)
    local.get 0
    block (result i32)
      local.get 0
      i32.const 1
      i32.add
    end
    i32.add))
