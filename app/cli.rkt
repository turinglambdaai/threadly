#lang racket/base

;; Threadly CLI — the engine drivable from a terminal. Same modules the
;; native shells use. `version` and `doctor` never touch the network, so
;; CI smoke stays hermetic.

(require json
         net/uri-codec
         racket/format
         racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         "core/cache.rkt"
         "core/discourse.rkt"
         "core/paths.rkt"
         "version.rkt")

;; ---- argument parsing -------------------------------------------------------

;; → (values command positionals page json? no-cache?)
(define (parse-args args)
  (let loop ([as args] [pos '()] [page 0] [json? #f] [no-cache? #f])
    (match as
      ['() (values (and (pair? pos) (first (reverse pos)))
                   (reverse (rest (reverse pos)))
                   page json? no-cache?)]
      [(cons "--json" rest) (loop rest pos page #t no-cache?)]
      [(cons "--no-cache" rest) (loop rest pos page json? #t)]
      [(cons "--page" (cons n rest))
       (loop rest pos (or (string->number n) 0) json? no-cache?)]
      [(cons other rest) (loop rest (cons other pos) page json? no-cache?)])))

(define (usage)
  (string-join
   (list "usage: racket app/cli.rkt [--json] [--no-cache] <command> [args]"
         ""
         "commands:"
         "  version              print the app version"
         "  latest [--page N]    list the latest forum topics"
         "  topic <id>           read a thread"
         "  search <query>       search the archive"
         "  categories           list categories"
         "  doctor               local environment check (offline)"
         ""
         "flags:"
         "  --json               emit raw API JSON instead of formatted rows"
         "  --no-cache           bypass the disk cache"
         "  --page N             page number for latest (0-based)")
   "\n"))

;; ---- output helpers ---------------------------------------------------------

(define (print-json doc)
  (write-json doc)
  (newline))

(define (table-row . cells)
  (displayln (string-join cells "  ")))

(define (pad s w)
  (~a s #:min-width w #:align 'right))

;; ---- commands ---------------------------------------------------------------

(define (cmd-version)
  (displayln (format "Threadly ~a" app-version)))

(define (cmd-latest page json?)
  (define doc (fetch-json-cached (format "/latest.json?page=~a" page)))
  (if json?
      (print-json doc)
      (for ([t (in-list (parse-latest doc))])
        (table-row (~a (topic-summary-id t) #:min-width 7)
                   (pad (topic-summary-posts-count t) 4)
                   (pad (topic-summary-views t) 6)
                   (~a (topic-summary-category-id t) #:min-width 4)
                   (topic-summary-title t)))))

(define (cmd-topic id json?)
  (define doc (fetch-json-cached (format "/t/~a.json" id)))
  (if json?
      (print-json doc)
      (let-values ([(topic posts) (parse-topic doc)])
        (displayln (topic-summary-title topic))
        (displayln (make-string (min 72 (max 16 (string-length (topic-summary-title topic)))) #\u2500))
        (for ([p (in-list posts)])
          (displayln (format "── #~a · ~a · ~a ──"
                             (forum-post-post-number p)
                             (forum-post-username p)
                             (or (forum-post-created-at p) "")))
          (displayln (html->text (forum-post-cooked p)))
          (newline)))))

(define (cmd-search q json?)
  (define doc (fetch-json-cached (format "/search.json?q=~a" (uri-encode q))))
  (if json?
      (print-json doc)
      (for ([r (in-list (parse-search doc))])
        (table-row (~a (search-result-id r) #:min-width 7)
                   (pad (search-result-posts-count r) 4)
                   (search-result-title r)))))

(define (cmd-categories json?)
  (define doc (fetch-json-cached "/categories.json"))
  (if json?
      (print-json doc)
      (for ([c (in-list (parse-categories doc))])
        (table-row (~a (forum-category-id c) #:min-width 7)
                   (forum-category-color c)
                   (forum-category-name c)))))

;; offline: data dir writable, cache entry count
(define (cmd-doctor)
  (define dir (with-handlers ([exn:fail? (lambda (_) #f)]) (ensure-data-dir!)))
  (displayln "Threadly doctor")
  (displayln (format "version:  ~a" app-version))
  (displayln (format "forum:    ~a" (current-forum-base-url)))
  (cond
    [(not dir)
     (displayln "data-dir: NOT WRITABLE")
     (exit 1)]
    [else
     (displayln (format "data-dir: ~a (writable)" dir))
     (define cache (build-path dir "cache"))
     (define entries
       (if (directory-exists? cache)
           (length (directory-list cache))
           0))
     (displayln (format "cache:    ~a entrie~a" entries (if (= entries 1) "y" "s")))]))

;; ---- entry ------------------------------------------------------------------

(define (main args)
  (define-values (command positionals page json? no-cache?)
    (parse-args args))
  (cond
    [(not command)
     (displayln (usage))
     (exit 2)]
    [else
     (parameterize ([current-cache-ttl-seconds (if no-cache? 0 300)])
       (match command
         ["version" (cmd-version)]
         ["latest" (cmd-latest page json?)]
         ["topic"
          (match positionals
            [(list id) (cmd-topic id json?)]
            [_ (displayln (usage) (current-error-port)) (exit 2)])]
         ["search"
          (match positionals
            [(list q) (cmd-search q json?)]
            [_ (displayln (usage) (current-error-port)) (exit 2)])]
         ["categories" (cmd-categories json?)]
         ["doctor" (cmd-doctor)]
         [_ (displayln (format "threadly: unknown command: ~a\n\n~a" command (usage))
                            (current-error-port))
            (exit 2)]))]))

(module+ main
  (with-handlers
      ([exn:fail:network?
        (lambda (e) (eprintf "threadly: network error: ~a\n" (exn-message e)) (exit 1))]
       [exn:fail?
        (lambda (e) (eprintf "threadly: error: ~a\n" (exn-message e)) (exit 1))])
    (main (vector->list (current-command-line-arguments)))))
