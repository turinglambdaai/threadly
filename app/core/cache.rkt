#lang racket/base

;; Politeness layer: every Discourse response is cached on disk under a TTL
;; so re-opening a view never re-hits the forum. Entries are JSON files
;; named by sha1 of the request URL, each storing
;; {"fetched_at": epoch, "body": jsexpr}. A stale entry is still served when
;; the forum is unreachable — better a slightly old thread than an error.

(require file/sha1
         json
         racket/file
         racket/path
         racket/port
         "paths.rkt")

(provide current-cache-ttl-seconds
         cache-path
         cache-lookup
         cache-store!)

;; seconds a cached response stays fresh
(define current-cache-ttl-seconds (make-parameter 300))

(define (cache-dir)
  (build-path (data-dir) "cache"))

(define (cache-path key)
  (build-path (cache-dir)
              (string-append (sha1 (open-input-bytes (string->bytes/utf-8 key)))
                             ".json")))

;; → (values body fresh?) — body is the stored jsexpr or #f,
;; fresh? says whether it is inside the TTL
(define (cache-lookup key)
  (define p (cache-path key))
  (cond
    [(not (file-exists? p)) (values #f #f)]
    [else
     (with-handlers ([exn:fail? (lambda (_) (values #f #f))])
       (define doc (call-with-input-file p read-json))
       (define fetched (hash-ref doc 'fetched_at 0))
       (define age (- (current-seconds) fetched))
       (values (hash-ref doc 'body #f)
               (and (exact-nonnegative-integer? fetched)
                    (<= age (current-cache-ttl-seconds)))))]))

;; atomic write: temp file in the same directory, then rename over
(define (cache-store! key body)
  (ensure-data-dir!)
  (define dir (cache-dir))
  (unless (directory-exists? dir)
    (make-directory* dir))
  (define p (cache-path key))
  (define tmp (make-temporary-file "threadly-cache-~a.json" #f dir))
  (with-output-to-file tmp
    (lambda ()
      (write-json (hasheq 'fetched_at (current-seconds) 'body body)))
    #:exists 'truncate)
  (rename-file-or-directory tmp p #t))
