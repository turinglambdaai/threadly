#lang racket/base

;; Parser tests against recorded forum responses (tests/fixtures/) — no
;; network. The fixtures are real racket.discourse.group payloads; if the
;; parser needs a new field, re-capture the fixture and extend the check.

(require json
         rackunit
         racket/list
         racket/runtime-path
         racket/string
         "../app/core/discourse.rkt")

(define-runtime-path fixtures-dir "fixtures")

(define (load-fixture name)
  (call-with-input-file (build-path fixtures-dir name) read-json))

;; ---- parse-latest -----------------------------------------------------------

(test-case "parse-latest: topic_list.topics"
  (define topics (parse-latest (load-fixture "latest.json")))
  (check-true ((length topics) . > . 0) "fixture should contain topics")
  (define t (first topics))
  (check-true (exact-positive-integer? (topic-summary-id t)))
  (check-true (string? (topic-summary-title t)))
  (check-true ((string-length (topic-summary-title t)) . > . 0))
  (check-true (exact-nonnegative-integer? (topic-summary-posts-count t)))
  (check-true (exact-nonnegative-integer? (topic-summary-views t)))
  (check-true (string? (or (topic-summary-created-at t) ""))))

(test-case "parse-latest: rejects a non-object"
  (check-exn exn:fail? (lambda () (parse-latest '[1 2 3]))))

;; ---- parse-topic ------------------------------------------------------------

(test-case "parse-topic: topic + post stream"
  (define-values (topic posts) (parse-topic (load-fixture "topic.json")))
  (check-true (exact-positive-integer? (topic-summary-id topic)))
  (check-true ((length posts) . > . 0))
  (define p (first posts))
  (check-true (exact-positive-integer? (forum-post-id p)))
  (check-true ((string-length (forum-post-username p)) . > . 0))
  ;; cooked posts are HTML
  (check-true (string-contains? (forum-post-cooked p) "<"))
  ;; post numbering starts at 1
  (check-equal? (forum-post-post-number p) 1))

;; ---- parse-search -----------------------------------------------------------

(test-case "parse-search: top-level topics"
  (define results (parse-search (load-fixture "search.json")))
  (check-true ((length results) . > . 0) "fixture should contain hits")
  (define r (first results))
  (check-true (exact-positive-integer? (search-result-id r)))
  (check-true ((string-length (search-result-title r)) . > . 0)))

;; ---- parse-categories ---------------------------------------------------------

(test-case "parse-categories: category_list.categories"
  (define cats (parse-categories (load-fixture "categories.json")))
  (check-true ((length cats) . > . 0))
  (define c (first cats))
  (check-true (exact-positive-integer? (forum-category-id c)))
  (check-true ((string-length (forum-category-name c)) . > . 0)))

;; ---- html->text ---------------------------------------------------------------

(test-case "html->text: tags and entities"
  (check-equal? (html->text "<p>a &amp; b</p>") "a & b")
  (check-equal? (html->text "1 &lt; 2 &gt; 0") "1 < 2 > 0")
  (check-equal? (html->text "<p>one</p><p>two</p>") "one\n\ntwo")
  (check-equal? (html->text "line<br>break") "line\nbreak")
  (check-equal? (html->text "x&nbsp;&hellip;y") "x …y"))
