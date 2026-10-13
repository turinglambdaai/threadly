#lang racket/base

;; Write-path (M2 reply) tests: pure form encoding, the wire request shape
;; against a loopback server, and the upgraded sign-in scopes. Live writes
;; to the real forum need the user's own account, so none happen here.

(require json
         net/base64
         net/uri-codec
         rackunit
         racket/file
         racket/port
         racket/string
         racket/system
         racket/tcp
         (file "../app/core/http.rkt")
         (file "../app/core/discourse.rkt")
         (file "../app/core/paths.rkt")
         (prefix-in auth: "../app/auth.rkt"))

(define openssl
  (let ([p (auth:find-openssl)])
    (and (auth:openssl3? p) p)))

(define-syntax-rule (skip-unless-openssl body ...)
  (if openssl (let () body ...) (displayln "skipped: no OpenSSL 3")))

;; ---- form encoding (pure) ------------------------------------------------------

(test-case "form-encode-fields"
  (check-equal? (form-encode-fields (list (cons "topic_id" "4416")
                                          (cons "raw" "hello world")))
                "topic_id=4416&raw=hello%20world")
  (define encoded (form-encode-fields (list (cons "raw" "第一行\n第二行 & = ?"))))
  (check-true (string-contains? encoded "%0A") "newline percent-encoded")
  (check-true (string-contains? encoded "%26") "ampersand percent-encoded")
  (check-true (string-contains? encoded (uri-encode "?")) "question mark escaped")
  (check-false (string-contains? encoded " & ") "raw ampersand must be escaped"))

;; ---- POST wire shape against a loopback server ----------------------------------

(define (read-request-headers in)
  (define request-line (read-line in 'any))
  (define headers
    (let loop ([acc (list request-line)])
      (define line (read-line in 'any))
      (if (or (eof-object? line) (string=? line ""))
          (reverse acc)
          (loop (cons line acc)))))
  (values request-line headers))

(test-case "http-post-form: POST /posts.json with urlencoded body"
  ;; grab a free port with retries (racket/tcp has no listener-port getter)
  (define (open-loopback-listener)
    (let loop ([tries 20])
      (define p (+ 20000 (random 40000)))
      (with-handlers ([exn:fail?
                       (λ (_)
                         (when (zero? tries) (error 'write-test "no free port"))
                         (loop (sub1 tries)))])
        (values (tcp-listen p 4 #f "127.0.0.1") p))))
  (define-values (listener port) (open-loopback-listener))
  (define captured (box #f))
  (define server
    (thread
     (lambda ()
       (define-values (in out) (tcp-accept listener))
       (define-values (request-line headers) (read-request-headers in))
       (define content-length
         (for/or ([h (in-list headers)]
                  #:when (string-contains? (string-downcase h) "content-length"))
           (string->number (substring h (string-length "Content-Length: ")))))
       (define body (read-string content-length in))
       (display "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 28\r\n\r\n{\"id\":777,\"post_number\":4}"
                out)
       (close-input-port in)
       (close-output-port out)
       (tcp-close listener)
       (set-box! captured (list request-line headers body)))))

  (define-values (code headers body)
    (http-post-form (format "http://127.0.0.1:~a/posts.json" port)
                    (list (cons "topic_id" "4416")
                          (cons "raw" "第一行\n第二行 & hi"))
                    (list "User-Api-Key: test-key-456")))

  (check-equal? code 200)
  (check-equal? body #"{\"id\":777,\"post_number\":4}")

  ;; the server sets the box after closing the response — join it before
  ;; reading what it captured
  (sync/timeout 5 server)

  (define captured-data (unbox captured))
  (define request-line (list-ref captured-data 0))
  (define req-headers (list-ref captured-data 1))
  (define req-body (list-ref captured-data 2))

  (check-true (string-contains? request-line "POST /posts.json")
              "POST hits the write endpoint")
  (check-true (string-contains? request-line "HTTP/1.1"))
  (check-not-false
   (findf (lambda (h) (string-contains? (string-downcase h)
                                        "user-api-key: test-key-456"))
          req-headers)
   "User-Api-Key header present")
  (check-not-false
   (findf (lambda (h) (string-contains? (string-downcase h)
                                        "content-type: application/x-www-form-urlencoded"))
          req-headers)
   "urlencoded content type")
  (check-true (string-contains? req-body "topic_id=4416"))
  (check-true (string-contains? req-body (uri-encode "第一行"))))

;; ---- sign-in scopes include write -------------------------------------------------

;; mark-notifications-read POSTs with no body beyond the api-key header —
;; same loopback shape check as the reply POST above.
(test-case "mark-notifications-read posts to the mark-read endpoint"
  (define (open-loopback-listener)
    (let loop ([tries 20])
      (define p (+ 20000 (random 40000)))
      (with-handlers ([exn:fail?
                       (λ (_)
                         (when (zero? tries) (error 'write-test "no free port"))
                         (loop (sub1 tries)))])
        (values (tcp-listen p 4 #f "127.0.0.1") p))))
  (define-values (listener port) (open-loopback-listener))
  (define captured (box #f))
  (define server
    (thread
     (lambda ()
       (define-values (in out) (tcp-accept listener))
       (define request-line (read-line in 'any))
       (define headers
         (let loop2 ([acc (list request-line)])
           (define line (read-line in 'any))
           (if (or (eof-object? line) (string=? line ""))
               (reverse acc)
               (loop2 (cons line acc)))))
       (define content-length
         (for/or ([h (in-list headers)]
                  #:when (string-contains? (string-downcase h) "content-length"))
           (string->number (substring h (string-length "Content-Length: ")))))
       (when (and content-length (> content-length 0))
         (read-string content-length in))
       (display "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" out)
       (close-input-port in)
       (close-output-port out)
       (tcp-close listener)
       (set-box! captured (list request-line headers)))))

  (parameterize ([current-forum-base-url (format "http://127.0.0.1:~a" port)]
                 [current-data-dir
                  (make-temporary-file "threadly-mark-~a" 'directory)])
    ;; a stored key makes the request signed without touching the network
    (define auth-dir (build-path (data-dir) "auth"))
    (make-directory* auth-dir)
    (with-output-to-file (build-path auth-dir "user-api-key")
      (lambda () (display "test-key-789"))
      #:exists 'truncate)
    (check-true (mark-notifications-read)))

  (sync/timeout 5 server)
  (define captured-data (unbox captured))
  (check-true (string-contains? (list-ref captured-data 0)
                                "POST /notifications/mark-read")
              "hits the mark-read endpoint")
  (check-not-false
   (findf (lambda (h) (string-contains? (string-downcase h)
                                        "user-api-key: test-key-789"))
          (list-ref captured-data 1))
   "signed request"))

(skip-unless-openssl
 (test-case "sign-in scopes request read|write|notifications"
   (parameterize ([current-data-dir
                   (make-temporary-file "threadly-scope-~a" 'directory)])
     (define url (auth:auth-begin))
     (check-true (string-contains? url (uri-encode "read|write|notifications"))
                 "write scope requested so posting works"))))

;; auth-begin refuses to run without OpenSSL 3 (graceful skip already covers
;; the other tests; this file needs at least the two above).
