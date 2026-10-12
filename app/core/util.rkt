#lang racket/base

;; Small shared helpers for the engine.

(provide hex->bytes)

;; "302a…" → bytes; #f on malformed input.
(define (hex->bytes s)
  (define n (string-length s))
  (if (and (even? n) (>= n 2))
      (apply bytes
             (for/list ([i (in-range 0 n 2)])
               (string->number (substring s i (+ i 2)) 16)))
      #f))
