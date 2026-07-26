(import (chicken base)
        (chicken foreign)
        (chicken format)
        (srfi 4)
        (srfi 63))

;; Link to the external C23 implementation
;; Do NOT implement the C logic here anymore
(foreign-declare "
extern float c23_to_bf16(float f);
extern float c23_to_fp8(float f);
")

;; Bind the external C functions to Scheme identifiers
(define q-bf16 (foreign-lambda float "c23_to_bf16" float))
(define q-fp8  (foreign-lambda float "c23_to_fp8" float))

;; Instantiate a 2x2 matrix using SRFI-63 with float32 array prototype
(define (make-matrix a b c d)
  (let ((m (make-array '#() 2 2)))
    (array-set! m a 0 0)
    (array-set! m b 0 1)
    (array-set! m c 1 0)
    (array-set! m d 1 1)
    m))

;; Quiver matrix multiplication with mixed precision accumulation
(define (quiver-multiply m1 m2 mode)
  (let ((q (cond ((eq? mode 'bf16) q-bf16) 
                 ((eq? mode 'fp8)  q-fp8) 
                 (else (lambda (x) x)))))
    (make-matrix
     (q (+ (* (array-ref m1 0 0) (array-ref m2 0 0)) (* (array-ref m1 0 1) (array-ref m2 1 0))))
     (q (+ (* (array-ref m1 0 0) (array-ref m2 0 1)) (* (array-ref m1 0 1) (array-ref m2 1 1))))
     (q (+ (* (array-ref m1 1 0) (array-ref m2 0 0)) (* (array-ref m1 1 1) (array-ref m2 1 0))))
     (q (+ (* (array-ref m1 1 0) (array-ref m2 0 1)) (* (array-ref m1 1 1) (array-ref m2 1 1)))))))

;; Track the orbit and visualize the cycle
(define (detect-17-cycle m-init max-steps mode)
  (let loop ((current m-init)
             (step 0))
    (if (>= step max-steps)
        (printf "Simulation finished\n")
        (begin
          (printf "Step ~A: RegState = ~A\n" step (array-ref current 0 0))
          (loop (quiver-multiply current m-init mode) (+ step 1))))))

;; Setup for the initial Jordan quiver
(define theta (/ (* 2.0 3.141592653589793) 17.0))
(define cos-t (cos theta))
(define sin-t (sin theta))

(define register-node-17
  (make-matrix cos-t      (- sin-t)
               sin-t      cos-t))

(print "=== Driving 17-cycle Register Machine (Emergence via FP8) ===")
(detect-17-cycle register-node-17 35 'fp8)