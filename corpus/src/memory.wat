;; memory.wat — memory declaration, data segment, and every MVP load/store width.
;;
;; Purpose: exercise address operands (base + offset immediate + align hint) and
;; the signed/unsigned split on narrow loads, which is where a naive decoder
;; turns `i32.load8_s` into the wrong MoonBit expression.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (memory (export "mem") 1 2)

  ;; Non-zero offset, non-UTF-8 bytes: the data segment must survive byte-exact.
  (data (i32.const 16) "\de\ad\be\ef\00\01\02\03")

  (func $loads (export "loads") (param $p i32) (result i32)
    local.get $p
    i32.load
    local.get $p
    i32.load offset=4
    i32.add
    local.get $p
    i32.load offset=8 align=1
    i32.add
    local.get $p
    i32.load8_s
    i32.add
    local.get $p
    i32.load8_u
    i32.add
    local.get $p
    i32.load16_s offset=2
    i32.add
    local.get $p
    i32.load16_u
    i32.add)

  (func $loads64 (export "loads64") (param $p i32) (result i64)
    local.get $p
    i64.load
    local.get $p
    i64.load offset=8
    i64.add
    local.get $p
    i64.load8_s
    i64.add
    local.get $p
    i64.load8_u
    i64.add
    local.get $p
    i64.load16_s
    i64.add
    local.get $p
    i64.load16_u
    i64.add
    local.get $p
    i64.load32_s
    i64.add
    local.get $p
    i64.load32_u
    i64.add)

  (func $stores (export "stores") (param $p i32) (param $v i32) (result i32)
    local.get $p
    local.get $v
    i32.store
    local.get $p
    local.get $v
    i32.store offset=4
    local.get $p
    local.get $v
    i32.store8
    local.get $p
    local.get $v
    i32.store16 offset=2
    local.get $p
    local.get $v
    i64.extend_i32_s
    i64.store
    local.get $p
    local.get $v
    i32.store8 offset=15
    local.get $p
    i32.load)

  (func $floats (export "floats") (param $p i32) (result f64)
    local.get $p
    f64.load
    local.get $p
    f32.load offset=8
    f64.promote_f32
    f64.add
    local.get $p
    local.get $p
    f32.load offset=4
    f32.store
    local.get $p
    f32.load offset=4
    f64.promote_f32
    f64.add)

  (func $size (export "size") (result i32)
    memory.size)

  (func $grow (export "grow") (param i32) (result i32)
    local.get 0
    memory.grow))
