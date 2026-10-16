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
         fetch-topic-all
         fetch-topic-all-batch-size
         fetch-search
         parse-search
         fetch-categories
         parse-categories
         fetch-category-topics
         fetch-current-user
         fetch-notifications
         parse-notifications
         notification-type-label
         (struct-out forum-notification)
         create-post
         like-post
         mark-notifications-read
         (struct-out created-post)
         html->text)

(struct topic-summary (id title slug created-at last-posted-at
                       posts-count reply-count views like-count category-id)
  #:transparent)

(struct forum-post (id username avatar-template created-at cooked post-number
                    like-count liked?)
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
(define (parse-post p)
  ;; like state lives in actions_summary under the like action (id 2);
  ;; `acted` only appears on signed-in requests — that's the "you
  ;; liked this" flag the like buttons render from.
  (define like-action
    (for/or ([a (in-list (hash-ref p 'actions_summary (list)))])
      (and (eq? (hash-ref a 'id 0) 2) a)))
  (forum-post (hash-ref p 'id 0)
              (hash-ref p 'username "")
              (hash-ref p 'avatar_template "")
              (json-clean (hash-ref p 'created_at #f))
              (hash-ref p 'cooked "")
              (hash-ref p 'post_number 0)
              (or (and like-action (hash-ref like-action 'count #f)) 0)
              (and like-action (eq? (json-clean (hash-ref like-action 'acted #f)) #t))))

(define (parse-topic doc)
  (hash-or-fail 'parse-topic doc)
  (define topic (parse-topic-summary doc))
  (define post-stream (hash-ref doc 'post_stream (hasheq)))
  (define posts
    (for/list ([p (in-list (hash-ref post-stream 'posts (list)))])
      (parse-post p)))
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

;; The whole thread. /t/<id>.json supplies the topic, the first chunk of
;; posts, and `stream` — every post id in reading order; posts past the
;; first chunk come from /t/<id>/posts.json in batches of post_ids[]
;; (the same call the forum's own web app makes). Those batches are
;; signed like every read but skip the disk cache: each is one slice of
;; a moving whole, and caching slices would pin a thread to its old tail.
(define fetch-topic-all-batch-size (make-parameter 20))

;; Split a list into consecutive groups of n (the last one short).
;; racket/list here has no in-slice to lean on.
(define (chunk n xs)
  (if (null? xs)
      (list)
      (let ([part (take xs (min n (length xs)))])
        (cons part (chunk n (list-tail xs (length part)))))))

(define (fetch-topic-all id)
  (define doc (fetch-json-cached (format "/t/~a.json" id)))
  (hash-or-fail 'fetch-topic-all doc)
  (define topic (parse-topic-summary doc))
  (define post-stream (hash-ref doc 'post_stream (hasheq)))
  (define head
    (for/list ([p (in-list (hash-ref post-stream 'posts (list)))])
      (parse-post p)))
  (define head-ids
    (for/hasheq ([p (in-list head)]) (values (forum-post-id p) #t)))
  (define rest-ids
    (for/list ([i (in-list (hash-ref post-stream 'stream (list)))]
               #:unless (hash-ref head-ids i #f))
      i))
  (define rest
    (for/list ([ids (in-list (chunk (fetch-topic-all-batch-size) rest-ids))])
      (define doc2
        (fetch-json
         (string-append
          (current-forum-base-url)
          (format "/t/~a/posts.json?~a" id
                  (string-join
                   (for/list ([i (in-list ids)]) (format "post_ids[]=~a" i))
                   "&")))))
      (for/list ([p (in-list (hash-ref (hash-ref doc2 'post_stream (hasheq))
                                       'posts (list)))])
        (parse-post p))))
  ;; the stream lists post ids in reading order, so the merged list is
  ;; kept in post-number order no matter what the batches returned
  (values topic
          (sort (append head (append* rest))
                < #:key forum-post-post-number)))

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

;; ---- notifications (signed-in reads) -----------------------------------------

(struct forum-notification (id type-label read? created-at topic-id title username)
  #:transparent)

;; Discourse notification_type integers -> human labels. Unknown types
;; fall back to "notification" so future forum features degrade gracefully.
(define (notification-type-label n)
  (case n
    [(1) "mention"] [(2) "reply"] [(3) "quote"] [(4) "edited"]
    [(5) "like"] [(6) "message"] [(9) "posted"] [(11) "link"]
    [(15) "group-mention"] [(18) "likes"]
    [else "notification"]))

(define (parse-notifications doc)
  (hash-or-fail 'parse-notifications doc)
  (for/list ([n (in-list (hash-ref doc 'notifications (list)))])
    (define data (hash-ref n 'data (hasheq)))
    (forum-notification
     (hash-ref n 'id 0)
     (notification-type-label (hash-ref n 'notification_type 0))
     (eq? (json-clean (hash-ref n 'read #f)) #t)
     (json-clean (hash-ref n 'created_at #f))
     (json-clean (hash-ref n 'topic_id #f))
     (hash-ref data 'topic_title "")
     (hash-ref data 'display_username ""))))

;; Requires a signed-in user: the endpoint 404s without User-Api-Key.
(define (fetch-notifications)
  (unless (auth:auth-signed-in?)
    (error 'fetch-notifications "sign in to see notifications"))
  (parse-notifications (fetch-json-cached "/notifications.json")))

;; ---- writes (M2: reply; needs read|write scope) ------------------------------

(struct created-post (id post-number topic-slug) #:transparent)

;; Reply to a topic (or to a specific post when reply-to is given).
;; → created-post. Raises signed-in / HTTP / Discourse errors with the
;; forum's own message when present (rate limits, validation).
(define (create-post topic-id raw [reply-to-post-number #f])
  (define key (or (auth:auth-api-key)
                  (error 'create-post "sign in to reply")))
  (define fields
    (append (list (cons "topic_id" (~a topic-id))
                  (cons "raw" raw))
            (if reply-to-post-number
                (list (cons "reply_to_post_number" (~a reply-to-post-number)))
                (list))))
  (define-values (code _h body)
    (http-post-form (string-append (current-forum-base-url) "/posts.json")
                    fields
                    (list (string-append "User-Api-Key: " key))))
  (unless (= code 200)
    (define detail
      (with-handlers ([exn:fail? (λ (_) "")])
        (define doc (read-json (open-input-bytes body)))
        (or (and (hash? doc) (hash-ref doc 'errors #f)
                 (string-join (hash-ref doc 'errors) ", "))
            "")))
    (error 'create-post "HTTP ~a~a" code
           (if (string=? detail "") "" (string-append ": " detail))))
  (define doc (read-json (open-input-bytes body)))
  (created-post (hash-ref doc 'id 0)
                (hash-ref doc 'post_number 0)
                (hash-ref doc 'topic_slug "")))

;; Like (on?) a post; Discourse toggles via was_deleted.
(define (like-post post-id on?)
  (define key (or (auth:auth-api-key)
                  (error 'like-post "sign in to like posts")))
  (define fields
    (append (list (cons "id" (~a post-id))
                  (cons "post_action_type_id" "2"))
            (if on? (list) (list (cons "was_deleted" "true")))))
  (define-values (code _h _b)
    (http-post-form (string-append (current-forum-base-url) "/post_actions.json")
                    fields
                    (list (string-append "User-Api-Key: " key))))
  (unless (= code 200)
    (error 'like-post "HTTP ~a" code))
  on?)

;; Marks every notification read — the forum's own behavior when you view
;; the notifications page; we fire it when the client's Notifications
;; scope loads.
(define (mark-notifications-read)
  (define key (or (auth:auth-api-key)
                  (error 'mark-notifications-read "sign in first")))
  (define-values (code _h _b)
    (http-post-form (string-append (current-forum-base-url)
                                   "/notifications/mark-read")
                    (list)
                    (list (string-append "User-Api-Key: " key))))
  (unless (= code 200)
    (error 'mark-notifications-read "HTTP ~a" code))
  #t)

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
