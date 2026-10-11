#lang racket/base

;; Data locations. Resolution order: current-data-dir parameter (tests and
;; tools inject a temp dir), then $THREADLY_DATA_DIR (CLI, CI smoke), then
;; the per-user cache directory (~/Library/Caches/threadly on macOS,
;; $XDG_CACHE_HOME/threadly or ~/.cache/threadly on Linux,
;; %LOCALAPPDATA%-ish on Windows via find-system-path 'cache-dir).

(require racket/file
         racket/path)

(provide current-data-dir
         data-dir
         ensure-data-dir!)

(define current-data-dir (make-parameter #f))

(define (data-dir)
  (or (current-data-dir)
      (let ([from-env (getenv "THREADLY_DATA_DIR")])
        (if from-env
            (simple-form-path from-env)
            (build-path (find-system-path 'cache-dir) "threadly")))))

(define (ensure-data-dir!)
  (define dir (data-dir))
  (unless (directory-exists? dir)
    (make-directory* dir))
  dir)
