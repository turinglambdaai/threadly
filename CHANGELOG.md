# Changelog

All notable changes to Threadly are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## 0.14.0 - 2026-10-30

The first release verified on real hardware of all three desktop
platforms: packaged products installed and exercised on Windows, Linux
and macOS virtual machines, reading live forum data end to end.

### Added
- The reader now binds every thread load to the selected topic's
  identity (issue #2): switching threads while one is still loading
  drops the late completion, so topic A can no longer overwrite topic
  B's posts, counts or reply target — and a late failure for A can no
  longer clear B. Signing out or going back to the list drops in-flight
  opens the same way.
- Failed thread opens recover in place on every desktop host (issue
  #2): the reader shows the failure with Retry and Back-to-list
  actions; retry re-opens the same thread without restarting, and the
  sidebar selection and list position stay untouched.
- Reply drafts survive per thread: a failed open, a dismissed composer
  or a switch to another topic keeps what was typed, on all three
  hosts; the draft is dropped only once the reply actually posts.
- Store-level delayed-response fixtures for the macOS host
  (`macos-host/Tests`): a scripted RivetAPI transport replays the
  issue #2 interleavings (slow A / fast B, late-A error, offline retry,
  close/sign-out invalidation, drafts, load-all identity) without a
  network or backend. Run via `swift test`; CI runs them after the
  build.

### Changed
- "Check for Updates…" moved next to "About" on every platform per the
  family menu convention: it now lives in the App menu directly below
  About on macOS, and in a Help menu (Ctrl+U accelerator) on Windows and
  Linux — replacing the always-visible header icon buttons, which were
  retired as low-frequency actions.

### Fixed
- Windows: topic rows ignored clicks and the reader pane stayed
  permanently white (issue #5). Two independent causes: the topic list,
  disabled in the XAML until the shell is ready, was never re-enabled
  once rows landed (search and the category picker re-enabled
  themselves in their own completion paths, the list did not); and the
  code-created reader WebView2 never got a layout slot — WinUI 3 no
  longer defaults ContentControl content alignment to Stretch and a
  WebView2 measures 0×0 before rendering, so pages loaded into a
  zero-sized surface. Both fixed; acceptance VM confirms rows open
  threads and the reader renders like macOS and Linux.
- Windows (MSI install): the app crashed at startup with an access
  violation. WebView2's default user-data folder sits beside the
  executable — under Program Files that location is unwritable for a
  filtered (UAC) admin token, which is what every real user's desktop
  session runs under. The reader now creates its WebView2 environment
  explicitly with the folder at `%LOCALAPPDATA%\threadly\WebView2`
  instead of the exe-adjacent default; the acceptance VM confirms the
  installed app starts, lists topics, and reads threads.
- Releases now publish as drafts: the real artifacts must pass an
  install-and-read acceptance pass on all three desktop platforms
  before the release is promoted to public.

### Security
- Sign-in completion no longer prints the decrypted authorization
  payload (which carries the user API key) to stderr, and a failed
  parse no longer embeds that payload in the error message the hosts
  surface in their status line (issue #1: secrets never reach feedback).

## 0.13.0 - 2026-10-16

Three threads converge here: likes become toggleable, the installers
grow up, and long threads finally read to the end.

### Added
- Long threads read in full: a thread longer than the forum's first
  page now shows a "Showing 20 of 87 posts · Load all" bar at the top
  of the reader; loading appends the remaining posts in place, so the
  scroll position survives. The engine fetches the tail through
  Discourse's post_ids[] batches (signed like every read, uncached —
  each batch is one slice of a moving whole), and the CLI grows
  `topic <id> --all` for the same in a terminal.
- Un-liking on every desktop: a second click on a liked post now removes
  the like. The reader routes the click (by the button's own state) to a
  new `unlike-post` RPC carrying the engine's was_deleted direction, and
  one settle path repaints the button from the server's answer — heart,
  count, and tooltip move together, and a failed call re-enables the
  button instead of leaving it stuck.
- The branded installer experience declared in `rivet.rktd` now takes
  effect: the macOS DMG ships the drag-to-install layout (background
  art, an /Applications symlink, placed icons, hidden status bar) and
  the Windows MSI gains the stock wizard sequence (welcome, license,
  install dir, progress, exit) with Threadly artwork and an
  auto-rendered license page. This rides a rivet pin advance from
  v0.11.0 to the rivet revision that implements it
  (cb97b88ad27dc604ef235f47e8e8c040ffd0670b — main, no tag yet).

## 0.12.0 - 2026-10-15

Linux is the last host on the family update surface, and this release
comes with one rollout note: **starting with 0.12.0, Linux AppImage
installs update themselves in place** — Threadly checks, verifies,
swaps the sibling `.AppImage` over the running image and re-executes,
no terminal and no manual re-download. That flow does not exist in
0.11.0 or earlier, so **AppImage users on those versions must upgrade
one last time by hand**: download
`threadly-0.12.0-linux-x86_64.AppImage` (or
`threadly-0.12.0-linux-aarch64.AppImage` on arm64) from this release,
replace your existing AppImage file with it, make it executable
(`chmod +x`) if needed, and launch. From then on every future release
updates itself inside the app. deb/rpm installs keep their package
manager, portable installs keep the hand-off flow; macOS and Windows
were already self-updating.

### Added
- Linux update flow, the last host on the shared backend update surface:
  a silent launch check throttled to once per 4 hours (local stamp file,
  the Windows host's storage), a "Check for Updates…" header entry that
  bypasses the throttle, a consent dialog, 400 ms progress polling, and a
  hand-off keyed on install shape. AppImage installs get an in-place
  update — the backend swaps the sibling `.AppImage` release asset over
  the running image, checksummed against its `.sha256` sidecar, and the
  host only asks to re-exec; `/opt/threadly` and `/usr` installs are
  pointed at their package manager; portable installs hand off the
  verified tar.gz with an open-folder action. Silent checks surface only
  an available update — never a nag.
- About on every desktop: macOS grows an "About Threadly" app-menu item
  opening a sheet (version, copyright, license line, product site +
  "Report an Issue" links); Windows gets an About button in the sidebar
  header opening the same-shape dialog; Linux a help-about button opening
  a GTK about dialog. All three carry the AGPL-3.0 line and the
  threadly.jrtx.site / GitHub-issues links.
- Windows update-failure dialogs ("Update failed" family) gain a
  "Copy error" secondary button that puts the failure text on the
  clipboard — macOS status lines were already selectable; Linux dialogs
  take selection. Error text always leaves the screen with the user.
- GitHub issue templates (bug report, feature request, contact links to
  the user guide).

### Changed
- CLI `usage` now lists the `category` and `update-check` subcommands —
  both were implemented but missing from the help text.

### Fixed
- Invoking the CLI with no command crashed with a contract violation
  before the usage/exit-2 path could run; it now prints usage and exits 2.

## 0.11.0 - 2026-10-14

The last update-engine bypass in the family is gone: the update engine
moves onto rivet/distribution end to end, and the macOS updater swaps its
hand-rolled CryptoKit for rivet's RivetUpdate. No new features — this is
the existing update capability rebuilt on the family engine: a
user-visible reliability improvement.

### Changed
- Update engine rebuilt on rivet/distribution: manifest fetch + Ed25519
  verification through the library (the hand-rolled signed-wrapper parser
  and the shelled-out OpenSSL 3 are gone), artifact download through
  download-update (redirect-following fetch, signed-size cap, .partial
  cleanup, SHA-256 + size verification, atomic rename), a 120 s stall /
  30 min total watchdog so a stuck download always reaches a terminal
  phase, and a sticky per-install rollout bucket (crypto-random-bytes,
  persisted to updater-state.json behind a one-key whitelist). The wire
  format is unchanged — the same signed update-manifest.json the 0.10.0
  feed already ships.
- macOS host updater replaced with a thin adapter over rivet's
  RivetUpdate module (verification, bounded download, atomic swap with
  rollback, and the quit/relaunch handoff live in the library); the host
  no longer imports CryptoKit.
- Rivet pin raised to v0.11.0 everywhere: ci.yml checkout refs, the
  release RIVET_COMMIT, and the setup-embed-racket action ref — the last
  main-branch drift is closed.
- Linux host consumes the platform as a package library
  (add_subdirectory + rivet::platform) instead of hand-copied Rivet
  source lists; Windows host links the rivet-host static project with a
  shared CRT knob (an unconditional MT forward would break dev builds
  with LNK2038) instead of compiling Rivet sources into the project.
- Site: the four stale "0.3.0 released" lines are gone, roadmap/status
  copy reflects what actually shipped (M1–M3 done, M4 in progress), and
  the README gains release + platform badges.

### Added
- User guide (site/guide.html, linked from the site nav): a five-minute
  start (install → sign in → first topic), the core features (topics,
  notifications, likes, AI summaries and translation with the
  `threadly ai-config` 0600 walkthrough), and an FAQ (scopes, data
  locations, accounts, platforms, updates, uninstall). Bilingual,
  Chinese-first.

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
