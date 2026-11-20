;; imports.wat — function imports and exports of every kind.
;;
;; Purpose: imported functions occupy the low end of the function index space,
;; so every `call` index in this module is offset by the import count. Getting
;; that wrong is silent: the module still decodes, and the generated code calls
;; the wrong function. Also exercises an export name that is not a valid MoonBit
;; identifier, which `info` reports and codegen must sanitise.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (import "env" "log" (func $log (param i32)))
  (import "env" "get" (func $get (result i32)))
  (import "env" "scale" (func $scale (param i32 i32) (result i32)))

  (memory (export "memory") 1)
  (global (export "version") i32 (i32.const 3))

  (func $twice (export "twice") (result i32)
    call $get
    i32.const 2
    call $scale
    call $log
    call $get)

  (func $local_only (result i32)
    i32.const 7)

  (func (export "with-dash") (result i32)
    call $local_only)
  (export "with space" (func $local_only)))
