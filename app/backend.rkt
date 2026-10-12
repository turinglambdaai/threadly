#lang racket/base

;; Threadly backend — the single RVT1 surface shared by the native hosts.
;; Everything declared here is the wire contract: changing an RPC name, an
;; Event, a State, or a row layout is a cross-platform release, not a local
;; edit.
;;
;; Rows are positional strings (Fulcrum style).
;;
;;   latest row     = (id title category-id posts-count reply-count
;;                     views like-count last-posted-at)
;;   topic-post row = (author avatar-url cooked-html created-at post-number)
;;   search row     = (id title created-at posts-count)
;;   category row   = (id name slug color)
;;
;; Errors never crash an RPC: the handler emits `notify` with the message
;; and returns empty rows; the host decides how to surface it.
;;
;; Lifecycle: the embedded runtime calls `start` with the two RVT1 fds.

(require json
         racket/format
         racket/list
         racket/match
         racket/string
         rivet/backend
         "core/cache.rkt"
         "core/discourse.rkt"
         "core/paths.rkt"
         "schema.rkt"
         "version.rkt"
         (prefix-in upd: "update.rkt"))

(provide start
         app-version
         avatar-url)

;; ---- States / Events -------------------------------------------------------

(define-state version : String app-version)

(define-event notify : String)
(define-event update-available : String)
(define-event open-url : String)

;; ---- RPCs ------------------------------------------------------------------

(define (rows-or-notify fetch)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (notify (exn-message e))
                     '())])
    (fetch)))

;; Discourse avatar templates look like "/user_avatar/<host>/<user>/{size}/…"
;; or are already absolute CDN URLs; hosts want a ready-to-fetch URL.
(define (avatar-url template)
  (define s (string-replace template "{size}" "90"))
  (if (string-prefix? s "http")
      s
      (string-append (current-forum-base-url) s)))

(define-rpc (health : String)
  (format "Threadly ~a" app-version))

(define-rpc (latest-list [page Int64] [fresh Bool] : (List (List String)))
  (rows-or-notify
   (lambda ()
     (parameterize ([current-cache-ttl-seconds (if fresh 0 300)])
       (for/list ([t (in-list (fetch-latest page))])
         (list (~a (topic-summary-id t))
               (topic-summary-title t)
               (~a (topic-summary-category-id t))
               (~a (topic-summary-posts-count t))
               (~a (topic-summary-reply-count t))
               (~a (topic-summary-views t))
               (~a (topic-summary-like-count t))
               (or (topic-summary-last-posted-at t) "")))))))

(define-rpc (topic-open [id String] : (List (List String)))
  (rows-or-notify
   (lambda ()
     (define-values (_topic posts)
       (fetch-topic (string->number id)))
     (for/list ([p (in-list posts)])
       (list (forum-post-username p)
             (avatar-url (forum-post-avatar-template p))
             (forum-post-cooked p)
             (or (forum-post-created-at p) "")
             (~a (forum-post-post-number p)))))))

(define-rpc (search-list [q String] : (List (List String)))
  (rows-or-notify
   (lambda ()
     (for/list ([r (in-list (fetch-search q))])
       (list (~a (search-result-id r))
             (search-result-title r)
             (or (search-result-created-at r) "")
             (~a (search-result-posts-count r)))))))

(define-rpc (categories-list : (List (List String)))
  (rows-or-notify
   (lambda ()
     (for/list ([c (in-list (fetch-categories))])
       (list (~a (forum-category-id c))
             (forum-category-name c)
             (forum-category-slug c)
             (forum-category-color c))))))

;; ---- updates ---------------------------------------------------------------------------
;; Family pattern (docs/UPDATE.md): this backend verifies and downloads the
;; signed artifact; hosts own installation and the silent 4-hour throttle.
;; update-check returns a typed UpdateCheck record so hosts never parse
;; localized strings; start-download runs the transfer on a backend worker
;; thread and hosts poll update-state.

(define-rpc (update-check : UpdateCheck)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (UpdateCheck "error" (nullable (exn-message e)) app-version
                       (void) (void) (void) (void) (void)))])
    (define result (upd:update-check-result app-version))
    (match result
      [(list 'available version)
       (define candidate (upd:current-candidate))
       (define artifact (and candidate (hash-ref candidate 'artifact #f)))
       (update-available version)
       (UpdateCheck
        "available" (void) app-version (nullable version)
        (nullable (and candidate (hash-ref candidate 'build #f)))
        (nullable (and candidate (hash-ref candidate 'published-at #f)))
        (nullable (and artifact (format "~a" (hash-ref artifact 'installer "zip"))))
        (nullable (and artifact (hash-ref artifact 'size #f))))]
      [(list 'up-to-date)
       (UpdateCheck "up-to-date" (void) app-version
                    (void) (void) (void) (void) (void))]
      [(list 'unavailable reason)
       (UpdateCheck "error" (nullable reason) app-version
                    (void) (void) (void) (void) (void))]
      [(list 'failed reason)
       (UpdateCheck "error" (nullable reason) app-version
                    (void) (void) (void) (void) (void))]
      [_ (UpdateCheck "error" (nullable "unknown") app-version
                      (void) (void) (void) (void) (void))])))

;; Runs on a backend worker thread; the host follows progress via
;; update-state. Never raises: failures surface through the state's phase.
(define-rpc (start-download : Void)
  (with-handlers
      ([exn:fail? (lambda (e) (upd:set-update-error! (exn-message e)))])
    (upd:start-download! (data-dir)))
  (void))

(define-rpc (update-state : UpdateState)
  (define s (upd:update-state-snapshot))
  (UpdateState
   (hash-ref s 'phase "idle")
   (hash-ref s 'percent 0)
   (nullable (hash-ref s 'message #f))
   (nullable (hash-ref s 'downloadedPath #f))
   (nullable (hash-ref s 'availableVersion #f))))

(define-rpc (open-releases : Void)
  (open-url upd:releases-page)
  (void))

;; ---- lifecycle ---------------------------------------------------------------

(define (start in-fd out-fd)
  (ensure-data-dir!)
  (state-set! version app-version)
  (serve-fds in-fd out-fd))
