;; nested.wat — a `br_table` inside a loop inside a block.
;;
;; Purpose: the shape a `switch` inside a `for` compiles to. `control.wat` has a
;; `br_table` that leaves three block nests but no loop; `stack.wat` has loops but
;; no dispatch. Here the dispatch is *inside* the loop, one of its targets is a
;; back edge, and two of them return from inside nested blocks — so the structurer
;; has to put a `match` inside a `while true` and let its arms `continue`,
;; `return` and `break` in the same construct.
;;
;; The argument is masked to three bits on entry so that every input terminates:
;; the loop's step is always a decrement, and an unmasked 2^31 would make the
;; differential harness wait for two billion iterations — a property of the
;; fixture, not of the decompiler.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (func $route (export "route") (param i32) (result i32)
    local.get 0
    i32.const 7
    i32.and
    local.set 0
    block $out
      loop $again
        block $k0
          block $k1
            block $k2
              local.get 0
              br_table $k0 $k1 $k2
            end ;; $k2 — default: 2..7, and 0 is handled above
            local.get 0
            i32.const 1
            i32.sub
            local.set 0
            br $again
          end ;; $k1 — 1
          i32.const 100
          return
        end ;; $k0 — 0
        i32.const 7
        return
      end
    end
    i32.const -1
  )

  ;; The same dispatch with a value carried across the branch, so the structurer
  ;; has to write that value down at the edge — the last point where the
  ;; expression that produced it is still correct — rather than at the use site.
  (func $route_sum (export "route_sum") (param i32 i32) (result i32)
    (local i32)
    block $out (result i32)
      loop $again (result i32)
        block $k0 (result i32)
          block $k1 (result i32)
            block $k2 (result i32)
              local.get 0
              i32.const 3
              i32.and
              local.tee 0
              i32.const 2
              i32.lt_u
              if
                local.get 1
                i32.const 1
                i32.add
                local.set 1
              end
              local.get 1
              local.get 0
              br_table $k2 $k1 $k0
            end ;; $k2 — 0: go round again
            local.get 0
            i32.const 1
            i32.sub
            local.set 0
            br $again
          end ;; $k1 — 1
          i32.const 10
          i32.add
          br $out
        end ;; $k0 — 2, 3 and anything that wrapped to a large index
        i32.const 3
        i32.mul
        br $out
      end
    end
  )
)
