#lang racket/base

;; Sign-in flow tests: keypair generation, the decrypt + nonce-verify half
;; of auth-complete, and sign-out hygiene — all against the real OpenSSL 3
;; when present (dev machines and CI runners have it; the test skips
;; gracefully when they don't).

(require json
         net/base64
         rackunit
         racket/file
         racket/path
         racket/runtime-path
         racket/string
         racket/system
         (file "../app/core/paths.rkt")
         (prefix-in auth: "../app/auth.rkt"))

(define openssl
  (let ([p (auth:find-openssl)])
    (and (auth:openssl3? p) p)))

(define-syntax-rule (skip-unless-openssl body ...)
  (if openssl (let () body ...) (displayln "skipped: no OpenSSL 3")))

;; RSA-encrypt `plain` (a path) with `pub` (a path) and return the base64
;; "code" the user would paste into the app.
(define (encrypt-code openssl pub plain)
  (define ct (path->string (make-temporary-file "thr-ct~a")))
  (unless (system* openssl "pkeyutl" "-encrypt" "-pubin"
                   "-inkey" (path->string pub)
                   "-in" plain "-out" ct)
    (error 'encrypt-code "openssl encrypt failed"))
  ;; the pasted "code" is the base64 of the ciphertext (family protocol)
  (define code (bytes->string/latin-1 (base64-encode (file->bytes ct) "")))
  code)

(parameterize ([current-data-dir
                (make-temporary-file "threadly-auth-test-~a" 'directory)])
  (skip-unless-openssl
   (test-case "SKIPPED auth-begin"
     (define url (auth:auth-begin))
     (check-true (string-prefix? url "https://racket.discourse.group/user-api-key/new?"))
     (check-true (string-contains? url "scopes=read"))
     (check-true (string-contains? url (string-append "nonce=" (auth:auth-nonce-for-tests))))
     (check-true (file-exists? (auth:private-key-path)))
     (check-false (auth:auth-signed-in?))))

  (skip-unless-openssl
   (test-case "auth-complete stores the key on a correct code"
     (define keys-dir
       (simple-form-path (build-path (auth:private-key-path) 'up)))
     (define pub (build-path keys-dir "test-pub.pem"))
     (unless (file-exists? pub)
       (system* openssl "pkey" "-in" (path->string (auth:private-key-path))
                "-pubout" "-out" (path->string pub)))
     (define plain (path->string (make-temporary-file "thr-plain~a")))
     (with-output-to-file plain
       (lambda ()
         (write-json (hasheq 'key "test-api-key-123"
                             'nonce (auth:auth-nonce-for-tests))))
       #:exists 'truncate)
     (define code (encrypt-code openssl pub plain))
     (check-equal? (auth:auth-complete code) "test-api-key-123")
     (check-true (auth:auth-signed-in?))
     (check-equal? (auth:auth-api-key) "test-api-key-123")
     (check-false (file-exists? (auth:private-key-path))
                  "handshake key is deleted once the API key is stored")))

  (skip-unless-openssl
   (test-case "auth-complete rejects a nonce mismatch"
     (parameterize ([current-data-dir
                     (make-temporary-file "threadly-auth-neg-~a" 'directory)])
       (auth:auth-begin)
       (define keys-dir
         (simple-form-path (build-path (auth:private-key-path) 'up)))
       (define pub (build-path keys-dir "test-pub.pem"))
       (system* openssl "pkey" "-in" (path->string (auth:private-key-path))
                "-pubout" "-out" (path->string pub))
       (define plain (path->string (make-temporary-file "thr-plain~a")))
       (with-output-to-file plain
         (lambda () (write-json (hasheq 'key "evil-key" 'nonce "WRONG")))
         #:exists 'truncate)
       (define code (encrypt-code openssl pub plain))
       (check-exn exn:fail? (lambda () (auth:auth-complete code)))
       (check-false (auth:auth-signed-in?))
       (auth:auth-sign-out)
       (check-false (file-exists? (auth:private-key-path))))))

  (skip-unless-openssl
   (test-case "sign-out clears every credential file"
     (parameterize ([current-data-dir
                     (make-temporary-file "threadly-auth-so-~a" 'directory)])
       (auth:auth-begin)
       (auth:auth-sign-out)
       (check-false (auth:auth-signed-in?))
       (check-false (auth:auth-configured?))
       (check-false (file-exists? (auth:private-key-path)))))))
