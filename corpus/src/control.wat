;; control.wat — every MVP control construct, in the shapes compilers emit.
;;
;; This is the fixture that matters most for S6 (relooper): a `br_table` that
;; jumps out of nested blocks, a loop with a back edge and a `br_if`, an
;; `if`/`else` with a result, and a `return` in the middle of a block.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  ;; Four-way dispatch that leaves the block nest at different depths.
  (func $classify (export "classify") (param i32) (result i32)
    block $out
      block $three
        block $two
          block $one
            local.get 0
            br_table $one $two $three $out
          end
        end
        i32.const 200
        return
      end
      i32.const 300
      return
    end
    i32.const 400)

  ;; Loop with a counter, a conditional exit and a back edge: the canonical
  ;; irreducible-looking shape that is actually reducible.
  (func $sum_to (export "sum_to") (param $n i32) (result i32)
    (local $acc i32)
    (local $i i32)
    loop $continue
      local.get $i
      local.get $n
      i32.ge_s
      if
        br 1
      end
      local.get $acc
      local.get $i
      i32.add
      local.set $acc
      local.get $i
      i32.const 1
      i32.add
      local.set $i
      br $continue
    end
    local.get $acc)

  ;; if/else as an expression: both arms leave one value.
  (func $abs (export "abs") (param i32) (result i32)
    local.get 0
    i32.const 0
    i32.lt_s
    if (result i32)
      i32.const 0
      local.get 0
      i32.sub
    else
      local.get 0
    end)

  ;; Nested if without else, plus an early return and a trap.
  (func $guard (export "guard") (param i32) (result i32)
    local.get 0
    i32.eqz
    if
      unreachable
    end
    local.get 0
    i32.const 0
    i32.lt_s
    if
      i32.const 0
      return
    end
    local.get 0)

  ;; `block` used as a forward branch target, the shape that a `break` compiles
  ;; to when the language has no early return.
  (func $find_limit (export "find_limit") (param i32) (result i32)
    (local $i i32)
    block $done
      loop $scan
        local.get $i
        local.get 0
        i32.ge_s
        br_if $done
        local.get $i
        i32.const 7
        i32.eq
        if
          local.get $i
          return
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $scan
      end
    end
    i32.const -1)

  ;; Select between two results at the end of a block, so the block result type
  ;; is only implied by the operand stack.
  (func $max (export "max") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    local.get 0
    local.get 1
    i32.gt_s
    select))
