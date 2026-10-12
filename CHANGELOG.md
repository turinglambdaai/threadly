# Changelog

All notable changes to Threadly are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is SemVer.

## Unreleased

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
