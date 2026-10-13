#lang racket/base

;; Discourse API client for racket.discourse.group. Anonymous public JSON
;; only: every forum page URL has a `.json` twin. Parsing is separated from
;; fetching and tested against recorded fixtures, so tests and CI never
;; touch the network.

(require json
         net/uri-codec
         racket/format
         racket/list
         racket/string
         "../version.rkt"
         "cache.rkt"
         "http.rkt"
         (prefix-in auth: "../auth.rkt"))

(provide (struct-out topic-summary)
         (struct-out forum-post)
         (struct-out search-result)
         (struct-out forum-category)
         current-forum-base-url
         fetch-json-cached
         fetch-latest
         parse-latest
         fetch-topic
         parse-topic
         fetch-search
         parse-search
         fetch-categories
         parse-categories
         fetch-category-topics
         fetch-current-user
         html->text)

(struct topic-summary (id title slug created-at last-posted-at
                       posts-count reply-count views like-count category-id)
  #:transparent)

(struct forum-post (id username avatar-template created-at cooked post-number)
  #:transparent)

(struct search-result (id title created-at posts-count) #:transparent)

(struct forum-category (id name slug color) #:transparent)

(define current-forum-base-url (make-parameter "https://racket.discourse.group"))

;; ---- fetching --------------------------------------------------------------

;; JSON GET through the disk cache: a fresh entry answers without the
;; network; a stale entry is refreshed, and still answers (with a log line)
;; when the forum cannot be reached.
(define (fetch-json-cached path)
  (define url (string-append (current-forum-base-url) path))
  (define-values (cached fresh?) (cache-lookup url))
  (if (and cached fresh?)
      cached
      (with-handlers
          ([exn:fail?
            (lambda (e)
              (if cached
                  (begin
                    (log-error "threadly: forum unreachable, serving cached ~a" url)
                    cached)
                  (raise e)))])
        (define doc (fetch-json url))
        (cache-store! url doc)
        doc)))

;; When signed in, every read carries the user's API key so the forum
;; shows what *this* user can see (private categories included).
(define (signed-request-headers)
  (define key (auth:auth-api-key))
  (if key (list (string-append "User-Api-Key: " key)) (list)))

(define (fetch-json url)
  (define-values (code headers body) (http-get-bytes url (signed-request-headers)))
  (unless (= code 200)
    (error 'discourse "HTTP ~a for ~a~a"
           code url
           (if (= code 429) " (rate limited — back off and retry later)" "")))
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (raise (exn:fail (format "discourse: invalid JSON from ~a" url)
                           (exn-continuation-marks e))))])
    (read-json (open-input-bytes body))))

;; ---- parsing (pure functions over jsexpr) ----------------------------------

;; read-json maps JSON null to the 'null symbol; hash-ref's default only
;; fires on a MISSING key, so every optional field goes through this.
(define (json-clean v)
  (if (eq? v 'null) #f v))

(define (hash-or-fail who doc)
  (unless (hash? doc)
    (error who "expected a JSON object"))
  doc)

(define (parse-topic-summary t)
  (topic-summary (hash-ref t 'id 0)
                 (hash-ref t 'title "")
                 (hash-ref t 'slug "")
                 (json-clean (hash-ref t 'created_at #f))
                 (json-clean (hash-ref t 'last_posted_at #f))
                 (hash-ref t 'posts_count 0)
                 (hash-ref t 'reply_count 0)
                 (hash-ref t 'views 0)
                 (hash-ref t 'like_count 0)
                 (hash-ref t 'category_id 0)))

;; /latest.json → (listof topic-summary)
;; (latest nests its topics under topic_list; search returns them top level)
(define (parse-latest doc)
  (hash-or-fail 'parse-latest doc)
  (define topic-list (hash-ref doc 'topic_list (hasheq)))
  (for/list ([t (in-list (hash-ref topic-list 'topics (list)))])
    (parse-topic-summary t)))

;; /t/<id>.json → (values topic-summary (listof forum-post))
(define (parse-topic doc)
  (hash-or-fail 'parse-topic doc)
  (define topic (parse-topic-summary doc))
  (define post-stream (hash-ref doc 'post_stream (hasheq)))
  (define posts
    (for/list ([p (in-list (hash-ref post-stream 'posts (list)))])
      (forum-post (hash-ref p 'id 0)
                  (hash-ref p 'username "")
                  (hash-ref p 'avatar_template "")
                  (json-clean (hash-ref p 'created_at #f))
                  (hash-ref p 'cooked "")
                  (hash-ref p 'post_number 0))))
  (values topic posts))

;; /search.json?q=… → (listof search-result)
(define (parse-search doc)
  (hash-or-fail 'parse-search doc)
  (for/list ([t (in-list (hash-ref doc 'topics (list)))])
    (search-result (hash-ref t 'id 0)
                   (hash-ref t 'title "")
                   (hash-ref t 'created_at #f)
                   (hash-ref t 'posts_count 0))))

;; /categories.json → (listof forum-category)
(define (parse-categories doc)
  (hash-or-fail 'parse-categories doc)
  (define category-list (hash-ref doc 'category_list (hasheq)))
  (for/list ([c (in-list (hash-ref category-list 'categories (list)))])
    (forum-category (hash-ref c 'id 0)
                    (hash-ref c 'name "")
                    (hash-ref c 'slug "")
                    (hash-ref c 'color ""))))

;; ---- public entry points ---------------------------------------------------

(define (fetch-latest [page 0])
  (parse-latest (fetch-json-cached (format "/latest.json?page=~a" page))))

(define (fetch-topic id)
  (parse-topic (fetch-json-cached (format "/t/~a.json" id))))

;; A category page (/c/<slug>/<id>.json) carries the same topic_list shape
;; as latest — parse-latest handles it.
(define (fetch-category-topics slug id)
  (parse-latest (fetch-json-cached (format "/c/~a/~a.json" slug id))))

;; /session/current.json → (values username avatar-template) for the
;; signed-in identity; requires a stored user API key.
(define (fetch-current-user)
  (define key (or (auth:auth-api-key) (error 'fetch-current-user "not signed in")))
  (define doc (fetch-json-cached "/session/current.json"))
  (define user (hash-ref doc 'current_user (hasheq)))
  (values (hash-ref user 'username "")
          (hash-ref user 'avatar_template "")))

(define (fetch-search q)
  (parse-search (fetch-json-cached (format "/search.json?q=~a" (uri-encode q)))))

(define (fetch-categories)
  (parse-categories (fetch-json-cached "/categories.json")))

;; ---- cooked HTML → readable plain text (terminal use) ----------------------

(define entities
  '(("&amp;" . "&")
    ("&lt;" . "<")
    ("&gt;" . ">")
    ("&quot;" . "\"")
    ("&#39;" . "'")
    ("&#x27;" . "'")
    ("&nbsp;" . " ")
    ("&hellip;" . "…")
    ("&mdash;" . "—")))

(define (decode-entities s)
  (for/fold ([s s]) ([pair (in-list entities)])
    (string-replace s (car pair) (cdr pair))))

(define (html->text html)
  (define with-breaks
    (string-replace
     (regexp-replace* #rx"</p>" html "\n\n")
     #rx"<br ?/?>" "\n"))
  (define text (decode-entities (regexp-replace* #rx"<[^>]*>" with-breaks "")))
  ;; collapse runs of blank lines left by block tags
  (string-trim (regexp-replace* #rx"\n{3,}" text "\n\n")))
