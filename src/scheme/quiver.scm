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
;; NxN matrix engine, stored as a record wrapping a flat row-major
;; f32vector: dim n, data of length n*n, entry (r,c) at r*n+c.
;;
;; This generalizes the previous hardcoded-2x2 representation (itself
;; a replacement for the old SRFI-63 array, which needed an external
;; egg fetch and did not actually guarantee float32 storage). f32vector
;; remains a CHICKEN core extension, no external egg needed.
;;
;; Division of labor in this project: quiver_c23.c owns the scalar
;; quantization primitive (what a single float rounds to under
;; FP8/BF16); this Scheme layer owns matrix algebra over that
;; primitive -- construction, raw and quantized products, and
;; equality/distance checks used to test algebraic identities.
;; ------------------------------------------------------------------

(define-record-type matrix
  (make-matrix-raw dim data)
  matrix?
  (dim matrix-dim)
  (data matrix-data))

(define (matrix-ref m row col)
  (f32vector-ref (matrix-data m) (+ (* row (matrix-dim m)) col)))

;; Build an n x n matrix from proc : row col -> value
(define (matrix-build n proc)
  (let ((data (make-f32vector (* n n) 0.0)))
    (do ((r 0 (+ r 1))) ((= r n))
      (do ((c 0 (+ c 1))) ((= c n))
        (f32vector-set! data (+ (* r n) c) (proc r c))))
    (make-matrix-raw n data)))

(define (matrix-identity n)
  (matrix-build n (lambda (r c) (if (= r c) 1.0 0.0))))

;; E_ij: 1 at (i,j), 0 elsewhere -- the elementary matrices used by
;; HatsuYakitori.HeisenbergCarabiner.heisenberg_matrix_witness.
(define (matrix-elementary n i j)
  (matrix-build n (lambda (r c) (if (and (= r i) (= c j)) 1.0 0.0))))

(define (matrix-add m1 m2)
  (matrix-build (matrix-dim m1) (lambda (r c) (+ (matrix-ref m1 r c) (matrix-ref m2 r c)))))

(define (matrix-sub m1 m2)
  (matrix-build (matrix-dim m1) (lambda (r c) (- (matrix-ref m1 r c) (matrix-ref m2 r c)))))

;; Raw (full-precision) matrix product; no quantization applied.
(define (matrix-mul-raw m1 m2)
  (let ((n (matrix-dim m1)))
    (matrix-build n
      (lambda (r c)
        (let loop ((k 0) (acc 0.0))
          (if (= k n) acc
              (loop (+ k 1) (+ acc (* (matrix-ref m1 r k) (matrix-ref m2 k c))))))))))

(define (matrix-map-q f m)
  (matrix-build (matrix-dim m) (lambda (r c) (f (matrix-ref m r c)))))

;; Quantize-after-multiply: Q(m1 @ m2)
(define (matrix-mul-q m1 m2 mode)
  (matrix-map-q (quantizer-for mode) (matrix-mul-raw m1 m2)))

(define (matrix-max-abs-diff m1 m2)
  (let ((n (matrix-dim m1)))
    (let loop-r ((r 0) (best 0.0))
      (if (= r n) best
          (loop-r (+ r 1)
                  (let loop-c ((c 0) (best2 best))
                    (if (= c n) best2
                        (loop-c (+ c 1)
                                (max best2 (abs (- (matrix-ref m1 r c) (matrix-ref m2 r c)))))))))))) 

;; ------------------------------------------------------------------
;; Backward-compatible 2x2 interface. Everything below (detect-17-cycle,
;; observe-double-shuffle, harvest-constants) was written against this
;; API and is otherwise unchanged.
;; ------------------------------------------------------------------

(define (make-matrix a b c d)
  (matrix-build 2 (lambda (r c*)
                     (cond ((and (= r 0) (= c* 0)) a)
                           ((and (= r 0) (= c* 1)) b)
                           ((and (= r 1) (= c* 0)) c)
                           (else d)))))

(define mref matrix-ref)
(define matrix-map matrix-map-q)
(define matrix-multiply-raw matrix-mul-raw)

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

;; ------------------------------------------------------------------
;; Heisenberg-relation bug oracle.
;;
;; HatsuYakitori.HeisenbergCarabiner.heisenberg_relation (Lean, proved,
;; 0 sorry) states: for any ring R and f, g : Mat(n,R) with f*z = g*z = 0
;; where z = [f,g] = fg - gf,
;;     (1+f)(1+g) = (1+g)(1+f)(1+z)
;; heisenberg_matrix_witness gives a concrete instance in Mat(3,R):
;; f = E01, g = E12, satisfying the hypothesis, with z = E02.
;;
;; Every entry touched by this computation is exactly 0 or 1 --
;; exactly representable in float32, BF16, and FP8 alike, so there is
;; no rounding ambiguity anywhere. That makes this an unusually clean
;; bug oracle: the Lean proof guarantees max|LHS-RHS| = 0 exactly,
;; regardless of quantization mode. Any nonzero result under ANY mode
;; is therefore necessarily an implementation bug in matrix-mul-raw /
;; matrix-mul-q / the quantizer binding -- never "expected quantization
;; noise" (contrast with observe-double-shuffle above, where nonzero
;; divergence is the expected, interesting result).
;; ------------------------------------------------------------------

(define (check-heisenberg-relation mode)
  (let* ((n 3)
         (id (matrix-identity n))
         (f  (matrix-elementary n 0 1))
         (g  (matrix-elementary n 1 2))
         (z  (matrix-sub (matrix-mul-raw f g) (matrix-mul-raw g f)))
         (lhs (matrix-mul-q (matrix-add id f) (matrix-add id g) mode))
         (rhs (matrix-mul-q (matrix-mul-q (matrix-add id g) (matrix-add id f) mode
                             (matrix-add id z)
                             mode)))
         (max-diff (matrix-max-abs-diff lhs rhs)))
    (printf "Heisenberg relation (mode = ~A): max|LHS-RHS| = ~A => ~A\n"
            mode max-diff
            (if (= max-diff 0.0)
                "OK (matches Lean proof exactly)"
                "BUG: Lean proof guarantees exact equality here"))
    max-diff))

(newline)
(printf "=== Heisenberg relation bug oracle ===\n")
(check-heisenberg-relation 'raw)
(check-heisenberg-relation 'bf16)
(check-heisenberg-relation 'fp8)