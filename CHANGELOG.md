# Changelog

All notable changes to Threadly are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## Unreleased

## 0.10.0 - 2026-10-13

M3 — reading value-add: AI thread summaries and translation on every
platform, plus the forum's like state on every post. This closes the
M2/M3 milestones; M4 (mobile) stays gated on Rivet's mobile platforms.

### Added
- AI summaries and translation over any OpenAI-compatible
  chat-completions endpoint. Configure once:
  `threadly ai-config --base-url … --api-key … --model … --target-lang …`
  (the key is stored 0600 and used only against that endpoint). Every
  desktop app then grows Summarize / Translate buttons for the open
  thread — a live-updating panel on macOS, Windows, and Linux — and the
  CLI gains `summary <id>` and `translate <id>`.
- Like state on every post: the reader now shows the forum's own like
  counts up front and renders posts you have already liked as filled
  hearts. Clicking an already-liked post does nothing; a fresh like
  bumps the count in place. (Before this, like buttons started blank on
  every open and showed no counts.)

## 0.9.0 - 2026-10-13

M2 wrap-up — the write path reaches every platform: likes everywhere,
replies on Windows and Linux, notifications read on view.

### Added
- Likes: signed in, every post in the reader grows a like button. The
  button rides a script-message bridge (WKWebView on macOS, WebView2 on
  Windows, WebKitGTK on Linux); the server's answer moves the button, so
  what you see always matches the forum.
- Windows and Linux get the account flow macOS has had since 0.6.0:
  one-click sign-in with the paste-the-code sheet, the identity in the
  toolbar tooltip, confirm-before-sign-out. Before this, Windows and
  Linux had no way to sign in at all.
- The reply composer reaches Windows (a ContentDialog) and Linux (a
  modal composer window); posting reloads the thread so the new post
  appears in place.
- Notifications mark as read when the Notifications view loads, matching
  the forum's own behavior.

### Changed
- Auth URLs open only from the backend's open-url event — auth-begin
  both fires the event and returns the URL, so hosts that opened from
  both channels would open the browser twice.
- Thread rows carry the post id as a sixth column; the like buttons
  target it.

## 0.8.0 - 2026-10-13

M2 third slice — write: Threadly can now speak, not just read.

### Added
- Replying: the macOS reader grows a Reply button. Signed in, it opens a
  raw-Markdown composer (Discourse posts are markdown); posting reloads
  the thread so the new post appears in place. Signed out, the composer
  points at the sign-in flow with a one-click start.
- `reply <topic-id>` on the CLI: pipe raw markdown on stdin
  (`echo "hi" | threadly reply 4416`) and post with the app's stored
  sign-in state.
- The engine's HTTP client speaks writes: urlencoded form POST with
  redirect chasing, DELETE, and per-request extra headers — the plumbing
  the forum write API needs.
- New tests cover form encoding (unicode + newlines survive), the POST
  wire shape against a loopback server (request line, api-key header,
  urlencoded body), and the sign-in scope.

### Changed
- Sign-in now requests the `read|write|notifications` scope. Keys issued
  by 0.6.x/0.7.0 are read-only: to reply, sign out and sign in again
  once after updating.
- The backend's post-create RPC returns one `(post-id post-number)` row,
  matching the row-listing shape every other endpoint uses.

## 0.7.0 - 2026-10-13

M2 second slice — notifications on every platform.

### Added
- Signed-in users get a Notifications view: the forum's unread mentions,
  replies, likes, quotes, and messages, with per-type symbols and an
  unread dot. Clicking a row opens the linked thread.
- macOS: a Notifications row appears in Browse once signed in; Windows
  picks notifications from the picker ComboBox; Linux from the GtkDropDown.
- Backend RPC notifications-list plus fixtures and tests for the
  notification parser (type labels, read flags, linked topics).

## 0.6.0 - 2026-10-12

M2 first slice — signed-in mode (read): Threadly can now act as you.

### Added
- Sign in with the forum via the Discourse user API key flow: the app
  generates an RSA-2048 handshake keypair, opens the forum approval page,
  and the user pastes back the encrypted code. The engine decrypts it with
  OpenSSL 3, verifies the echoed nonce, and stores the user API key 0600
  in the data directory; the handshake private key is deleted once the
  key is stored.
- Every read then carries User-Api-Key, so the forum shows what this user
  can see (private categories included). Backend RPCs: auth-begin,
  auth-complete, auth-status, auth-sign-out.
- macOS host: Account section in the sidebar — sign in with one click,
  paste-the-code sheet, signed-in identity, sign out.
- Tests cover keypair generation, decrypt + nonce-verify, nonce-mismatch
  rejection, and sign-out hygiene (skipped gracefully without OpenSSL 3).

## 0.5.3 - 2026-10-12

