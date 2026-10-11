#lang racket/base

;; TTL disk cache: fresh inside the TTL, stale outside, corrupt entries are
;; misses, and all of it lands in an injected temp data dir.

(require json
         rackunit
         racket/file
         racket/port
         "../app/core/cache.rkt"
         "../app/core/paths.rkt")

(define tmp (make-temporary-file "threadly-cache-test-~a" 'directory))

(test-case "store + fresh lookup"
  (parameterize ([current-data-dir tmp]
                 [current-cache-ttl-seconds 300])
    (define body (hasheq 'topics (list 1 2 3)))
    (cache-store! "key-a" body)
    (define-values (hit fresh?) (cache-lookup "key-a"))
    (check-equal? hit body)
    (check-true fresh?)
    ;; cache files are on disk as JSON envelopes
    (check-true (file-exists? (cache-path "key-a")))))

(test-case "stale when older than the TTL"
  (parameterize ([current-data-dir tmp]
                 [current-cache-ttl-seconds 60])
    ;; backdate the entry by an hour (same-second writes make ttl-0 flaky)
    (define p (cache-path "key-a"))
    (define doc (call-with-input-file p read-json))
    (with-output-to-file p
      (lambda ()
        (write-json (hash-set doc 'fetched_at (- (hash-ref doc 'fetched_at) 3600))))
      #:exists 'truncate)
    (define-values (hit fresh?) (cache-lookup "key-a"))
    (check-equal? hit (hasheq 'topics (list 1 2 3)))
    (check-false fresh?)))

(test-case "missing key is a miss"
  (parameterize ([current-data-dir tmp])
    (define-values (hit fresh?) (cache-lookup "never-stored"))
    (check-false hit)
    (check-false fresh?)))

(test-case "corrupt entry is a miss, not a crash"
  (parameterize ([current-data-dir tmp])
    (define p (cache-path "broken"))
    (with-output-to-file p (lambda () (display "not json{")))
    (define-values (hit fresh?) (cache-lookup "broken"))
    (check-false hit)
    (check-false fresh?)))
