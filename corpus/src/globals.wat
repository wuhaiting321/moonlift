;; globals.wat — immutable and mutable globals, initialisers, and a start func.
;;
;; Purpose: the global section is the one place where a constant expression of
;; each value type appears at module scope, and mutable globals are the reason the decompiler
;; cannot treat globals as MoonBit `let` bindings.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (global $counter (mut i32) (i32.const -40))
  (global $mask i64 (i64.const -6148914691236517206))
  (global $pi f32 (f32.const 0x1.921fb6p+1))
  (global $e f64 (f64.const 0x1.5bf0a8b145769p+1))
  (global $ready (mut i32) (i32.const 0))
  (global $derived i32 (i32.const 5))

  (func $init (global.set $ready (i32.const 1)))
  (start $init)

  (func $bump (export "bump") (param i32) (result i32)
    global.get $counter
    local.get 0
    i32.add
    global.set $counter
    global.get $counter)

  (func $read (export "read") (result i64)
    global.get $mask
    global.get $counter
    i64.extend_i32_s
    i64.add
    global.get $derived
    i64.extend_i32_s
    i64.add)

  (func $floats (export "floats") (result f64)
    global.get $pi
    f64.promote_f32
    global.get $e
    f64.add)

  (func $is_ready (export "is_ready") (result i32)
    global.get $ready))
