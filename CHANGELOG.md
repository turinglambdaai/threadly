# Changelog

All notable changes to Threadly are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## Unreleased

### Added
- Discourse engine: latest topics, topic threads, archive search, and
  categories over the anonymous public JSON API, with manual redirect
  following and a TTL disk cache (stale cache still answers when the forum
  is unreachable).
- CLI: `version`, `latest`, `topic`, `search`, `categories`, `doctor`, and
  a global `--json` flag; `doctor` and `version` never touch the network.
- macOS SwiftUI shell (Rivet host): sidebar topic browser, thread reader,
  archive search.
- App icon (family terracotta palette, thread staircase mark) for the
  macOS and Windows bundles; `THREADLY_APPEARANCE=dark|light` pins the
  appearance for dual-theme verification.
- CI: engine tests on ubuntu/macos/windows plus a macOS host package gate;
  release pipeline shipping macOS DMG (arm64/x64) with a signed update feed.

### Changed
- Category chips render the forum's own category colors; topic counts use
  SF Symbols; the thread reader renders post avatars and constrains text
  to a 680px reading column.
