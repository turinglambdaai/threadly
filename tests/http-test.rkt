#lang racket/base

;; Redirect-following test against a loopback server: hop 1 answers 302,
;; hop 2 answers 200 and asserts the User-Agent survived the redirect
;; (Discourse's CDN hands out 301/302s; a UA-less second hop can be
;; throttled or refused).

(require rackunit
         racket/file
         racket/list
         racket/string
         racket/tcp
         "../app/core/http.rkt")

(define (read-request-headers in)
  (read-line in 'any) ; request line
  (let loop ([acc '()])
    (define line (read-line in 'any))
    (if (or (eof-object? line) (string=? line ""))
        (reverse acc)
        (loop (cons line acc)))))

;; racket/tcp has no way to read back the port of a port-0 listener, so
;; grab a random free port in the private range with retries
(define (open-loopback-listener)
  (let loop ([tries 20])
    (define port (+ 20000 (random 40000)))
    (with-handlers ([exn:fail?
                     (lambda (_)
                       (when (zero? tries) (error 'http-test "no free port"))
                       (loop (sub1 tries)))])
      (values (tcp-listen port 4 #f "127.0.0.1") port))))

(test-case "http-get-bytes follows redirects and keeps the User-Agent"
  (define-values (listener port) (open-loopback-listener))
  (define headers-box (box #f))
  (define done (make-semaphore))
  (define server
    (thread
     (lambda ()
       ;; hop 1 → 302 to hop 2 on the same port
       (define-values (in1 out1) (tcp-accept listener))
       (read-request-headers in1)
       (fprintf out1 "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:~a/final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" port)
       (close-input-port in1)
       (close-output-port out1)
       ;; hop 2 → 200, remember what the client sent
       (define-values (in2 out2) (tcp-accept listener))
       (set-box! headers-box (read-request-headers in2))
       (fprintf out2 "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
       (close-input-port in2)
       (close-output-port out2)
       (tcp-close listener)
       (semaphore-post done))))

  (define-values (code _headers body)
    (http-get-bytes (format "http://127.0.0.1:~a/start" port)))
  (check-equal? code 200)
  (check-equal? body #"ok")
  (check-true (and (sync/timeout 5 done) #t) "server should finish both hops")
  (define sent (unbox headers-box))
  (check-true (and sent (pair? sent)) "second hop should have been captured")
  (check-true
   (and sent
        (and (findf (lambda (h)
                      (string-contains? (string-downcase h) "user-agent: threadly/"))
                    sent)
             #t))
   "the User-Agent must survive the redirect hop"))

(test-case "http-download-file requests the redirect target, not the original URL"
  ;; Regression for the OTA download leg: the loop split the outer original
  ;; URL every hop, so a GitHub-style 302 chain re-requested /start until
  ;; the hop budget ran out and the download never landed. The second hop
  ;; answers 200 with the payload only for the redirected path — a client
  ;; still asking for /start gets a 404 and the file stays absent.
  (define-values (listener port) (open-loopback-listener))
  (define payload (make-bytes 4096 7))
  (define done (make-semaphore))
  (define server
    (thread
     (lambda ()
       ;; hop 1 → 302 to /final
       (define-values (in1 out1) (tcp-accept listener))
       (read-request-headers in1)
       (fprintf out1 "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:~a/final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" port)
       (close-input-port in1)
       (close-output-port out1)
       ;; hop 2 → 200 payload only for the redirected path
       (define-values (in2 out2) (tcp-accept listener))
       (define request-line (read-line in2 'any))
       (if (regexp-match? #rx"^GET /final " (or request-line ""))
           (begin
             (fprintf out2 "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n" (bytes-length payload))
             (write-bytes payload out2))
           (fprintf out2 "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
       (close-input-port in2)
       (close-output-port out2)
       (tcp-close listener)
       (semaphore-post done))))

  (define dest (make-temporary-file "threadly-dl-~a" 'directory))
  (define target (build-path dest "artifact.bin"))
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (define-values (code written)
        (http-download-file (format "http://127.0.0.1:~a/start" port)
                            target))
      (check-equal? code 200)
      (check-equal? written (bytes-length payload))
      (check-true (file-exists? target) "the redirected payload must be written")
      (when (file-exists? target)
        (check-equal? (file->bytes target) payload)))
    (lambda ()
      (delete-directory/files dest)
      (kill-thread server)
      ;; The server thread owns the close in the success path; tolerate a
      ;; already-closed listener when the test failed early.
      (with-handlers ([exn:fail? void]) (tcp-close listener))
      (sync/timeout 1 (thread-dead-evt server)))))
