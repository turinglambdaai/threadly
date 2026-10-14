#lang racket/base

;; Update-flow tests on the rivet/distribution engine: the offline trust
;; chain — craft a manifest, sign it with a throwaway Ed25519 key, verify
;; it, and select updates the same way the live checker does — then the
;; real download path through a local TCP server, the sticky rollout
;; bucket and its one-key whitelist, and the failed-check contract against
;; an unreachable feed. (fetch-update-manifest itself only accepts HTTPS,
;; so the network half is exercised in production; the live-feed signature
;; compatibility of the embedded key is the release pipeline's job and was
;; proven at the 0.10.0 feed when the engine moved onto rivet/distribution.)

(require crypto
         crypto/all
         json
         rackunit
         rivet/distribution
         racket/file
         racket/path
         racket/tcp
         (file "../app/core/paths.rkt")
         (prefix-in upd: "../app/update.rkt"))

(use-all-factories!)

;; Every state-file touch lands in a throwaway data dir, never the user's.
(define test-data-dir
  (make-temporary-file "threadly-updater-home-~a" 'directory))

(define download-limit (* 800 1024 1024))

;; ---- platform identity ------------------------------------------------------

(test-case "platform symbols match rivet release manifests"
  (case (system-type 'os)
    [(macosx) (check-equal? (upd:platform-symbol) 'macos)]
    [(windows) (check-equal? (upd:platform-symbol) 'windows)]
    [else (check-equal? (upd:platform-symbol) 'linux)])
  (check-not-false (memq (upd:architecture-symbol) '(arm64 x64))))

;; ---- embedded release identity ----------------------------------------------

(test-case "embedded identity is coherent and the key is configured"
  (check-true (upd:update-configured?))
  (check-equal? upd:current-update-key-id "threadly-2026-10")
  (check-equal? upd:current-update-application-id "site.jrtx.threadly")
  (check-equal? (upd:manifest-url)
                "https://github.com/turinglambdaai/threadly/releases/latest/download/update-manifest.json")
  (check-equal?
   (parameterize ([upd:current-update-base-url "https://feed.test/threadly/"])
     (upd:manifest-url))
   "https://feed.test/threadly/update-manifest.json"))

;; ---- rollout bucket ------------------------------------------------------------

(test-case "rollout bucket is sticky and persists to updater-state.json"
  (parameterize ([current-data-dir test-data-dir])
    (define bucket0 (upd:rollout-bucket))
    (check-true (exact-integer? bucket0))
    (check-true (<= 0 bucket0 99))
    ;; a second read returns the persisted bucket, not a fresh draw
    (check-equal? (upd:rollout-bucket) bucket0)
    (define doc
      (with-input-from-file
          (build-path test-data-dir "updater-state.json")
        read-json))
    (check-equal? (hash-ref doc 'rollout-bucket) bucket0)))

(test-case "updater-state whitelist: one integer key, nothing else"
  (parameterize ([current-data-dir test-data-dir])
    (define path (build-path test-data-dir "updater-state.json"))
    ;; a hand-edited file grows product data; the next bucket assignment
    ;; rewrites the store through the whitelist and drops the junk
    (with-output-to-file path #:exists 'truncate
      (lambda () (write-json (hasheq 'evil "x"))))
    (define bucket (upd:rollout-bucket))
    (check-true (exact-integer? bucket))
    (define doc (with-input-from-file path read-json))
    (check-false (hash-has-key? doc 'evil))
    (check-equal? (hash-ref doc 'rollout-bucket) bucket)))

;; ---- offline trust chain (throwaway keypair, same DER shapes the
;; ---- release pipeline uses) ------------------------------------------------------

(define priv (generate-private-key 'eddsa '((curve ed25519))))
(define pub (datum->pk-key (pk-key->datum priv 'rkt-public) 'rkt-public))

(define payload-file (make-temporary-file "threadly-payload-~a.zip"))
(define payload (make-bytes 300000 42))
(call-with-output-file payload-file #:exists 'truncate
  (lambda (out) (write-bytes payload out)))
(define payload-sha256 (sha256-file/hex payload-file))

;; A manifest whose single artifact points at artifact-url but carries the
;; local payload's signed size + digest.
(define (test-manifest artifact-url)
  (update-manifest
   upd:current-update-application-id "9.9.9" 7 'stable
   "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
   (list (update-artifact (upd:platform-symbol) (upd:architecture-symbol)
                          artifact-url
                          payload-sha256
                          (bytes-length payload)
                          'zip '()))))

(test-case "signed manifest verifies, a wrong key-id fails closed"
  (define wrapped (open-output-bytes))
  (write-signed-manifest (test-manifest "https://dl.example/threadly-9.9.9.zip")
                         priv "threadly-test" wrapped)
  (define verified
    (verify-signed-manifest (open-input-bytes (get-output-bytes wrapped))
                            pub #:key-id "threadly-test"))
  (check-equal? (update-manifest-version verified) "9.9.9")
  (check-exn exn:fail?
             (lambda ()
               (verify-signed-manifest
                (open-input-bytes (get-output-bytes wrapped))
                pub #:key-id "some-other-key"))))

(test-case "select-update picks this platform's artifact and gates versions"
  (define config
    (updater-config upd:current-update-application-id "0.0.1" 'stable
                    (upd:platform-symbol) (upd:architecture-symbol)
                    pub "threadly-test" 42 download-limit))
  (define candidate
    (select-update config
                   (test-manifest "https://dl.example/threadly-9.9.9.zip")))
  (check-true (update-candidate? candidate))
  (check-equal? (update-artifact-size (update-candidate-artifact candidate))
                (bytes-length payload))
  ;; the same feed at/below the running version selects nothing
  (define current-config
    (struct-copy updater-config config [current-version "9.9.9"]))
  (check-false
   (select-update current-config
                  (test-manifest "https://dl.example/threadly-9.9.9.zip")))
  ;; destination layout: <data-dir>/updates/Threadly-<version><ext>
  (check-equal?
   (upd:destination-path test-data-dir candidate)
   (build-path test-data-dir "updates"
               (string-append "Threadly-9.9.9" (upd:installer-extension)))))

;; ---- real download path against a local TCP server -----------------------------
;; A minimal one-shot HTTP artifact server: get-pure-port insists on a
;; well-formed response head, and the tampered-artifact case downloads
;; twice, so every connection gets the same bytes.

(define (serve-artifact-payload! payload-bytes)
  (define listener (tcp-listen 0 4 #f "127.0.0.1"))
  (define-values (_bind-host port-number _peer-host _peer-port)
    (tcp-addresses listener #t))
  (define server
    (thread
     (lambda ()
       (let accept-loop ()
         (define-values (in out) (tcp-accept listener))
         (thread
          (lambda ()
            (let drain ()
              (define line (read-line in 'any))
              (unless (or (eof-object? line) (equal? line "") (equal? line "\r"))
                (drain)))
            (write-string
             (format "HTTP/1.0 200 OK\r\nContent-Length: ~a\r\n"
                     (bytes-length payload-bytes))
             out)
            (write-string "Content-Type: application/zip\r\n\r\n" out)
            (write-bytes payload-bytes out)
            (close-output-port out)
            (close-input-port in)))
         (accept-loop)))))
  (values port-number
          (lambda ()
            (kill-thread server)
            (tcp-close listener))))

(test-case "download fetches, verifies and stages locally; tampering fails"
  (define-values (port-number stop-server!) (serve-artifact-payload! payload))
  (define config
    (updater-config upd:current-update-application-id "0.1.0" 'stable
                    (upd:platform-symbol) (upd:architecture-symbol)
                    pub "threadly-test" 0 download-limit))
  (define candidate
    (select-update config
                   (test-manifest
                    (format "http://127.0.0.1:~a/threadly.zip" port-number))))
  (check-true (update-candidate? candidate))

  (parameterize ([current-data-dir test-data-dir])
    (upd:reset-update-state!)
    (upd:set-candidate! candidate)
    ;; the candidate reaches the RPC layer in the documented hasheq shape
    (define as-hash (upd:current-candidate))
    (check-equal? (hash-ref as-hash 'version) "9.9.9")
    (check-equal? (hash-ref (hash-ref as-hash 'artifact) 'installer) 'zip)
    (check-equal? (hash-ref (hash-ref as-hash 'artifact) 'size)
                  (bytes-length payload))

    (define destination (upd:destination-path test-data-dir candidate))
    (check-equal?
     (upd:download-with-progress! config candidate destination)
     destination)
    (check-true (file-exists? destination))
    (check-equal? (file-size destination) (bytes-length payload))
    (check-equal? (hash-ref (upd:update-state-snapshot) 'percent) 100)
    (delete-file destination)

    ;; a tampered artifact fails the sha256 gate before landing
    (define bad-manifest
      (struct-copy update-manifest
                   (test-manifest
                    (format "http://127.0.0.1:~a/threadly.zip" port-number))
                   [artifacts
                    (list (struct-copy update-artifact
                                       (car (update-manifest-artifacts
                                             (test-manifest "https://x/")))
                                       [sha256 (make-string 64 #\0)]))]))
    (define bad-candidate (select-update config bad-manifest))
    (check-exn exn:fail?
               (lambda ()
                 (upd:download-with-progress!
                  config bad-candidate
                  (build-path test-data-dir "updates" "bad.zip")))))

  (stop-server!))

(test-case "check against an unreachable feed reports the failed contract"
  ;; the real check path, offline: the connection failure maps to
  ;; '(failed reason) and the state phase lands on error
  (parameterize ([upd:current-update-base-url "https://127.0.0.1:9/threadly"])
    (parameterize ([current-data-dir test-data-dir])
      (upd:reset-update-state!)
      (define result (upd:update-check-result "0.1.0"))
      (check-equal? (car result) 'failed)
      (check-true (string? (cadr result)))
      (check-equal? (hash-ref (upd:update-state-snapshot) 'phase) "error"))))

(delete-file payload-file)
