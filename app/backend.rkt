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
         "ai.rkt"
         "schema.rkt"
         "version.rkt"
         (prefix-in upd: "update.rkt")
         (prefix-in authn: "auth.rkt")
         (prefix-in d: "core/discourse.rkt"))

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

;; A category's topics; same row shape as latest-list so hosts render one
;; list model for both scopes.
(define-rpc (category-topics-list [slug String] [id String] : (List (List String)))
  (rows-or-notify
   (lambda ()
     (for/list ([t (in-list (fetch-category-topics slug (string->number id)))])
       (list (~a (topic-summary-id t))
             (topic-summary-title t)
             (~a (topic-summary-category-id t))
             (~a (topic-summary-posts-count t))
             (~a (topic-summary-reply-count t))
             (~a (topic-summary-views t))
             (~a (topic-summary-like-count t))
             (or (topic-summary-last-posted-at t) ""))))))

;; The reader's post rows: 8 display columns plus the thread's total
;; post count, which tells the reader whether the thread continues past
;; this chunk (the "load all" bar renders from it).
(define (post-rows posts total)
  (for/list ([p (in-list posts)])
    (list (forum-post-username p)
          (avatar-url (forum-post-avatar-template p))
          (forum-post-cooked p)
          (or (forum-post-created-at p) "")
          (~a (forum-post-post-number p))
          ;; post id — the like button targets it via the webview bridge
          (~a (forum-post-id p))
          (~a (forum-post-like-count p))
          (if (forum-post-liked? p) "1" "0")
          (~a total))))

(define-rpc (topic-open [id String] : (List (List String)))
  (rows-or-notify
   (lambda ()
     (define-values (topic posts)
       (fetch-topic (string->number id)))
     (post-rows posts (topic-summary-posts-count topic)))))

;; Every post of a thread, for the reader's "load all" bar.
(define-rpc (topic-posts-all [id String] : (List (List String)))
  (rows-or-notify
   (lambda ()
     (define-values (topic posts)
       (fetch-topic-all (string->number id)))
     (post-rows posts (topic-summary-posts-count topic)))))

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
;; Family pattern (the full contract is app/update.rkt's module header): this
;; backend verifies and downloads the signed artifact; hosts own installation
;; and the silent 4-hour throttle. update-check returns a typed UpdateCheck
;; record so hosts never parse localized strings; start-download runs the
;; transfer on a backend worker thread and hosts poll update-state.

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
       ;; Also emitted as the update-available event. The macOS store
       ;; subscribes (a status line alongside its native UpdateService);
       ;; the Windows and Linux hosts have no event consumer and follow
       ;; this RPC's answer plus update-state polling instead. Kept on the
       ;; wire for the hosts that do subscribe — removal would be a
       ;; backend contract change for no consumer gain.
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

;; ---- signed-in mode (M2) -------------------------------------------------
;; Discourse user API key flow: auth-begin returns the forum authorization
;; URL (hosts open it in the browser); after the user approves, the forum
;; shows an encrypted blob that the user pastes into auth-complete. The
;; engine decrypts it with the handshake key, verifies the nonce, and
;; stores the user API key; every read then carries User-Api-Key, so the
;; forum shows what this user can see.

(define-rpc (auth-begin : String)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (notify (exn-message e))
          (void))])
    (define url (authn:auth-begin))
    (open-url url)
    url))

(define-rpc (auth-complete [code String] : String)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (notify (exn-message e))
          (void))])
    (authn:auth-complete code)
    (define-values (username _avatar) (fetch-current-user))
    (with-output-to-file (authn:auth-username-path)
      (lambda () (display username))
      #:exists 'replace)
    username))

(define-rpc (auth-status : AuthStatus)
  (AuthStatus (if (authn:auth-signed-in?) "in" "out")
              (or (authn:auth-username) "")))

(define-rpc (auth-sign-out : Void)
  (authn:auth-sign-out)
  (void))

;; Signed-in notifications. Rows:
;;   (id type-label read-flag created topic-id title username)
;; Clicking a row opens topic-id. Unsigned-in → empty rows + notify.
;; Reply to a topic. → one row (post-id post-number); a fixed 2-tuple
;; isn't a supported Rivet wire type, so it travels like every other
;; row-listing endpoint. The second parameter is `body`, not `raw` —
;; codegen names its call-result local after nothing in particular but
;; collides with argument names (rivet codegen issue, filed upstream).
(define-rpc (post-create [topic-id String] [body String] : (List (List String)))
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (notify (exn-message e))
          (list (list "" "")))])
    (define created (create-post (string->number topic-id) body))
    (list (list (~a (d:created-post-id created))
                (~a (d:created-post-post-number created))))))

;; Like a post (needs read|write scope).
(define-rpc (like-post [post-id String] : Bool)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (notify (exn-message e))
          #f)])
    (like-post (string->number post-id) #t)))

;; Un-like a post (needs read|write scope) — the engine's was_deleted
;; direction, wired to a second click on a liked post. Returns #t on
;; success so hosts can tell it apart from the failure #f.
(define-rpc (unlike-post [post-id String] : Bool)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (notify (exn-message e))
          #f)])
    (like-post (string->number post-id) #f)
    #t))

;; Marks all notifications read — hosts call it after listing the
;; Notifications scope (the forum's own mark-on-view behavior).
(define-rpc (notifications-mark-read : Void)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (notify (exn-message e))
          (void))])
    (mark-notifications-read)))

;; ---- M3 reading value-add (summaries, translation) ----------------------------

;; Whether an OpenAI-compatible endpoint is configured. Hosts use it to
;; gate tooltips; the AI RPCs work regardless and raise useful errors.
(define-rpc (ai-status : Bool)
  (ai-configured?))

;; Both AI RPCs are long calls (tens of seconds): the engine thread
;; blocks on the LLM while the backend keeps serving everything else.
;; Failures surface as a notify + empty string.
(define-rpc (ai-summarize [topic-id String] : String)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (notify (exn-message e))
          "")])
    (ai-summarize-topic (string->number topic-id))))

(define-rpc (ai-translate [topic-id String] : String)
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (notify (exn-message e))
          "")])
    (ai-translate-topic (string->number topic-id))))

(define-rpc (notifications-list : (List (List String)))
  (rows-or-notify
   (lambda ()
     (for/list ([n (in-list (fetch-notifications))])
       (list (~a (forum-notification-id n))
             (forum-notification-type-label n)
             (if (forum-notification-read? n) "1" "0")
             (or (forum-notification-created-at n) "")
             (~a (forum-notification-topic-id n))
             (forum-notification-title n)
             (forum-notification-username n))))))

;; ---- lifecycle ---------------------------------------------------------------

(define (start in-fd out-fd)
  (ensure-data-dir!)
  (state-set! version app-version)
  (serve-fds in-fd out-fd))
