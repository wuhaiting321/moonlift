;; fib.wat — a complete small program: recursion, a loop, memory traffic.
;;
;; This is the "does the whole pipeline hold together" fixture. It is small
;; enough to read the generated MoonBit by eye and decide whether the output is
;; recognisable as the program it came from.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (memory 1)

  (func $fib (export "fib") (param $n i32) (result i32)
    local.get $n
    i32.const 2
    i32.lt_s
    if (result i32)
      local.get $n
    else
      local.get $n
      i32.const 1
      i32.sub
      call $fib
      local.get $n
      i32.const 2
      i32.sub
      call $fib
      i32.add
    end)

  ;; Iterative variant, so the differential checker can compare the two.
  (func $fib_iter (export "fib_iter") (param $n i32) (result i32)
    (local $a i32)
    (local $b i32)
    (local $i i32)
    i32.const 1
    local.set $a
    loop $next
      local.get $i
      local.get $n
      i32.ge_s
      if
        local.get $a
        return
      end
      local.get $a
      local.get $b
      i32.add
      local.set $a
      local.get $a
      local.get $b
      i32.sub
      local.set $b
      local.get $i
      i32.const 1
      i32.add
      local.set $i
      br $next
    end
    local.get $a)

  ;; Ping-pong through memory: stores a value, reads it back from a byte offset.
  (func $roundtrip (export "roundtrip") (param $x i32) (result i32)
    i32.const 64
    local.get $x
    i32.store
    i32.const 64
    i32.load)
)
