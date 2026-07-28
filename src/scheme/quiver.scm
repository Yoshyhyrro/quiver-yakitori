(import (chicken base)
        (chicken foreign)
        (chicken format)
        (srfi 4))

;; Link to the external C23 implementation
;; Do NOT implement the C logic here anymore
(foreign-declare "
extern float c23_to_bf16(float f);
extern float c23_to_fp8(float f);
")

;; Bind the external C functions to Scheme identifiers
(define q-bf16 (foreign-lambda float "c23_to_bf16" float))
(define q-fp8  (foreign-lambda float "c23_to_fp8" float))

(define (quantizer-for mode)
  (cond ((eq? mode 'bf16) q-bf16)
        ((eq? mode 'fp8)  q-fp8)
        (else (lambda (x) x))))

;; ------------------------------------------------------------------
;; 2x2 matrix, stored as a flat f32vector: #(a b c d) = [[a b] [c d]]
;;
;; This replaces the previous SRFI-63 array representation. f32vector
;; is a CHICKEN core extension (part of SRFI-4, bundled with the base
;; install) so it needs no external egg fetch, and it guarantees
;; genuine IEEE-754 float32 storage -- which the old '#() prototype
;; (a generic, untyped SRFI-63 prototype) did not actually pin down.
;; ------------------------------------------------------------------

(define (make-matrix a b c d)
  (f32vector a b c d))

(define (mref m row col) (f32vector-ref m (+ (* row 2) col)))

(define (matrix-map f m)
  (make-matrix (f (mref m 0 0)) (f (mref m 0 1))
               (f (mref m 1 0)) (f (mref m 1 1))))

;; Raw (full-precision) 2x2 matrix product; no quantization applied.
(define (matrix-multiply-raw m1 m2)
  (make-matrix
   (+ (* (mref m1 0 0) (mref m2 0 0)) (* (mref m1 0 1) (mref m2 1 0)))
   (+ (* (mref m1 0 0) (mref m2 0 1)) (* (mref m1 0 1) (mref m2 1 1)))
   (+ (* (mref m1 1 0) (mref m2 0 0)) (* (mref m1 1 1) (mref m2 1 0)))
   (+ (* (mref m1 1 0) (mref m2 0 1)) (* (mref m1 1 1) (mref m2 1 1)))))

;; ------------------------------------------------------------------
;; Two composition orders ("double shuffle" experiment)
;;
;; Let Q be the quantization map (q-fp8 / q-bf16 / identity for raw).
;; In the continuum (Q = identity) these two paths are identical:
;;     Q(Q(A) @ Q(B)) = Q(A @ B) = A @ B
;; On a coarse quantization grid they generally are not, since Q is a
;; nonlinear projection onto a finite grid. This is the discrete
;; analogue of the shuffle/stuffle products agreeing at a generic
;; point but failing to commute at a degenerate one.
;;
;;   shuffle path: quantize BOTH operands before combining, then
;;                 quantize the result again  -> Q(Q(A) @ Q(B))
;;   stuffle path: combine at full precision first, quantize once
;;                 afterward                  -> Q(A @ B)
;; ------------------------------------------------------------------

(define (quiver-multiply-shuffle m1 m2 mode)
  (let ((q (quantizer-for mode)))
    (matrix-map q (matrix-multiply-raw (matrix-map q m1) (matrix-map q m2)))))

(define (quiver-multiply-stuffle m1 m2 mode)
  (let ((q (quantizer-for mode)))
    (matrix-map q (matrix-multiply-raw m1 m2))))

;; Preserves the original name/signature used by existing callers.
(define quiver-multiply quiver-multiply-stuffle)

;; Track a single orbit under one composition rule and print each step.
(define (detect-17-cycle m-init max-steps mode #!optional (compose quiver-multiply-stuffle))
  (let loop ((current m-init)
             (step 0))
    (if (>= step max-steps)
        (printf "Simulation finished\n")
        (begin
          (printf "Step ~A: RegState = ~A\n" step (mref current 0 0))
          (loop (compose current m-init mode) (+ step 1))))))

;; Run both composition orders side by side and report their
;; divergence at each step -- the actual "double shuffle" observation.
(define (observe-double-shuffle m-init max-steps mode)
  (printf "=== Double-Shuffle Divergence (mode = ~A) ===\n" mode)
  (printf "step  shuffle:Q(Q(A)Q(B))    stuffle:Q(A@B)      |diff|\n")
  (let loop ((shuffle-state m-init)
             (stuffle-state m-init)
             (step 0))
    (if (>= step max-steps)
        (printf "Simulation finished\n")
        (let ((rs (mref shuffle-state 0 0))
              (rt (mref stuffle-state 0 0)))
          (printf "~A     ~A     ~A     ~A\n" step rs rt (abs (- rs rt)))
          (loop (quiver-multiply-shuffle shuffle-state m-init mode)
                (quiver-multiply-stuffle  stuffle-state  m-init mode)
                (+ step 1))))))

;; ------------------------------------------------------------------
;; Vendored constants (NOT a live chicken-install dependency)
;;
;; These two values are copied from Yoshyhyrro/hatsu-yakitori's
;; core/machine_constants.scm. As of release v0.4.8 that egg is not
;; actually chicken-install-able: core.setup uses an invalid CHICKEN5
;; .egg structure (multiple top-level forms instead of one wrapping
;; list, plus a "name" key CHICKEN5 doesn't recognize, plus CRLF line
;; endings), and machine_constants.scm imports srfi-1 without
;; declaring it in the egg's dependencies. Both are reproducible
;; independently of network access, so they are not sandbox-specific.
;; Vendoring avoids coupling quiver-yakitori's CI to that repo's
;; release hygiene; revisit as a real egg dependency once fixed.
;; ------------------------------------------------------------------

(define machine-epsilon (expt 2.0 -52))
(define default-tolerance 1e-10)

;; 1 ULP of the E4M3 grid at a given magnitude (normal range only;
;; this implementation has no true subnormals -- see quiver_c23.c).
(define (fp8-e4m3-ulp magnitude)
  (if (= magnitude 0.0)
      (expt 2.0 -6)
      (let ((exponent (inexact->exact (floor (/ (log (abs magnitude)) (log 2.0))))))
        (expt 2.0 (- exponent 3)))))

;; ------------------------------------------------------------------
;; Constant harvesting: run the double-shuffle experiment and reduce
;; it to a small set of scalar invariants, suitable for logging and
;; later cross-referencing against independently-derived constants
;; (e.g. on the Lean side of the project). Two states are considered
;; to "agree" at a step if their difference is within
;; default-tolerance, rather than requiring bit-exact equality.
;; ------------------------------------------------------------------

(define (harvest-constants m-init max-steps mode)
  (let loop ((shuffle-state m-init)
             (stuffle-state m-init)
             (step 0)
             (onset #f)            ; first step where diff > default-tolerance
             (max-diff 0.0)
             (max-diff-steps '())  ; steps achieving max-diff
             (agree-count 0))
    (if (>= step max-steps)
        (list (cons 'mode mode)
              (cons 'max-steps max-steps)
              (cons 'onset-step onset)
              (cons 'agree-count agree-count)
              (cons 'max-diff max-diff)
              (cons 'max-diff-steps (reverse max-diff-steps))
              (cons 'max-diff-ulp-ratio (/ max-diff (fp8-e4m3-ulp 1.0))))
        (let* ((rs (mref shuffle-state 0 0))
               (rt (mref stuffle-state 0 0))
               (d  (abs (- rs rt)))
               (agrees? (< d default-tolerance)))
          (loop (quiver-multiply-shuffle shuffle-state m-init mode)
                (quiver-multiply-stuffle  stuffle-state  m-init mode)
                (+ step 1)
                (or onset (and (not agrees?) step))
                (max max-diff d)
                (cond ((> d max-diff) (list step))
                      ((= d max-diff) (cons step max-diff-steps))
                      (else max-diff-steps))
                (+ agree-count (if agrees? 1 0)))))))

(define (print-harvest h)
  (for-each (lambda (kv) (printf "~A: ~A\n" (car kv) (cdr kv))) h))
(define theta (/ (* 2.0 3.141592653589793) 17.0))
(define cos-t (cos theta))
(define sin-t (sin theta))

(define register-node-17
  (make-matrix cos-t      (- sin-t)
               sin-t      cos-t))

(print "=== Driving 17-cycle Register Machine (Emergence via FP8) ===")
(detect-17-cycle register-node-17 35 'fp8)

(newline)
(observe-double-shuffle register-node-17 20 'fp8)

(newline)
(printf "=== Harvested constants (mode = fp8) ===\n")
(print-harvest (harvest-constants register-node-17 20 'fp8))