#lang racket/base

;; M3 reading value-add: thread summaries and translation over any
;; OpenAI-compatible chat-completions endpoint. Configuration lives in the
;; data directory as ai-config.json (0600 on POSIX) and is written by the
;; CLI's `ai-config` command — no SDK, one endpoint, plain JSON.

(require json
         racket/file
         racket/format
         racket/string
         "core/discourse.rkt"
         "core/http.rkt"
         "core/paths.rkt")

(provide ai-config-path
         ai-settings
         ai-settings?
         ai-settings-base-url
         ai-settings-api-key
         ai-settings-model
         ai-settings-target-language
         ai-configured?
         ai-config-read
         ai-config-save!
         ai-summarize-topic
         ai-translate-topic)

(struct ai-settings (base-url api-key model target-language) #:transparent)

(define defaults
  (ai-settings "https://api.openai.com/v1" "" "gpt-4o-mini" "Chinese"))

(define (ai-config-path)
  (build-path (ensure-data-dir!) "ai-config.json"))

;; → ai-settings; missing file or fields fall back to the defaults, so a
;; half-written config never crashes a host.
(define (ai-config-read)
  (with-handlers ([exn:fail? (lambda (_) defaults)])
    (unless (file-exists? (ai-config-path)) (error 'ai-config "not configured"))
    (define doc (read-json (open-input-bytes (file->bytes (ai-config-path)))))
    (unless (hash? doc) (error 'ai-config "expected a JSON object"))
    (define (field name default)
      (define v (hash-ref doc name default))
      (if (string? v) v default))
    (ai-settings (field 'base-url (ai-settings-base-url defaults))
                 (field 'api-key "")
                 (field 'model (ai-settings-model defaults))
                 (field 'target-language (ai-settings-target-language defaults)))))

;; Save; the key must not be world-readable (same guard as the auth files).
(define (ai-config-save! base-url api-key model target-language)
  (define doc
    (hasheq 'base-url base-url
            'api-key api-key
            'model model
            'target-language target-language))
  (with-output-to-file (ai-config-path)
    (lambda () (write-json doc))
    #:exists 'truncate)
  (restrict-config-permissions!)
  (ai-config-path))

(define (restrict-config-permissions!)
  (unless (eq? (system-type) 'windows)
    (file-or-directory-permissions (ai-config-path) 384)))

(define (ai-configured?)
  (define c (ai-config-read))
  (non-empty-string? (string-trim (ai-settings-api-key c))))

;; One chat completion. messages is a list of (role . content) pairs.
;; → the assistant message content.
(define (chat-completion settings messages)
  (define base (string-trim (ai-settings-base-url settings)))
  (define url
    (if (string-suffix? base "/")
        (string-append base "chat/completions")
        (string-append base "/chat/completions")))
  (define body
    (hasheq 'model (ai-settings-model settings)
            'temperature 0.2
            'messages (for/list ([m (in-list messages)])
                        (hasheq 'role (car m) 'content (cdr m)))))
  (define-values (code resp)
    (http-post-json url body
                    (list (string-append
                           "Authorization: Bearer "
                           (ai-settings-api-key settings)))))
  (unless (= code 200)
    (define detail
      (with-handlers ([exn:fail? (lambda (_) "")])
        (define doc (read-json (open-input-bytes resp)))
        (or (and (hash? doc)
                 (hash? (hash-ref doc 'error #f))
                 (hash-ref (hash-ref doc 'error #f) 'message #f))
            "")))
    (error 'ai "HTTP ~a~a" code
           (if (string=? detail "") "" (string-append ": " detail))))
  (define doc (read-json (open-input-bytes resp)))
  (define choices (hash-ref doc 'choices (list)))
  (unless (pair? choices) (error 'ai "no choices in the response"))
  (define message (hash-ref (car choices) 'message (hasheq)))
  (hash-ref message 'content ""))

;; The raw material: every post as "#n author:\ntext" under the title.
(define (thread-transcript title posts)
  (string-join
   (cons (string-append "Title: " title)
         (for/list ([p (in-list posts)])
           (string-append "#" (~a (forum-post-post-number p))
                          " " (forum-post-username p) ":\n"
                          (html->text (forum-post-cooked p)))))
   "\n\n"))

(define (summarize-messages transcript target-language)
  (list (cons "system"
              (string-append "You summarize forum threads for a reader who "
                             "has not read them. Answer in " target-language
                             ". Cover: what the thread is about, the key "
                             "points or disagreements, and any conclusion. "
                             "Be concrete and under 250 words. Plain text "
                             "only, no markdown headers."))
        (cons "user" transcript)))

(define (translate-messages transcript target-language)
  (list (cons "system"
              (string-append "You translate forum threads. Translate every "
                             "post into " target-language ", keeping the "
                             "\"#n author:\" structure exactly so posts stay "
                             "separable. Translate faithfully; keep code "
                             "blocks and technical identifiers as-is."))
        (cons "user" transcript)))

(define (run-over-topic topic-id make-messages)
  (define-values (topic posts) (fetch-topic topic-id))
  (define settings (ai-config-read))
  (chat-completion
   settings
   (make-messages
    (thread-transcript (topic-summary-title topic) posts)
    (ai-settings-target-language settings))))

;; Both entry points raise on network/API failure; callers surface the
;; message. Long calls (tens of seconds) are expected.
(define (ai-summarize-topic topic-id)
  (run-over-topic topic-id summarize-messages))

(define (ai-translate-topic topic-id)
  (run-over-topic topic-id translate-messages))
