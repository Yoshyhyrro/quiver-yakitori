(import (chicken base)
        (chicken foreign)
        (chicken format)
        (srfi 4))

;; Minimal local list helpers (my-filter/my-take/my-drop/my-fold/my-del-assv), written
;; by hand instead of importing srfi-1 -- that egg needs a network fetch
;; this sandbox can't reach (same issue hit earlier with srfi-63), and
;; avoiding it keeps this experiment dependency-free besides srfi-4.
(define (my-filter pred lst)
  (cond ((null? lst) '())
        ((pred (car lst)) (cons (car lst) (my-filter pred (cdr lst))))
        (else (my-filter pred (cdr lst)))))
(define (my-take lst n)
  (if (= n 0) '() (cons (car lst) (my-take (cdr lst) (- n 1)))))
(define (my-drop lst n)
  (if (= n 0) lst (my-drop (cdr lst) (- n 1))))
(define (my-fold proc init lst)
  (if (null? lst) init (my-fold proc (proc (car lst) init) (cdr lst))))
(define (my-del-assv key alist)
  (cond ((null? alist) '())
        ((eqv? (caar alist) key) (cdr alist))
        (else (cons (car alist) (my-del-assv key (cdr alist))))))

;; ------------------------------------------------------------------
;; Experiment scope note
;;
;; This file tests one narrow, concrete question: can the "two quivers"
;; idea from the LaTeX sketch (a Jordan quiver = 1 vertex + 1 loop, and
;; a McKay quiver = vertices from Irr(G) with edges from tensor-product
;; multiplicities) be represented using only `vector` (for the fixed
;; vertex table) and plain lists (for adjacency / edge data), with NO
;; pattern-matching (`match`) construct anywhere.
;;
;; It does NOT attempt to verify the deeper LaTeX conjecture (Sedenion
;; collapse, "Resonance Condition" at Fermat primes, PicardFunctor
;; commutativity connecting BSDQuiver-style structures to this). That
;; remains unproven. What IS real and checked here: the S6 McKay quiver
;; itself (a completely standard, well-defined combinatorial object,
;; independent of any Sedenion/Fermat claims) and the "PicardFunctor"
;; *shape* (three matrices + a commutativity check), used only as a
;; mechanical example that such a structure is at least expressible and
;; checkable in this style -- not as evidence for the sketch's claims.
;; ------------------------------------------------------------------

(foreign-declare "
extern float c23_to_bf16(float f);
extern float c23_to_fp8(float f);
")
(define q-bf16 (foreign-lambda float "c23_to_bf16" float))
(define q-fp8  (foreign-lambda float "c23_to_fp8" float))
(define (quantizer-for mode)
  (cond ((eq? mode 'bf16) q-bf16) ((eq? mode 'fp8) q-fp8) (else (lambda (x) x))))

(define-record-type matrix (make-matrix-raw dim data) matrix?
  (dim matrix-dim) (data matrix-data))
(define (matrix-ref m row col) (f32vector-ref (matrix-data m) (+ (* row (matrix-dim m)) col)))
(define (matrix-build n proc)
  (let ((data (make-f32vector (* n n) 0.0)))
    (do ((r 0 (+ r 1))) ((= r n))
      (do ((c 0 (+ c 1))) ((= c n))
        (f32vector-set! data (+ (* r n) c) (proc r c))))
    (make-matrix-raw n data)))
(define (matrix-mul-raw m1 m2)
  (let ((n (matrix-dim m1)))
    (matrix-build n (lambda (r c)
      (let loop ((k 0) (acc 0.0))
        (if (= k n) acc (loop (+ k 1) (+ acc (* (matrix-ref m1 r k) (matrix-ref m2 k c))))))))))
(define (matrix-map-q f m) (matrix-build (matrix-dim m) (lambda (r c) (f (matrix-ref m r c)))))
(define (matrix-mul-q m1 m2 mode) (matrix-map-q (quantizer-for mode) (matrix-mul-raw m1 m2)))
(define (matrix-max-abs-diff m1 m2)
  (let ((n (matrix-dim m1)))
    (let loop-r ((r 0) (best 0.0))
      (if (= r n) best
          (loop-r (+ r 1)
                  (let loop-c ((c 0) (best2 best))
                    (if (= c n) best2
                        (loop-c (+ c 1)
                                (max best2 (abs (- (matrix-ref m1 r c) (matrix-ref m2 r c)))))))))))) 

;; ==================================================================
;; PART 1 -- Jordan quiver: 1 vertex, 1 loop.
;;
;; This is not new machinery -- it IS the existing register machine.
;; The "vertex" is the current 2x2 matrix state (a `matrix` record,
;; itself backed by an f32vector -- the "vector" half of the
;; vector/list question). The "loop" is `matrix-mul-q` applied to
;; itself repeatedly. No list or match needed here at all; the whole
;; point of a Jordan quiver is that it's this trivial.
;; ==================================================================

(define (jordan-quiver-run m-init max-steps mode)
  (let loop ((current m-init) (step 0) (states '()))
    (if (>= step max-steps)
        (reverse states)
        (loop (matrix-mul-q current m-init mode) (+ step 1)
              (cons (matrix-ref current 0 0) states)))))

;; ==================================================================
;; PART 2 -- McKay quiver for S6, tensoring with the standard rep.
;;
;; Vertices: the 11 partitions of 6 (= 11 irreps of S6), stored in a
;; VECTOR (fixed indexing). Edges: for each vertex, a LIST of
;; (target-index . multiplicity) pairs -- a plain association list,
;; read with `assv`/`car`/`cdr`, never `match`.
;;
;; Edge rule (standard branching-rule combinatorics, not specific to
;; this project): mult(nu) in V_lambda (x) V_std = (number of paths
;; lambda -> mu -> nu by removing then adding one box) minus 1 if
;; nu = lambda. Verified below against the dimension identity
;; dim(lambda) * 5 = sum_nu mult(nu) * dim(nu), for all 11 vertices.
;; ==================================================================

(define s6-partitions
  (vector '(6) '(5 1) '(4 2) '(4 1 1) '(3 3) '(3 2 1)
          '(3 1 1 1) '(2 2 2) '(2 2 1 1) '(2 1 1 1 1) '(1 1 1 1 1 1)))

(define (partition-index p)
  (let loop ((i 0))
    (cond ((>= i (vector-length s6-partitions)) #f)
          ((equal? (vector-ref s6-partitions i) p) i)
          (else (loop (+ i 1))))))

;; Hook-length dimension of a partition (plain list/cond, no match).
(define (partition-dim p)
  (define n (apply + p))
  (define (col-height j)
    (length (my-filter (lambda (r) (> r j)) p)))
  (define (fact k) (if (<= k 1) 1 (* k (fact (- k 1)))))
  (let row-loop ((rows p) (i 0) (prod 1))
    (cond
      ((null? rows) (quotient (fact n) prod))
      (else
       (let ((row-len (car rows)))
         (let col-loop ((j 0) (prod prod))
           (if (= j row-len)
               (row-loop (cdr rows) (+ i 1) prod)
               (let* ((arm (- row-len j 1))
                      (leg (- (col-height j) i 1))
                      (hook (+ arm leg 1)))
                 (col-loop (+ j 1) (* prod hook))))))))))

;; All partitions obtainable by removing exactly one corner box from p.
(define (remove-box p)
  (let loop ((i 0) (acc '()))
    (if (= i (length p))
        (reverse acc)
        (let* ((row (list-ref p i))
               (next (if (= (+ i 1) (length p)) 0 (list-ref p (+ i 1)))))
          (if (>= (- row 1) next)
              (let* ((new-row (- row 1))
                     (candidate (append (my-take p i) (list new-row) (my-drop p (+ i 1))))
                     (trimmed (my-filter (lambda (x) (> x 0)) candidate)))
                (loop (+ i 1) (cons trimmed acc)))
              (loop (+ i 1) acc))))))

;; All partitions obtainable by adding exactly one box to p.
(define (add-box p)
  (let loop ((i 0) (acc '()))
    (if (= i (length p))
        (reverse (cons (append p (list 1)) acc))
        (let* ((row (list-ref p i))
               (prev (if (= i 0) +inf.0 (list-ref p (- i 1)))))
          (if (<= (+ row 1) prev)
              (loop (+ i 1)
                    (cons (append (my-take p i) (list (+ row 1)) (my-drop p (+ i 1))) acc))
              (loop (+ i 1) acc))))))

;; Bump (idx . 1) into an alist, or increment the existing count.
(define (bump alist idx)
  (let ((hit (assv idx alist)))
    (if hit
        (cons (cons idx (+ 1 (cdr hit))) (my-del-assv idx alist))
        (cons (cons idx 1) alist))))

(define (mckay-edges lambda-idx)
  (let* ((lam (vector-ref s6-partitions lambda-idx))
         (mus (remove-box lam))
         (raw
          (my-fold (lambda (mu acc)
                  (my-fold (lambda (nu acc2) (bump acc2 (partition-index nu)))
                        acc (add-box mu)))
                '() mus))
         (self-hit (assv lambda-idx raw)))
    (if (and self-hit (= (cdr self-hit) 1))
        (my-del-assv lambda-idx raw)
        (if self-hit
            (cons (cons lambda-idx (- (cdr self-hit) 1)) (my-del-assv lambda-idx raw))
            raw))))

;; The McKay quiver itself: a VECTOR of 11 entries, each entry a LIST
;; of (target-index . multiplicity) pairs.
(define mckay-quiver-s6
  (let ((v (make-vector 11)))
    (do ((i 0 (+ i 1))) ((= i 11) v)
      (vector-set! v i (mckay-edges i)))))

(define (verify-mckay-quiver)
  (let loop ((i 0) (all-ok #t))
    (if (= i 11)
        all-ok
        (let* ((lam (vector-ref s6-partitions i))
               (dim-lam (partition-dim lam))
               (edges (vector-ref mckay-quiver-s6 i))
               (total (my-fold (lambda (kv acc)
                              (+ acc (* (cdr kv) (partition-dim (vector-ref s6-partitions (car kv))))))
                            0 edges))
               (expect (* dim-lam 5))
               (ok (= total expect)))
          (printf "~A  dim=~A  edges=~A  check: ~A = ~A  ~A\n"
                  lam dim-lam edges total expect (if ok "OK" "MISMATCH"))
          (loop (+ i 1) (and all-ok ok))))))

;; ==================================================================
;; PART 3 -- PicardFunctor shape (mechanical only)
;;
;; Per the HatsuYakitori reference (BSDQuiver.lean, DirectedBanachQuiver
;; .lean): a PicardFunctor carries three matrices A_recover, A_project,
;; A_tensor with the condition A_recover * A_project = A_tensor. This
;; section only checks that such a condition is expressible and
;; checkable here -- it does NOT construct a functor tying the Jordan
;; and McKay quivers together, and proves nothing about the LaTeX
;; sketch's conjecture.
;; ==================================================================

(define (check-picard-functor a-recover a-project a-tensor mode)
  (let* ((product (matrix-mul-q a-recover a-project mode))
         (diff (matrix-max-abs-diff product a-tensor)))
    (printf "PicardFunctor commutativity check (mode=~A): max|A_recover*A_project - A_tensor| = ~A\n"
            mode diff)
    diff))

;; ==================================================================
;; Run everything
;; ==================================================================

(printf "=== Jordan quiver (register machine, n=17, mode=fp8) ===\n")
(let* ((theta (/ (* 2.0 3.141592653589793) 17.0)) (ct (cos theta)) (st (sin theta))
       (m-init (matrix-build 2 (lambda (r c)
                 (cond ((and (= r 0)(= c 0)) ct) ((and (= r 0)(= c 1)) (- st))
                       ((and (= r 1)(= c 0)) st) (else ct)))))
       (trajectory (jordan-quiver-run m-init 5 'fp8)))
  (printf "first 5 states of the single vertex's loop: ~A\n" trajectory))

(newline)
(printf "=== McKay quiver for S6 (x) V_std, verified vs hook-length dimensions ===\n")
(define mckay-ok (verify-mckay-quiver))
(printf "~A\n" (if mckay-ok "ALL 11 VERTICES OK" "MISMATCH FOUND"))

(newline)
(printf "=== PicardFunctor shape check (toy 2x2 matrices, mode=raw) ===\n")
(let* ((a-recover (matrix-build 2 (lambda (r c) (if (= r c) 1.0 0.0))))
       (a-project (matrix-build 2 (lambda (r c) (if (= r c) 2.0 0.0))))
       (a-tensor  (matrix-build 2 (lambda (r c) (if (= r c) 2.0 0.0)))))
  (check-picard-functor a-recover a-project a-tensor 'raw))
