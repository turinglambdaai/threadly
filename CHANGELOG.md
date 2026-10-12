# Changelog

All notable changes to Threadly are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## Unreleased

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
