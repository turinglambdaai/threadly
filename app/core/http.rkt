#lang racket/base

;; Minimal HTTP(S) client over net/http-client. Redirects are followed
;; manually — up to 5 hops, preserving the User-Agent on every hop —
;; because the Discourse CDN hands out 301/302s and the default client
;; would otherwise surface the redirect page as the body.

(require net/http-client
         net/uri-codec
         racket/file
         racket/format
         racket/list
         racket/port
         racket/string
         "../version.rkt")

(provide http-user-agent
         split-url
         status-code
         header-value
         headers->strings
         http-get-bytes
         http-get-string
         http-post-form
         http-download-file
         form-encode-fields)

(define http-user-agent
  (format "Threadly/~a (+https://github.com/turinglambdaai/threadly)" app-version))

;; ---- URL splitting (no net/url dependency; forum URLs are plain https) ----

;; → (values ssl? host port path)
(define (split-url u)
  (define m
    (regexp-match #rx"^https?://([^/:?#]+)(:([0-9]+))?(/[^?#]*)?(\\?.*)?$" u))
  (unless m
    (raise-argument-error 'split-url "absolute http(s) URL" u))
  (define ssl? (string-prefix? u "https://"))
  (define host (list-ref m 1))
  (define port
    (cond
      [(list-ref m 3) (string->number (list-ref m 3))]
      [ssl? 443]
      [else 80]))
  (define path
    (string-append
     (or (list-ref m 4) "/")
     (or (list-ref m 5) "")))
  (values ssl? host port path))

;; ---- request core ----------------------------------------------------------

(define (headers->strings headers)
  (map (lambda (h) (if (bytes? h) (bytes->string/utf-8 h) h)) headers))

(define (header-value headers name)
  (define m
    (findf (lambda (h)
             (regexp-match (format "(?i:^~a:)" (regexp-quote name)) h))
           headers))
  (and m
       (string-trim
        (second (regexp-match (format "(?i:^~a:\\s*(.*)$)" (regexp-quote name)) m)))))

;; status line like "HTTP/1.1 200 OK" → 200
(define (status-code status)
  (define s (if (bytes? status) (bytes->string/utf-8 status) status))
  (define m (regexp-match #px"HTTP/[0-9.]+ +([0-9]+)" s))
  (and m (string->number (second m))))

(define (content-length-or-#f headers)
  (define v (header-value headers "content-length"))
  (and v (string->number (string-trim v))))

;; One request, no redirects. → (values status headers body-bytes)
;; Bodies are read to EOF with Connection: close.
(define (request-once url-string headers)
  (define-values (ssl? host port path) (split-url url-string))
  (define conn
    (http-conn-open host #:ssl? ssl? #:port port))
  (define all-headers
    (append (list (format "User-Agent: ~a" http-user-agent)
                  "Accept: application/json"
                  "Connection: close")
            headers))
  (define-values (status resp-headers body-port)
    (http-conn-sendrecv! conn path #:method "GET" #:headers all-headers))
  (define resp-headers* (headers->strings resp-headers))
  (define body (port->bytes body-port))
  (close-input-port body-port)
  (with-handlers ([exn:fail? void]) (http-conn-close! conn))
  (values (status-code status) resp-headers* body))

;; GET with up to 5 redirect hops. → (values code headers body-bytes)
(define (http-get-bytes url-string [extra-headers (list)])
  (let loop ([url url-string] [hops 0])
    (define-values (code headers body)
      (request-once url extra-headers))
    (if (and (member code '(301 302 303 307 308)) (< hops 5))
        (let ([location (header-value headers "location")])
          (unless location
            (error 'http-get-bytes "redirect without Location from ~a" url))
          (loop location (add1 hops)))
        (values code headers body))))

(define (http-get-string url-string)
  (define-values (code headers body) (http-get-bytes url-string))
  (values code headers (bytes->string/utf-8 body)))

;; ---- form POST (Discourse write API) -----------------------------------------

;; application/x-www-form-urlencoded body from an alist of (key . value).
;; Values may be strings; newlines and unicode survive the round trip.
(define (form-encode-fields fields)
  (string-join
   (for/list ([kv (in-list fields)])
     (string-append (uri-encode (car kv)) "=" (uri-encode (cdr kv))))
   "&"))

;; POST a urlencoded form, following up to 5 redirect hops (Discourse
;; answers some writes with a temporary). → (values code headers body-bytes)
(define (http-post-form url-string fields [extra-headers (list)])
  (define body (string->bytes/utf-8 (form-encode-fields fields)))
  (define-values (ssl? host port path) (split-url url-string))
  (define conn (http-conn-open host #:ssl? ssl? #:port port))
  (define all-headers
    (append (list (format "User-Agent: ~a" http-user-agent)
                  "Content-Type: application/x-www-form-urlencoded; charset=utf-8"
                  (format "Content-Length: ~a" (bytes-length body))
                  "Connection: close")
            extra-headers))
  (define-values (status resp-headers body-port)
    (http-conn-sendrecv! conn path
                         #:method "POST"
                         #:headers all-headers
                         #:data body))
  (define code (status-code status))
  (define resp-headers* (headers->strings resp-headers))
  (define resp-body (port->bytes body-port))
  (close-input-port body-port)
  (with-handlers ([exn:fail? void]) (http-conn-close! conn))
  ;; follow redirects for POSTs that answer 30x (rare, but the forum can)
  (let follow ([code code] [resp-headers* resp-headers*] [resp-body resp-body] [hops 0])
    (define location
      (for/or ([h (in-list resp-headers*)] #:when (string-prefix? (string-downcase h) "location:"))
        (string-trim (substring h (string-length "location:")))))
    (if (and (member code '(301 302 303 307 308)) location (< hops 5))
        (let-values ([(ssl2? host2 port2 path2) (split-url location)])
          (define conn2 (http-conn-open host2 #:ssl? ssl2? #:port port2))
          (define-values (st2 rh2 bp2)
            (http-conn-sendrecv! conn2 path2 #:method "GET"
                                 #:headers (list (format "User-Agent: ~a" http-user-agent)
                                                 "Connection: close")))
          (define c2 (status-code st2))
          (define rh* (headers->strings rh2))
          (define b2 (port->bytes bp2))
          (close-input-port bp2)
          (with-handlers ([exn:fail? void]) (http-conn-close! conn2))
          (follow c2 rh* b2 (add1 hops)))
        (values code resp-headers* resp-body))))

;; DELETE with the same header plumbing (Discourse un-like).
(define (http-delete url-string [extra-headers (list)])
  (define-values (ssl? host port path) (split-url url-string))
  (define conn (http-conn-open host #:ssl? ssl? #:port port))
  (define all-headers
    (append (list (format "User-Agent: ~a" http-user-agent)
                  "Connection: close")
            extra-headers))
  (define-values (status resp-headers body-port)
    (http-conn-sendrecv! conn path #:method "DELETE" #:headers all-headers))
  (define code (status-code status))
  (define body (port->bytes body-port))
  (close-input-port body-port)
  (with-handlers ([exn:fail? void]) (http-conn-close! conn))
  (values code body))

;; Stream a download to dest-path. on-progress is called as
;; (on-progress done-bytes total-bytes-or-#f) at most every 256 KiB.
;; Returns (values code bytes-written). Raises on network failure only;
;; non-200 responses still write nothing and return the code.
(define (http-download-file url-string dest-path [on-progress (lambda (_a _b) (void))])
  ;; release assets answer with a 30x to their CDN — chase up to 5 hops,
  ;; mirroring http-get-bytes
  (let download-loop ([url url-string] [hops 0])
    (define-values (ssl? host port path) (split-url url-string))
    (define conn (http-conn-open host #:ssl? ssl? #:port port))
    (define-values (status resp-headers body-port)
      (http-conn-sendrecv! conn path
                           #:method "GET"
                           #:headers (list (format "User-Agent: ~a" http-user-agent)
                                           "Accept: */*"
                                           "Connection: close")))
    (define code (status-code status))
    (define resp-headers-strs (headers->strings resp-headers))
    (cond
      [(and (member code '(301 302 303 307 308)) (< hops 5))
       (define location (header-value resp-headers-strs "location"))
       (close-input-port body-port)
       (unless location
         (error 'http-download-file "redirect without Location from ~a" url))
       (download-loop location (add1 hops))]
      [else
       (download-into! conn code resp-headers-strs body-port dest-path on-progress)])))

(define (download-into! conn code resp-headers-strs body-port dest-path on-progress)
  (define total (content-length-or-#f resp-headers-strs))
  (define written 0)
  (define last-reported 0)
  (if (not (= code 200))
      (begin (close-input-port body-port)
             (with-handlers ([exn:fail? void]) (http-conn-close! conn))
             (values code 0))
      (begin
        ;; binary mode is load-bearing: a text-mode port on Windows turns
        ;; every 0x0A into 0x0D 0x0A, which would corrupt downloads (update
        ;; archives) and fail every byte-exact checksum
        (with-output-to-file dest-path
          (lambda ()
            (let copy ([chunk (read-bytes 262144 body-port)])
              (unless (eof-object? chunk)
                (write-bytes chunk)
                (set! written (+ written (bytes-length chunk)))
                (when (or (>= (- written last-reported) 262144)
                          (and total (>= written total)))
                  (set! last-reported written)
                  (on-progress written total))
                (copy (read-bytes 262144 body-port)))))
          #:exists 'truncate
          #:mode 'binary)
        (close-input-port body-port)
        (with-handlers ([exn:fail? void]) (http-conn-close! conn))
        (values code written))))
