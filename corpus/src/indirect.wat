;; indirect.wat — the function table, end to end.
;;
;; Purpose: `table.wasm` proves that a `call_indirect` decodes and runs. This
;; fixture proves that the *whole* construct survives the migration:
;;
;;   - three different signatures in one table, so the dispatcher cannot be a
;;     single function type;
;;   - slots 5..7 left uninitialised, so a call through them must trap;
;;   - a method table read out of linear memory, which is how C++ virtual
;;     dispatch and Rust `dyn` calls compile;
;;   - indirect calls chained through each other and inside a loop, so the
;;     index is a real run-time value rather than a constant the decompiler
;;     could fold away;
;;   - a function reached both directly and through the table, so the two
;;     calling conventions meet in one body.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (type $unary (func (param i32) (result i32)))
  (type $binary (func (param i32 i32) (result i32)))
  (type $nullary (func (result i32)))

  (memory 1)
  ;; A method table in data memory: i32 indices 0..4, one per table slot.
  (data (i32.const 0)
    "\00\00\00\00\01\00\00\00\02\00\00\00\03\00\00\00\04\00\00\00")

  ;; Eight slots, five filled. 5..7 stay null, which is a trap, not a zero.
  (table 8 8 funcref)
  (elem (i32.const 0) $add1 $dbl $add $mul $const)

  (func $add1 (type $unary) (i32.add (local.get 0) (i32.const 1)))
  (func $dbl (type $unary) (i32.mul (local.get 0) (i32.const 2)))
  (func $add (type $binary) (i32.add (local.get 0) (local.get 1)))
  (func $mul (type $binary) (i32.mul (local.get 0) (local.get 1)))
  (func $const (type $nullary) (i32.const 42))

  ;; sel in 0..1 works, 2..4 is a type mismatch, 5..7 is null, 8.. is out of
  ;; bounds. All four cases are reachable from the export, so the differential
  ;; harness can compare them.
  (func (export "apply1") (param i32 i32) (result i32)
    (call_indirect (type $unary) (local.get 1) (local.get 0)))

  (func (export "apply2") (param i32 i32 i32) (result i32)
    (call_indirect (type $binary) (local.get 1) (local.get 2) (local.get 0)))

  (func (export "apply0") (param i32) (result i32)
    (call_indirect (type $nullary) (local.get 0)))

  ;; The index comes from linear memory, not from an immediate: this is the
  ;; shape a real vtable call takes.
  (func (export "vt") (param i32 i32) (result i32)
    (call_indirect (type $unary)
      (local.get 1)
      (i32.load (i32.mul (local.get 0) (i32.const 4)))))

  ;; One indirect call feeding another, and the result feeding a direct call.
  (func (export "chain") (param i32) (result i32)
    (call_indirect (type $unary)
      (call $add1 (call_indirect (type $unary) (local.get 0) (i32.const 0)))
      (i32.const 1)))

  ;; A loop whose body dispatches between slot 0 and slot 1 every iteration.
  ;; The trip count is masked to 0..255: the harness runs every export for the
  ;; extreme i32 values too, and two billion indirect calls is not a test.
  (func (export "loopdispatch") (param $start i32) (param $bound i32) (result i32)
    (local $i i32)
    (local $acc i32)
    (local.set $acc (local.get $start))
    (local.set $bound (i32.and (local.get $bound) (i32.const 255)))
    (block $done
      (loop $again
        (br_if $done (i32.ge_s (local.get $i) (local.get $bound)))
        (local.set $acc
          (call_indirect (type $unary)
            (local.get $acc)
            (i32.and (local.get $i) (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $again)))
    (local.get $acc))

  ;; The same function reached both ways in one expression.
  (func (export "mixed") (param i32) (result i32)
    (i32.add
      (call $add1 (local.get 0))
      (call_indirect (type $unary) (local.get 0) (i32.const 0)))))
