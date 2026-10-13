#lang racket/base

;; Release identity; scripts/check-release-version.sh greps the define
;; below against VERSION and rivet.rktd, so keep this exact shape.

(provide app-version)

(define app-version "0.8.0")
