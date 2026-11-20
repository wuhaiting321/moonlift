;; arith.wat — every MVP numeric operator on the four value types.
;;
;; Purpose: force the instruction decoder (S3) and the expression builder (S7)
;; to handle the complete numeric opcode range, including sign/zero-split
;; division, the four conversion families, and bit reinterpretation.
;;
;; Hand-written for moonlift; no upstream source. CC0.
;;
;; Bodies are written in the flat (stack) form on purpose: that is what a real
;; compiler emits, and it is what the decompiler has to turn back into
;; expressions. Folded wat would test a form that never appears in the wild.
(module
  ;; Running-accumulator style: each instruction after the first binary op
  ;; consumes the accumulator plus one freshly pushed operand.
  (func $i32_bin (export "i32_bin") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add
    local.get 0
    i32.sub
    local.get 1
    i32.mul
    local.get 0
    i32.div_s
    local.get 1
    i32.rem_s
    local.get 0
    i32.and
    local.get 1
    i32.or
    local.get 0
    i32.xor
    local.get 0
    i32.shl
    local.get 1
    i32.shr_s
    local.get 0
    i32.shr_u
    local.get 1
    i32.rotl
    local.get 0
    i32.rotr
    local.get 1
    i32.div_u
    local.get 0
    i32.rem_u)

  (func $i32_un (export "i32_un") (param i32) (result i32)
    local.get 0
    i32.clz
    local.get 0
    i32.ctz
    i32.add
    local.get 0
    i32.popcnt
    i32.add
    local.get 0
    i32.eqz
    i32.add
    local.get 0
    local.get 0
    i32.eq
    i32.add
    local.get 0
    local.get 0
    i32.ne
    i32.add
    local.get 0
    local.get 0
    i32.lt_s
    i32.add
    local.get 0
    local.get 0
    i32.lt_u
    i32.add
    local.get 0
    local.get 0
    i32.gt_s
    i32.add
    local.get 0
    local.get 0
    i32.gt_u
    i32.add
    local.get 0
    local.get 0
    i32.le_s
    i32.add
    local.get 0
    local.get 0
    i32.le_u
    i32.add
    local.get 0
    local.get 0
    i32.ge_s
    i32.add
    local.get 0
    local.get 0
    i32.ge_u
    i32.add)

  (func $i64_ops (export "i64_ops") (param i64 i64) (result i64)
    local.get 0
    local.get 1
    i64.add
    local.get 0
    i64.mul
    local.get 1
    i64.div_s
    local.get 0
    i64.rem_u
    local.get 0
    i64.and
    local.get 1
    i64.or
    local.get 0
    i64.xor
    local.get 1
    i64.shl
    local.get 0
    i64.shr_s
    local.get 1
    i64.shr_u
    local.get 0
    i64.rotl
    local.get 1
    i64.rotr
    local.get 0
    i64.sub)

  (func $i64_cmp (export "i64_cmp") (param i64 i64) (result i32)
    local.get 0
    local.get 1
    i64.eq
    local.get 0
    local.get 1
    i64.lt_s
    i32.add
    local.get 0
    local.get 1
    i64.ge_u
    i32.add)

  (func $f32_ops (export "f32_ops") (param f32 f32) (result f32)
    local.get 0
    local.get 1
    f32.add
    local.get 0
    f32.sub
    local.get 1
    f32.mul
    local.get 0
    f32.div
    local.get 1
    f32.min
    local.get 0
    f32.max
    local.get 1
    f32.copysign
    f32.abs
    f32.neg
    f32.ceil
    f32.floor
    f32.trunc
    f32.nearest
    f32.sqrt)

  (func $f64_ops (export "f64_ops") (param f64 f64) (result f64)
    local.get 0
    local.get 1
    f64.add
    local.get 0
    f64.sub
    local.get 1
    f64.mul
    local.get 0
    f64.div
    local.get 1
    f64.min
    local.get 0
    f64.max
    local.get 1
    f64.copysign
    f64.abs
    f64.neg
    f64.ceil
    f64.floor
    f64.trunc
    f64.nearest
    f64.sqrt)

  (func $f_cmp (export "f_cmp") (param f64 f64) (result i32)
    local.get 0
    local.get 1
    f64.eq
    local.get 0
    local.get 1
    f64.lt
    i32.add
    local.get 0
    local.get 1
    f64.ge
    i32.add)

  (func $convert (export "convert") (param i32 i64 f32 f64) (result f64)
    local.get 0
    f64.convert_i32_s
    local.get 0
    f64.convert_i32_u
    f64.add
    local.get 1
    f64.convert_i64_u
    f64.add
    local.get 1
    f64.convert_i64_s
    f64.add
    local.get 2
    f64.promote_f32
    f64.add
    local.get 3
    f64.add)

  (func $narrow (export "narrow") (param i64 f64) (result i32)
    local.get 0
    i32.wrap_i64
    local.get 0
    i32.wrap_i64
    i64.extend_i32_u
    i32.wrap_i64
    i32.add
    local.get 0
    i32.wrap_i64
    i64.extend_i32_s
    i32.wrap_i64
    i32.add
    local.get 1
    f32.demote_f64
    i32.trunc_f32_s
    i32.add
    local.get 1
    i64.trunc_f64_s
    i32.wrap_i64
    i32.add)

  (func $trunc (export "trunc") (param f64 f32) (result i32)
    local.get 0
    i32.trunc_f64_s
    local.get 0
    i32.trunc_f64_u
    i32.add
    local.get 1
    i32.trunc_f32_s
    i32.add
    local.get 1
    i32.trunc_f32_u
    i32.add
    local.get 0
    i64.trunc_f64_u
    i32.wrap_i64
    i32.add)

  (func $reinterpret (export "reinterpret") (param i32 i64 f64) (result i32)
    local.get 0
    f32.reinterpret_i32
    i32.reinterpret_f32
    local.get 1
    i32.wrap_i64
    i32.add
    local.get 2
    i64.reinterpret_f64
    i32.wrap_i64
    i32.add)

  ;; `select` is the one MVP operator whose result type depends on its operands
  ;; rather than on the opcode, which makes it a useful decoding trap.
  (func $pick (export "pick") (param i32 i32 i32) (result i32)
    local.get 0
    local.get 1
    local.get 2
    select)

  (func $drops (export "drops") (param i64 i64) (result i64)
    nop
    local.get 0
    local.get 1
    i64.add
    local.get 1
    drop
    i64.const -1
    i64.add
    i64.const 9223372036854775807
    i64.add)
)
