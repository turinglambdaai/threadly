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
         "ai.rkt"
         "auth.rkt"
         "version.rkt"
         (prefix-in upd: "update.rkt"))

;; ---- argument parsing -------------------------------------------------------

;; → (values command positionals page json? no-cache?)
(define (parse-args args)
  (let loop ([as args] [pos '()] [page 0] [json? #f] [no-cache? #f])
    (match as
      ['() (values (and (pair? pos) (first (reverse pos)))
                   (rest (reverse pos))
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
         "  reply <id>           reply to a topic (markdown on stdin;"
         "                       needs sign-in via the app)"
         "  summary <id>         AI summary of a thread (needs ai-config)"
         "  translate <id>       AI translation of a thread"
         "  ai-config            show / set the AI endpoint:"
         "                       [--base-url U --api-key K --model M"
         "                        --target-lang L]"
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

(define (cmd-category slug id json?)
  (define doc (fetch-json-cached (format "/c/~a/~a.json" slug id)))
  (if json?
      (print-json doc)
      (for ([t (in-list (parse-latest doc))])
        (table-row (~a (topic-summary-id t) #:min-width 7)
                   (pad (topic-summary-posts-count t) 4)
                   (pad (topic-summary-views t) 6)
                   (topic-summary-title t)))))

;; Reply: raw markdown arrives on stdin so pipelines work —
;;   echo "nice post" | threadly reply 4416
;; Uses the sign-in state the GUI app wrote (same data dir).
(define (cmd-reply topic-id)
  (unless (auth-signed-in?)
    (displayln "threadly: not signed in — sign in with the Threadly app first.")
    (exit 2))
  (define raw (string-trim (port->string (current-input-port))))
  (when (string=? raw "")
    (displayln "threadly: empty reply — pipe the markdown body on stdin.")
    (exit 2))
  (define created
    (create-post (string->number topic-id) raw))
  (displayln (format "posted as #~a (post id ~a)"
                     (created-post-post-number created)
                     (created-post-id created))))

;; ---- M3: AI summary / translation -------------------------------------------

(define (cmd-summary topic-id)
  (unless (ai-configured?)
    (displayln "threadly: AI is not configured — see `ai-config`.")
    (exit 2))
  (displayln (ai-summarize-topic (string->number topic-id))))

(define (cmd-translate topic-id)
  (unless (ai-configured?)
    (displayln "threadly: AI is not configured — see `ai-config`.")
    (exit 2))
  (displayln (ai-translate-topic (string->number topic-id))))

;; `ai-config` shows the current settings (key masked); any of
;; --base-url/--api-key/--model/--target-lang updates and saves.
(define (cmd-ai-config positionals)
  (define current (ai-config-read))
  (define (flag-value name)
    (let loop ([as positionals])
      (match as
        [(cons (== name) (cons v _)) v]
        [(cons _ rest) (loop rest)]
        ['() #f])))
  (define base (or (flag-value "--base-url") (ai-settings-base-url current)))
  (define key (or (flag-value "--api-key") (ai-settings-api-key current)))
  (define model (or (flag-value "--model") (ai-settings-model current)))
  (define lang (or (flag-value "--target-lang")
                   (ai-settings-target-language current)))
  (when (or (flag-value "--base-url") (flag-value "--api-key")
            (flag-value "--model") (flag-value "--target-lang"))
    (unless (and (non-empty-string? base) (non-empty-string? key))
      (displayln "threadly: base-url and api-key must both be non-empty.")
      (exit 2))
    (ai-config-save! base key model lang)
    (set! current (ai-config-read)))
  (define key-shown
    (if (non-empty-string? (ai-settings-api-key current))
        (string-append (substring (ai-settings-api-key current)
                                  0 (min 6 (string-length (ai-settings-api-key current))))
                       "…")
        "(not set)"))
  (displayln "Threadly AI config")
  (displayln (format "base-url:  ~a" (ai-settings-base-url current)))
  (displayln (format "api-key:   ~a" key-shown))
  (displayln (format "model:     ~a" (ai-settings-model current)))
  (displayln (format "language:  ~a" (ai-settings-target-language current)))
  (displayln (format "configured: ~a" (if (ai-configured?) "yes" "no"))))

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

;; verify the signed feed and report; never raises
(define (cmd-update-check)
  (define result
    (with-handlers ([exn:fail? (lambda (e) (list 'failed (exn-message e)))])
      (upd:update-check-result app-version)))
  (match result
    [(list 'available version)
     (displayln (format "update available: ~a (current ~a)" version app-version))]
    [(list 'up-to-date) (displayln "up to date")]
    [(list 'unavailable reason) (displayln (format "unavailable: ~a" reason))]
    [(list 'failed reason) (displayln (format "check failed: ~a" reason))]
    [_ (displayln "unknown result")]))

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
         ["category"
          (match positionals
            [(list slug id) (cmd-category slug id json?)]
            [_ (displayln (usage) (current-error-port)) (exit 2)])]
         ["reply"
          (match positionals
            [(list id) (cmd-reply id)]
            [_ (displayln (usage) (current-error-port)) (exit 2)])]
         ["summary"
          (match positionals
            [(list id) (cmd-summary id)]
            [_ (displayln (usage) (current-error-port)) (exit 2)])]
         ["translate"
          (match positionals
            [(list id) (cmd-translate id)]
            [_ (displayln (usage) (current-error-port)) (exit 2)])]
         ["ai-config" (cmd-ai-config positionals)]
         ["update-check" (cmd-update-check)]
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
