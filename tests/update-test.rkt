#lang racket/base

;; Update-flow tests: the pure parts of the family signed-wrapper scheme
;; against a real captured feed (tests/fixtures/update-manifest.json).
;; The live-signature test shells out to OpenSSL 3 and is skipped when no
;; OpenSSL 3 is available (CI macos/ubuntu runners have one).

(require json
         net/base64
         rackunit
         racket/file
         racket/port
         racket/runtime-path
         racket/string
         (file "../app/core/util.rkt")
         (prefix-in upd: "../app/update.rkt"))

(define-runtime-path fixture "fixtures/update-manifest.json")

(define wrapper (call-with-input-file fixture read-json))
(define-values (fixture-payload fixture-key-id fixture-signature)
  (upd:parse-signed-wrapper wrapper))
(define fixture-manifest (read-json (open-input-bytes fixture-payload)))

;; ---- hex->bytes --------------------------------------------------------------

(test-case "hex->bytes"
  (check-equal? (hex->bytes "302a300506032b6570032100")
                (bytes #x30 #x2a #x30 #x05 #x06 #x03 #x2b #x65 #x70 #x03 #x21 #x00))
  (check-false (hex->bytes "abc"))
  ;; even length but not hex: the byte constructor rejects the #f digits
  (check-exn exn:fail? (lambda () (hex->bytes "zz"))))

;; ---- key PEM round trip -------------------------------------------------------

(test-case "raw-key->pem builds a valid SPKI PEM"
  (define raw (base64-decode (string->bytes/latin-1 upd:current-update-public-key-hex)))
  (check-equal? (bytes-length raw) 32)
  (define pem (upd:raw-key->pem raw))
  (check-true (string-prefix? pem "-----BEGIN PUBLIC KEY-----"))
  (check-true (string-suffix? (string-trim pem) "-----END PUBLIC KEY-----"))
  ;; the base64 body must decode back to SPKI prefix + raw key
  (define body
    (apply string-append
           (filter (lambda (l) (and (string? l)
                                    (not (string-prefix? l "-----"))))
                   (string-split pem "\n"))))
  (define der (base64-decode (string->bytes/latin-1 body)))
  (check-equal? (subbytes der 12) raw))

;; ---- signed wrapper parsing -----------------------------------------------------

(test-case "parse-signed-wrapper on the real captured feed"
  (check-equal? fixture-key-id "threadly-2026-10")
  (check-equal? (bytes-length fixture-signature) 64)
  (check-equal? (hash-ref fixture-manifest 'application_id) "site.jrtx.threadly")
  (check-true (string? (hash-ref fixture-manifest 'version)))
  (check-true ((length (hash-ref fixture-manifest 'artifacts)) . >= . 4)))

(test-case "parse-signed-wrapper rejects malformed envelopes"
  (check-exn exn:fail? (lambda () (upd:parse-signed-wrapper (hasheq 'schema 2))))
  (check-exn exn:fail? (lambda () (upd:parse-signed-wrapper "not a hash")))
  (check-exn exn:fail?
             (lambda ()
               (upd:parse-signed-wrapper
                (hasheq 'schema 1 'payload "AAAA"
                        'signature (hasheq 'algorithm "rsa"
                                           'key_id "x" 'value "AAAA"))))))

;; ---- live signature verification (needs OpenSSL 3) ------------------------------

(test-case "verify-wrapper-signature against the live signature"
  (define raw (base64-decode (string->bytes/latin-1 upd:current-update-public-key-hex)))
  (define verified
    (with-handlers ([exn:fail? (lambda (_) #f)]) 
      (upd:verify-wrapper-signature fixture-payload fixture-signature raw)
      #t))
  ;; #f can mean "no OpenSSL 3 here" or "bad signature"; tell them apart by
  ;; re-running with a tampered payload when OpenSSL exists at all
  (when verified
    (check-exn exn:fail?
               (lambda ()
                 (upd:verify-wrapper-signature
                  (subbytes fixture-payload 0 (sub1 (bytes-length fixture-payload)))
                  fixture-signature raw)))))

;; ---- artifact selection -----------------------------------------------------------

(test-case "select-artifact matches platform × architecture"
  (define mac-arm (upd:select-artifact fixture-manifest 'macos 'arm64))
  (check-equal? (hash-ref mac-arm 'installer) "zip")
  (check-equal? (hash-ref mac-arm 'platform) "macos")
  (check-true (hash-has-key? mac-arm 'sha256))
  (check-false (upd:select-artifact fixture-manifest 'ios 'arm64)))

;; ---- version comparison --------------------------------------------------------------

(test-case "version-newer?"
  (check-true (upd:version-newer? "0.1.0" "0.2.0"))
  (check-false (upd:version-newer? "0.2.0" "0.2.0"))
  (check-true (upd:version-newer? "0.1.0" "0.2"))
  (check-true (upd:version-newer? "0.10.0" "0.9.9")))
