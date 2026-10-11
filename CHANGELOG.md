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
- CI: engine tests on ubuntu/macos/windows plus a macOS host package gate;
  release pipeline shipping macOS DMG (arm64/x64) with a signed update feed.
