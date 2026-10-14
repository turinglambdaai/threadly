#lang racket/base

;; Threadly update support, built on rivet/distribution — the family
;; pattern (taskly/payback/brainfuel): the backend verifies and downloads
;; the signed update artifact; the native host owns installation. The feed
;; is the single GitHub release asset `update-manifest.json` (the family
;; signed-wrapper format, produced by scripts/make-update-manifest.sh
;; through rivet/distribution's own signer), so fetch-update-manifest +
;; select-update consume it directly — no hand-rolled wrapper parsing,
;; no shelled-out OpenSSL.
;;
;; The backend owns the artifact download: a check stashes the selected
;; candidate, start-download! streams it to <data-dir>/updates/ on a
;; background thread with progress published to a state box that hosts
;; poll through the `update-state` RPC (RVT1 events are thread-local, so a
;; background thread cannot emit them). Hosts own installation and the
;; silent 4-hour throttle (macOS keeps it in UserDefaults).
;;
;; The sticky rollout bucket lives in <data-dir>/updater-state.json behind
;; a one-key write whitelist — the threadly equivalent of taskly's
;; config.ini whitelist discipline.
;;
;; Note on crypto factories: rivet/distribution pins the provider set to
;; libcrypto at module load and deliberately avoids crypto/all — factory
;; FFIs load at import time and the gmp factory kills embedded runtimes
;; on hosts without libgmp. This module runs inside the embedded CS
;; runtime, so it must not require crypto/all either (tests may, they are
;; headless). Plain `crypto` here is only for crypto-random-bytes, the
;; rollout-bucket primitive; it loads no crypto factory.

(require crypto
         json
         net/base64
         rivet/distribution
         racket/file
         racket/path
         racket/string
         "core/paths.rkt"
         "version.rkt")

(provide update-check-result
         update-configured?
         current-update-public-key
         current-update-key-id
         current-update-application-id
         releases-api
         releases-page
         manifest-url
         current-update-base-url
         destination-path
         update-state-snapshot
         reset-update-state!
         set-update-error!
         current-candidate
         set-candidate!
         start-download!
         download-with-progress!
         platform-symbol
         architecture-symbol
         installer-extension
         rollout-bucket)

;; Ed25519 public key, base64 of the raw 32 bytes (scripts/update-keys.sh)
;; — the same bytes the macOS host embeds in UpdateService.swift. The
;; private half lives outside the repository (.keys/ backup + the CI
;; secret UPDATE_ED25519_PRIVATE_KEY) and never ships. Rotation: ship a
;; client trusting the next key before signing releases exclusively with
;; it.
(define current-update-public-key "xwjCTB1ixovxtwrHoG1JnG3amjb9HBBIWuUHGIvr5Fs=")
(define current-update-key-id "threadly-2026-10")
(define current-update-application-id "site.jrtx.threadly")

(define releases-api "https://api.github.com/repos/turinglambdaai/threadly/releases/latest")
(define releases-page "https://github.com/turinglambdaai/threadly/releases/latest")

;; The moving "latest" location; fetch-update-manifest follows the release
;; asset's 302 to the CDN internally (rivet#153). The parameter is a test
;; seam: tests point it at an unreachable local URL instead of touching
;; the network (checks run on backend serve threads in production, where
;; the default is always in force).
(define current-update-base-url (make-parameter #f))

(define (manifest-url)
  (define base (current-update-base-url))
  (if base
      (string-append (string-trim base "/" #:right? #t) "/update-manifest.json")
      "https://github.com/turinglambdaai/threadly/releases/latest/download/update-manifest.json"))

(define maximum-download-bytes (* 800 1024 1024))

;; Fixed SPKI prefix bytes for an Ed25519 public key (12 bytes) followed
;; by the raw 32-byte key = full SubjectPublicKeyInfo DER — the form
;; datum->pk-key accepts. rivet/distribution's bytes->ed25519-public-key
;; takes no raw form, and the raw constant is load-bearing (it is the
;; exact byte string the Swift host embeds).
(define ed25519-spki-prefix (bytes #x30 #x2a #x30 #x05 #x06 #x03 #x2b #x65 #x70 #x03 #x21 #x00))

(define (update-configured?)
  (define raw (base64-string->bytes current-update-public-key))
  (= 32 (bytes-length raw)))

(define (embedded-public-key)
  (datum->pk-key
   (bytes-append ed25519-spki-prefix (base64-string->bytes current-update-public-key))
   'SubjectPublicKeyInfo))

;; ---------- updater state (the one-key whitelist) --------------------------

;; Exactly this key may exist in updater-state.json. Values are integers
;; (0-99 for the bucket).
(define updater-state-keys '(rollout-bucket))

(define (updater-state-path)
  (build-path (data-dir) "updater-state.json"))

(define (read-updater-state)
  (define path (updater-state-path))
  (if (file-exists? path)
      (with-handlers ([exn:fail? (lambda (_) (hasheq))])
        (define doc (with-input-from-file path read-json))
        (if (hash? doc) doc (hasheq)))
      (hasheq)))

(define (write-updater-state! doc)
  ;; Whitelist on write: unknown keys are dropped, so a corrupt or
  ;; hand-edited file can never grow product data into the updater store.
  (define clean
    (for/fold ([acc (hasheq)])
              ([key (in-list updater-state-keys)])
      (define value (hash-ref doc key #f))
      (if (exact-integer? value)
          (hash-set acc key value)
          acc)))
  (define path (updater-state-path))
  (define dir (path-only path))
  (when dir (make-directory* dir))
  (with-output-to-file path
    #:exists 'truncate/replace
    (lambda () (write-json clean))))

;; Stable random 0..99 assigned on first check so staged rollouts are
;; sticky per installation. crypto-random-bytes, not `random`:
;; racket/base's PRNG has a fixed seed, which would put every fresh
;; install in the same lockstep bucket.
(define (rollout-bucket)
  (define existing (hash-ref (read-updater-state) 'rollout-bucket #f))
  (if (and existing (exact-integer? existing) (<= 0 existing 99))
      existing
      (let ([bucket
             (modulo (integer-bytes->integer (crypto-random-bytes 4) #t #t)
                     100)])
        (write-updater-state!
         (hash-set (read-updater-state) 'rollout-bucket bucket))
        bucket)))

;; ---------- shared update state (UI-visible) -------------------------------

;; phase: idle | checking | downloading | downloaded | error. The download
;; streams on a background thread; RVT1 events are thread-local, so progress
;; is published through this box and hosts poll it via `update-state`.
(define update-state
  (box (hasheq 'phase "idle"
               'percent 0
               'message #f
               'downloadedPath #f
               'availableVersion #f)))

;; Candidate chosen by the last successful check; start-download! consumes
;; it. Reset by every new check. Holds a rivet update-candidate struct.
(define candidate-box (box #f))
(define worker-thread-box (box #f))

;; Download watchdog bounds. rivet's copy loop waits on read-bytes-avail!
;; with no timeout, so a connection that stalls without RST/FIN parks the
;; worker thread forever — visibly "stuck at 100%" (all bytes had arrived;
;; the loop was still waiting for EOF). Two finite bounds keep the phase
;; machine honest: no byte progress for the stall limit, or wall clock past
;; the total limit, breaks the worker (rivet's partial-file cleanup runs,
;; and the worker reports phase=error itself) so the UI always gets a
;; terminal state.
(define download-stall-limit-seconds 120)
(define download-total-limit-seconds (* 30 60))
(define last-progress-seconds (box 0))

(define (state-set! key value)
  (set-box! update-state (hash-set (unbox update-state) key value)))

(define (update-state-snapshot)
  (unbox update-state))

(define (reset-update-state!)
  (set-box! candidate-box #f)
  (set-box! update-state
            (hasheq 'phase "idle"
                    'percent 0
                    'message #f
                    'downloadedPath #f
                    'availableVersion #f)))

;; Pre-spawn download failures (already running, no candidate) surface
;; through the state instead of an RPC error, so host UIs have a single
;; failure channel.
(define (set-update-error! message)
  (state-set! 'phase "error")
  (state-set! 'message message))

;; The candidate stashed by the last successful check: #f or a hasheq with
;; 'version / 'artifact / 'build / 'published-at. The RPC layer maps it onto
;; the UpdateCheck record's optional fields.
(define (current-candidate)
  (define c (unbox candidate-box))
  (and c
       (let ([manifest (update-candidate-manifest c)]
             [artifact (update-candidate-artifact c)])
         (hasheq 'version (update-manifest-version manifest)
                 'build (update-manifest-build manifest)
                 'published-at (update-manifest-published-at manifest)
                 'artifact (hasheq 'platform (update-artifact-platform artifact)
                                   'architecture (update-artifact-architecture artifact)
                                   'url (update-artifact-url artifact)
                                   'installer (update-artifact-installer artifact)
                                   'size (update-artifact-size artifact)
                                   'sha256 (update-artifact-sha256 artifact))))))

;; Test seam: install a candidate without a network check so the download
;; can be driven against a local HTTP server.
(define (set-candidate! candidate) (set-box! candidate-box candidate))

;; ---------- check ------------------------------------------------------------

;; → structured result the callers localize:
;;   '(up-to-date) | (list 'available version)
;;   (list 'unavailable reason) | (list 'failed reason)
;;
;; The macOS host runs the same contract natively (UpdateService.swift, a
;; thin adapter over rivet's RivetUpdate); this module gives the CLI, the
;; backend RPC and the Windows host the same check through
;; rivet/distribution. An "available" result also stashes the candidate
;; for start-download!, so the download never re-fetches or re-verifies
;; the manifest.
(define (update-check-result current-version)
  (cond
    [(not (update-configured?))
     (list 'unavailable "developer build (no update key configured)")]
    [else
     (with-handlers
         ([exn:fail?
           (lambda (e)
             (state-set! 'phase "error")
             (state-set! 'message (exn-message e))
             (list 'failed (exn-message e)))])
       (reset-update-state!)
       (state-set! 'phase "checking")
       (define manifest
         (fetch-update-manifest (manifest-url)
                                (embedded-public-key)
                                #:key-id current-update-key-id))
       ;; fetch-update-manifest follows GitHub release-asset redirections
       ;; internally; it accepts only #:key-id and #:maximum-bytes.
       (define config
         (updater-config current-update-application-id
                         current-version
                         'stable
                         (platform-symbol)
                         (architecture-symbol)
                         (embedded-public-key)
                         current-update-key-id
                         (rollout-bucket)
                         maximum-download-bytes))
       (define candidate (select-update config manifest))
       (cond
         [candidate
          (set-box! candidate-box candidate)
          (define latest
            (update-manifest-version (update-candidate-manifest candidate)))
          (state-set! 'phase "idle")
          (state-set! 'availableVersion latest)
          (list 'available latest)]
         [else
          (state-set! 'phase "idle")
          (state-set! 'availableVersion #f)
          (list 'up-to-date)]))]))

;; rivet release tooling emits these exact symbols into update manifests
;; (same mapping the rivet MSI tooling uses).
(define (platform-symbol)
  (case (system-type 'os)
    [(macosx) 'macos]
    [(windows) 'windows]
    [else 'linux]))

(define (architecture-symbol)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

;; ---------- download ----------------------------------------------------------

(define (installer-extension)
  (case (system-type 'os)
    [(macosx) ".zip"]
    [(windows) ".zip"]
    [else ".tar.gz"]))

(define (destination-path data-dir candidate)
  (define version
    (update-manifest-version (update-candidate-manifest candidate)))
  (build-path data-dir
              "updates"
              (string-append "Threadly-" version (installer-extension))))

;; rivet's download-update owns the whole artifact path — redirect-following
;; fetch (the rivet#153 302 shape), signed-size cap, .partial cleanup on
;; any failure, SHA-256 + size verification against the signed manifest,
;; atomic rename — so the wrapper only maps its byte progress onto the
;; integer percent the UI polls, and feeds the watchdog's stall clock on
;; every report.
(define (download-with-progress! config candidate destination)
  (define total (update-artifact-size (update-candidate-artifact candidate)))
  (download-update
   config candidate destination
   #:on-progress
   (lambda (done)
     (set-box! last-progress-seconds (current-seconds))
     (state-set! 'percent
                 (if (> total 0)
                     (min 100 (quotient (* done 100) total))
                     0)))))

;; Spawns the worker thread and returns immediately; the host follows
;; progress via the update-state RPC. Raises before spawning when there is
;; nothing to download (the RPC maps that onto the state's error phase);
;; never raises from the thread itself.
(define (start-download! data-dir)
  (define worker (unbox worker-thread-box))
  (when (and worker (thread-running? worker))
    (error 'start-download! "an update download is already running"))
  (define candidate (unbox candidate-box))
  (unless candidate
    (error 'start-download! "no update is available; run a check first"))
  (state-set! 'phase "downloading")
  (state-set! 'percent 0)
  (state-set! 'message #f)
  (define config
    (updater-config current-update-application-id
                    app-version
                    'stable
                    (platform-symbol)
                    (architecture-symbol)
                    (embedded-public-key)
                    current-update-key-id
                    (rollout-bucket)
                    maximum-download-bytes))
  (define destination (destination-path data-dir candidate))
  (set-box! last-progress-seconds (current-seconds))
  (define worker-thread
    (thread
     (lambda ()
       ;; The watchdog breaks a stalled worker; exn:break is not an
       ;; exn:fail, so it needs its own arm — either way rivet's partial
       ;; cleanup removes the .partial and the phase lands on error
       ;; (never mid-flight).
       (with-handlers
           ([(lambda (e) (or (exn:fail? e) (exn:break? e)))
             (lambda (e)
               (state-set! 'phase "error")
               (state-set! 'message
                           (if (exn:break? e)
                               "update download stalled or timed out"
                               (exn-message e))))])
         (define path (download-with-progress! config candidate destination))
         (state-set! 'phase "downloaded")
         (state-set! 'percent 100)
         (state-set! 'downloadedPath (path->string path))))))
  (set-box! worker-thread-box worker-thread)
  ;; Watchdog: exits once the worker finishes on its own; otherwise a stall
  ;; (no byte progress) or the total wall-clock limit breaks the worker so
  ;; phase never rests on "downloading" indefinitely.
  (define download-started (current-seconds))
  (thread
   (lambda ()
     (let loop ()
       (cond
         [(sync/timeout download-stall-limit-seconds
                        (thread-dead-evt worker-thread))
          (void)]
         [(> (- (current-seconds) (unbox last-progress-seconds))
             download-stall-limit-seconds)
          (break-thread worker-thread)]
         [(> (- (current-seconds) download-started)
             download-total-limit-seconds)
          (break-thread worker-thread)]
         [else (loop)]))))
  (void))