Pins the sidebar search field above the scrolling topic list — it used to
scroll away with the list, leaving no way to search. Same pattern as the
Windows and Linux hosts, plus an inline clear button.

## 0.5.2 - 2026-10-12

Graceful empty states: Uncategorized on the forum genuinely has zero
topics, and the old full-sidebar overlay swallowed the whole Browse list
behind a giant No topics view. Empty categories now show a subdued inline
note in the Topics section (Uncategorized explains the forum keeps it
empty) and the detail pane nudges toward other categories or search.

## 0.5.1 - 2026-10-12

Fixes the macOS update download leg: the byte-by-byte bytes(from:) stream
stalled against the GitHub CDN on some networks (it would sit at 4 MiB
forever). The artifact now downloads through a URLSession download task —
system-managed and disk backed — and the archive is still held to the
signed SHA-256 before anything is trusted.

## 0.5.0 - 2026-10-12

Category navigation reaches every desktop.

### Added
- Windows and Linux hosts join the Discourse information architecture: a
  category picker (ComboBox / GtkDropDown) above the topic list serves
  per-category topic pages, with Back and Refresh respecting the current
  scope, matching the macOS sidebar.

## 0.4.1 - 2026-10-12

Fixes the macOS self-update install: the eager temp-directory cleanup ran
while the background swap script was still moving the unpacked bundle
into place, so every install silently rolled back to the old version.
The swap script now cleans up its own work directory after the new bundle
is in place.

## 0.4.0 - 2026-10-12

The forum's own navigation: categories are now first-class.

### Added
- Category browsing in the Discourse information architecture — a Browse
  section (Latest plus every category in the forum's own order and colors)
  above the topic list, and per-category topic pages served by
  /c/<slug>/<id>.json. CLI gains `category <slug> <id>`.
- CLI positional-argument parsing fix (multi-argument commands received
  their arguments reversed).

### Fixed
- A latent wire-contract bug: read-json maps JSON null to the 'null
  symbol, which leaked into RPC rows and failed the List(List(String))
  contract on category pages containing reply-less pinned topics.

## 0.3.0 - 2026-10-12

The hosts learn to update themselves — the release feed published since
0.1.0 is now consumed in-app on every platform.

### Added
- In-app self-update on macOS and Windows: a throttled silent check at
  launch plus a manual "Check for Updates" action, the signed wrapper
  verified end-to-end (schema, key id, Ed25519 over the exact payload
  bytes — CryptoKit on macOS, OpenSSL 3 in the engine), download with
  size + SHA-256 held to the signed manifest, and explicit install
  consent. macOS swaps the bundle atomically with rollback; portable-zip
  Windows installs swap in place via a detached handoff script, MSI
  installs take the manual releases path.
- CLI `update-check` command running the same verification chain.
- Update tests driving the real captured feed through parsing and live
  signature verification.

## 0.2.0 - 2026-10-12

Windows and Linux join the family: every desktop platform ships native
installers from this release.

### Added
- Windows host (WinUI 3) and Linux host (GTK4 + WebKitGTK): sidebar topic
  browser with search, thread reader rendering the forum's cooked HTML in
  a 680px reading column (light and dark), notify-event status surface,
  and generation guards against superseded loads. The Windows reader runs
  in WebView2 created in code so a missing runtime degrades to a status
  message instead of crashing the shell.
- Windows installer: MSI plus portable zip. Linux installers: deb, rpm,
  AppImage, tar.gz and portable zip on x64 and arm64 — each with SHA256
  sidecars, and one signed `update-manifest.json` covering macOS, Windows
  and Linux update payloads.

## 0.1.0 - 2026-10-12

First release — born in the family's 0.x era.

### Added
- Discourse engine: latest topics, topic threads, archive search, and
  categories over the anonymous public JSON API, with manual redirect
  following and a TTL disk cache (stale cache still answers when the forum
  is unreachable).
- CLI: `version`, `latest`, `topic`, `search`, `categories`, `doctor`, and
  a global `--json` flag; `doctor` and `version` never touch the network.
- macOS SwiftUI shell (Rivet host): sidebar topic browser with the forum's
  category colors, SF Symbol counts, a thread reader with post avatars and
  a 680px reading column, archive search, and the notify-event status bar.
- App icon (family terracotta palette, thread staircase mark) for the
  macOS bundle; `THREADLY_APPEARANCE=dark|light` pins the appearance for
  dual-theme verification.
- CI: engine tests on ubuntu/macos/windows plus a macOS host package gate.
- Release pipeline: macOS DMG (arm64/x64) + update zips with SHA256
  sidecars, SHA256SUMS, and the signed `update-manifest.json` feed.
- Windows/Linux native hosts, signed-in mode, and reading value-add are
  on the roadmap (M1–M3); mobile hosts follow on M4.
