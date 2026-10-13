#lang racket/base

;; M2 first slice — Discourse user API key sign-in (read scope), family
;; pattern: the app generates an RSA keypair, opens the forum's
;; /user-api-key/new authorization page, and the user approves. The forum
;; hands back an RSA-encrypted payload (a base64 blob to paste into the
;; hands back an RSA-encrypted payload (a base64 blob to paste into the
;; app) containing {"key": "<user api key>", "nonce": "<echoed>"}; the app
;; decrypts it with its private key, verifies the nonce, and stores the
;; user API key (0600). All signed requests then carry
;; User-Api-Key: <key>.
;;
;; Crypto goes through OpenSSL 3 by shelling out — the same family pattern
;; as update.rkt's signature verification — so the engine keeps zero
;; package dependencies beyond base. The private key exists only for the
;; handshake and is deleted as soon as the key is stored; the API key file
;; is written with 0600 and never logged.

(require json
         net/base64
         net/uri-codec
         racket/file
         racket/format
         racket/path
         racket/port
         racket/string
         racket/system
         "core/http.rkt"
         "core/paths.rkt")

(provide auth-configured?
         auth-signed-in?
         auth-api-key
         auth-begin
         auth-complete
         auth-sign-out
         (rename-out [username-path auth-username-path]
                     [private-key-path private-key-path])
         auth-username
         auth-username
         auth-nonce-for-tests
         find-openssl
         openssl3?)

;; ---- locations ---------------------------------------------------------------

(define (auth-dir)
  (build-path (data-dir) "auth"))

(define (private-key-path)
  (build-path (auth-dir) "user-api-key.pem"))

(define (nonce-path)
  (build-path (auth-dir) "nonce"))

(define (api-key-path)
  (build-path (auth-dir) "user-api-key"))

(define (username-path)
  (build-path (auth-dir) "username"))

(define forum-base "https://racket.discourse.group")

;; ---- openssl plumbing ---------------------------------------------------------

(define (find-openssl)
  (define candidates
    (list (getenv "OPENSSL_BIN")
          "/opt/homebrew/opt/openssl@3/bin/openssl"
          "/usr/local/opt/openssl@3/bin/openssl"))
  (or (for/or ([c (in-list candidates)] #:when (and c (file-exists? c))) c)
      (find-executable-path "openssl")))

(define (openssl3? path)
  (and path
       (string-contains?
        (with-output-to-string
          (lambda ()
            (with-handlers ([exn:fail? void])
              (system* path "version"))))
        "OpenSSL 3")))

(define (require-openssl)
  (define openssl (find-openssl))
  (unless (openssl3? openssl)
    (error 'auth "OpenSSL 3 not found for sign-in"))
  openssl)

(define (run/lines openssl args)
  (with-output-to-string
    (lambda ()
      (with-handlers ([exn:fail? void])
        (apply system* openssl args)))))

;; ---- state ---------------------------------------------------------------------

(define (auth-configured?)
  ;; a keypair + pending nonce exist and we are waiting for the user code
  (and (file-exists? (private-key-path))
       (file-exists? (nonce-path))))

(define (auth-signed-in?)
  (define p (api-key-path))
  (and (file-exists? p)
       (> (file-size p) 0)))

;; → the stored user API key or #f. Never logs the key.
(define (auth-api-key)
  (define p (api-key-path))
  (and (file-exists? p)
       (let ([key (string-trim (file->string p))])
         (and (non-empty-string? key) key))))

(define (auth-username)
  (define p (username-path))
  (and (file-exists? p)
       (let ([u (string-trim (file->string p))])
         (and (non-empty-string? u) u))))

;; ---- begin ---------------------------------------------------------------------

;; Generates the keypair + nonce, returns the authorization URL the host
;; opens in the user's browser.
(define (auth-begin)
  (define openssl (require-openssl))
  (define dir (auth-dir))
  (make-directory* dir)
  (define key-pem (private-key-path))
  (define pub-pem (path-replace-extension key-pem #".pub.pem"))
  (define nonce
    (string-trim (run/lines openssl (list "rand" "-hex" "16"))))
  (unless (non-empty-string? nonce)
    (error 'auth-begin "cannot generate nonce"))
  (unless (zero? (system*/exit-code openssl
                                    "genpkey" "-algorithm" "RSA"
                                    "-pkeyopt" "rsa_keygen_bits:2048"
                                    "-out" (path->string key-pem)))
    (error 'auth-begin "key generation failed"))
  (file-or-directory-permissions key-pem 384)
  (unless (zero? (system*/exit-code openssl
                                    "pkey" "-in" (path->string key-pem)
                                    "-pubout"
                                    "-out" (path->string pub-pem)))
    (error 'auth-begin "public key export failed"))
  (with-output-to-file (nonce-path)
    (lambda () (display nonce))
    #:exists 'replace)
  (file-or-directory-permissions (nonce-path) 384)
  (define pub-pem-text (string-trim (file->string pub-pem)))
  (delete-file pub-pem)
  (format "~a/user-api-key/new?application_name=~a&client_id=~a&scopes=~a&nonce=~a&public_key=~a"
          forum-base
          (uri-encode "Threadly")
          (uri-encode (substring (string-downcase nonce) 0 32))
          (uri-encode "read")
          (uri-encode nonce)
          (uri-encode pub-pem-text)))

;; ---- complete --------------------------------------------------------------------

;; PKCS#1 v1.5 decrypt of the pasted base64 payload with the handshake
;; private key. Pure-ish (no network); raises on failure.
(define (decrypt-payload code)
  (define openssl (require-openssl))
  (define ct (or (base64-decode (string->bytes/latin-1 (string-trim code)))
                 (error 'auth-complete "code is not valid base64")))
  (define tmp (make-temporary-file "threadly-auth~a"))
  (define ct-file (path-replace-extension tmp #".ct"))
  (define pt-file (path-replace-extension tmp #".pt"))
  (dynamic-wind
    (lambda () (void))
    (lambda ()
      (display-to-file ct ct-file #:exists 'replace #:mode 'binary)
      (unless (zero? (system*/exit-code openssl
                                        "pkeyutl" "-decrypt"
                                        "-inkey" (path->string (private-key-path))
                                        "-in" (path->string ct-file)
                                        "-out" (path->string pt-file)))
        (error 'auth-complete "decryption failed (wrong key or bad code)"))
      (define pt (file->bytes pt-file))
      (eprintf "auth-diag: priv=~s pt-bytes=~v\n"
               (path->string (private-key-path)) pt)
      (with-handlers ([exn:fail? (λ (e) (error 'auth-complete "decrypted payload is not JSON (~v); bytes: ~v" (exn-message e) pt))])
        (bytes->jsexpr pt)))
    (lambda ()
      (with-handlers ([exn:fail? void])
        (delete-file ct-file)
        (delete-file pt-file)))))

;; Paste-code completion: decrypt, verify the echoed nonce, store the user
;; API key (0600), discard the handshake private key.
(define (auth-complete code)
  (unless (auth-configured?)
    (error 'auth-complete "no sign-in in progress; run auth-begin first"))
  (define doc (decrypt-payload code))
  (unless (hash? doc)
    (error 'auth-complete "decrypted payload is not a JSON object"))
  (define key (hash-ref doc 'key #f))
  (define nonce (hash-ref doc 'nonce #f))
  (unless (and (string? key) (non-empty-string? key))
    (error 'auth-complete "payload carries no API key"))
  (define expected (string-trim (file->string (nonce-path))))
  (unless (and (string? nonce) (string=? nonce expected))
    (error 'auth-complete "nonce mismatch"))
  (with-output-to-file (api-key-path)
    (lambda () (display key))
    #:exists 'replace)
  (file-or-directory-permissions (api-key-path) 384)
  ;; the handshake private key has done its job; the API key is the credential
  (with-handlers ([exn:fail? void]) (delete-file (private-key-path)))
  (with-handlers ([exn:fail? void]) (delete-file (nonce-path)))
  key)

(define (auth-nonce-for-tests)
  (and (file-exists? (nonce-path))
       (string-trim (file->string (nonce-path)))))

;; ---- sign out ---------------------------------------------------------------------

(define (auth-sign-out)
  (define (drop p) (with-handlers ([exn:fail? void]) (when (file-exists? p) (delete-file p))))
  (drop (api-key-path))
  (drop (username-path))
  (drop (nonce-path))
  (drop (private-key-path))
  (void))
