;; The other half of the shared-memory pair.
;;
;; It imports the same memory as `shared_a` and never touches it except to
;; read: `pages` reports `memory.size`, `peek` reads one byte. Everything this
;; module can observe was done to the instance by the other module, which is
;; exactly the property a per-package copy of the memory destroys.
(module
  (import "env" "mem" (memory 1 4))

  (func (export "pages") (result i32)
    memory.size)

  (func (export "peek") (param $addr i32) (result i32)
    local.get $addr
    i32.load8_u))
