#lang racket/base

;; M3 tests: the AI config store (roundtrip, 0600, defaults on garbage)
;; and the chat-completions wire shape against a loopback server — both
;; the direct POST and the full summarize path (forum JSON from one
;; loopback, model answer from another). No network, no API key needed.

(require json
         net/base64
         rackunit
         racket/file
         racket/format
         racket/port
         racket/string
         racket/tcp
         (file "../app/ai.rkt")
         (file "../app/core/discourse.rkt")
         (file "../app/core/paths.rkt"))

;; ---- config store ------------------------------------------------------------

(parameterize ([current-data-dir
                (make-temporary-file "threadly-ai-~a" 'directory)])
  (test-case "ai config defaults and roundtrip"
    (check-false (ai-configured?) "fresh data dir is not configured")
    (define settings (ai-config-read))
    (check-equal? (ai-settings-target-language settings) "Chinese")

    (ai-config-save! "https://api.example.com/v1" "sk-secret-123"
                     "test-model" "English")
    (check-true (ai-configured?))
    (define saved (ai-config-read))
    (check-equal? (ai-settings-base-url saved) "https://api.example.com/v1")
    (check-equal? (ai-settings-api-key saved) "sk-secret-123")
    (check-equal? (ai-settings-model saved) "test-model")
    (check-equal? (ai-settings-target-language saved) "English")

    ;; the key must not be world-readable (POSIX; Windows has no chmod)
    (unless (eq? (system-type) 'windows)
      (check-equal? (file-or-directory-permissions (ai-config-path) 'bits)
                    384
                    "0600 on the config file")))

  (test-case "garbage config falls back to defaults"
    (with-output-to-file (ai-config-path)
      (lambda () (display "not json at all"))
      #:exists 'truncate)
    (define settings (ai-config-read))
    (check-equal? (ai-settings-base-url settings)
                  (ai-settings-base-url (ai-config-read))
                  "stable defaults")))

;; ---- loopback plumbing ---------------------------------------------------------

(define (read-request in)
  (define request-line (read-line in 'any))
  (define headers
    (let loop ([acc (list request-line)])
      (define line (read-line in 'any))
      (if (or (eof-object? line) (string=? line ""))
          (reverse acc)
          (loop (cons line acc)))))
  (define content-length
    (for/or ([h (in-list headers)]
             #:when (string-contains? (string-downcase h) "content-length"))
      (string->number (substring h (string-length "Content-Length: ")))))
  (define body
    (if (and content-length (> content-length 0))
        (read-string content-length in)
        ""))
  (list request-line headers body))

(define (open-loopback-listener)
  (let loop ([tries 20])
    (define p (+ 20000 (random 40000)))
    (with-handlers ([exn:fail?
                     (λ (_)
                       (when (zero? tries) (error 'ai-test "no free port"))
                       (loop (sub1 tries)))])
      (values (tcp-listen p 4 #f "127.0.0.1") p))))

(define (chat-answer-json)
  (jsexpr->string (hasheq 'choices
                          (list (hasheq 'message
                                        (hasheq 'role "assistant"
                                                'content "the model said this"))))))

;; ---- chat-completions wire shape --------------------------------------------------

(test-case "summarize hits the forum and the chat endpoint correctly"
  (define-values (forum-listener forum-port) (open-loopback-listener))
  (define-values (ai-listener ai-port) (open-loopback-listener))
  (define captured (box #f))

  ;; forum leg: /t/7.json with two posts
  (define forum-doc
    (jsexpr->string
     (hasheq 'id 7
             'title "Test thread"
             'posts_count 2
             'post_stream
             (hasheq 'posts
                     (list (hasheq 'id 11 'username "alice" 'cooked "<p>hello world</p>"
                                   'post_number 1
                                   'actions_summary (list (hasheq 'id 2 'count 3 'acted #t)))
                           (hasheq 'id 12 'username "bob" 'cooked "<p>a reply</p>"
                                   'post_number 2
                                   'actions_summary (list)))))))
  (define forum-server
    (thread
     (lambda ()
       (define-values (in out) (tcp-accept forum-listener))
       (read-request in)
       (display (string-append "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                               (~a (string-length forum-doc))
                               "\r\n\r\n" forum-doc)
                out)
       (close-input-port in) (close-output-port out) (tcp-close forum-listener))))

  ;; ai leg: capture the request, answer with one choice
  (define ai-server
    (thread
     (lambda ()
       (define-values (in out) (tcp-accept ai-listener))
       (define captured-request (read-request in))
       (display (string-append "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                               (~a (string-length (chat-answer-json)))
                               "\r\n\r\n" (chat-answer-json))
                out)
       (close-input-port in) (close-output-port out) (tcp-close ai-listener)
       (set-box! captured captured-request))))

  (parameterize ([current-data-dir
                  (make-temporary-file "threadly-ai-wire-~a" 'directory)]
                 [current-forum-base-url (format "http://127.0.0.1:~a" forum-port)])
    (ai-config-save! (format "http://127.0.0.1:~a/v1" ai-port)
                     "sk-wire-test" "wire-model" "Chinese")
    (define answer (ai-summarize-topic 7))
    (check-equal? answer "the model said this"))

  (sync/timeout 5 ai-server)
  (define request-line (list-ref (unbox captured) 0))
  (define headers (list-ref (unbox captured) 1))
  (define body (list-ref (unbox captured) 2))

  (check-true (string-contains? request-line "POST /v1/chat/completions")
              "chat completions on the configured base url")
  (check-not-false
   (findf (lambda (h) (string-contains? (string-downcase h)
                                        "authorization: bearer sk-wire-test"))
          headers)
   "bearer auth header")
  (define doc (read-json (open-input-string body)))
  (check-equal? (hash-ref doc 'model) "wire-model")
  (define messages (hash-ref doc 'messages))
  (check-equal? (length messages) 2)
  (check-true (string-contains? (hash-ref (list-ref messages 1) 'content)
                                "alice")
              "transcript carries the post authors")
  (check-true (string-contains? (hash-ref (list-ref messages 1) 'content)
                                "hello world")
              "transcript carries the post text")
  (check-true (string-contains? (hash-ref (car messages) 'content)
                                "Chinese")
              "target language reaches the prompt"))

(test-case "translate asks for the configured language"
  (define-values (ai-listener ai-port) (open-loopback-listener))
  (define captured (box #f))
  (define ai-server
    (thread
     (lambda ()
       (define-values (in out) (tcp-accept ai-listener))
       (define captured-request (read-request in))
       (display (string-append "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                               (~a (string-length (chat-answer-json)))
                               "\r\n\r\n" (chat-answer-json))
                out)
       (close-input-port in) (close-output-port out) (tcp-close ai-listener)
       (set-box! captured captured-request))))

  (parameterize ([current-data-dir
                  (make-temporary-file "threadly-ai-tr-~a" 'directory)])
    (ai-config-save! (format "http://127.0.0.1:~a/v1" ai-port)
                     "sk-wire-test" "wire-model" "Japanese")
    (define answer (ai-translate-topic 7))
    (check-equal? answer "the model said this"))

  (sync/timeout 5 ai-server)
  (define body (list-ref (unbox captured) 2))
  (define doc (read-json (open-input-string body)))
  (check-true (string-contains? (hash-ref (car (hash-ref doc 'messages)) 'content)
                                "Japanese")
              "translation prompt targets the configured language"))
