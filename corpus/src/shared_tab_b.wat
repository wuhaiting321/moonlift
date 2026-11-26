;; shared_tab_b.wat — the other half of the shared-table pair.
;;
;; B never fills a slot; it only calls through slot 0, which A's element segment
;; filled. So the value B gets back (42) is a value that exists nowhere in B: it
;; is A's function, reached through the table the host handed to both.
;;
;; B's own function 0 returns 7 — so an implementation that keys the table by
;; per-module index answers 7 here instead of 42. That is the bug this fixture
;; exists to catch.
;;
;; Hand-written for moonlift; no upstream source. CC0.
(module
  (type $ret (func (result i32)))

  (import "env" "tab" (table 2 2 funcref))

  ;; Function 0 of this module. Never in the table: if it were, a per-module
  ;; index would look correct.
  (func $seven (result i32)
    i32.const 7)

  (func (export "b_slot0") (result i32)
    i32.const 0
    call_indirect (type $ret)))
