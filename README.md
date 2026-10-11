# Threadly

A native desktop client for the Racket community forum — browse, read, and
search [racket.discourse.group](https://racket.discourse.group) without
opening a browser tab. The forum is where Racket's design decisions,
proposals, and ecosystem news actually happen; Threadly gives those long
technical threads the desktop reading experience they deserve.

[![CI](https://github.com/turinglambdaai/threadly/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/threadly/actions/workflows/ci.yml) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE) ![Racket](https://img.shields.io/badge/Racket-9.3-9D00FF?logo=racket&logoColor=white)

**English** · [中文](README.zh-CN.md)

## Why

Every page of the forum loads a web app — sidebar, trackers, infinite
chrome — around text that deserves better. Long threads about type systems
and macro expanders scroll past in a browser tab you lose the moment you
switch away. And there is no desktop client at all: Discourse ships
official iOS/Android apps, but desktop users get a URL.

Threadly is that desktop client, built the way the Racket community
builds things: a small Racket engine, first-party native UI, and no
magic.

## How it works

- **Browse** — the latest topics across all categories, with reply, view,
  and like counts, backed by a polite on-disk cache so re-opening a view
  never re-hits the forum.
- **Read** — a thread view built for long discussions: posts in reading
  order, rendered from the forum's own HTML, with the author and original
  thread one click away on the web.
- **Search** — full archive search, keyboard-first.

The engine speaks the anonymous public Discourse JSON API (any forum URL
plus `.json`). No account, no scraping, no private endpoints.

## Design principles

1. **The forum is the source of truth.** Threadly caches, it never forks:
   edits, deletions, and topic moves always win, and every thread links
   back to the web.
2. **A good citizen.** Public endpoints only, every response cached on
   disk with a TTL, requests carry a identifying User-Agent, and a 429 is
   honored rather than retried into the ground.
3. **Read-only today.** No credentials live in or near the app. Signing
   in (via Discourse's user API key flow) is a later milestone, not a
   hidden feature.
4. **Long-form first.** The reading experience is the product; chrome is
   the thing being removed.

## Status & roadmap

Working today: the Discourse engine (latest / topic / search / categories),
the TTL disk cache with offline fallback, a terminal CLI, and the macOS
SwiftUI shell.

- [x] M0 — Discourse engine, disk cache, CLI, macOS SwiftUI shell
- [ ] M1 — Windows and Linux native hosts
- [ ] M2 — signed-in mode: user API key flow, replies, likes, notifications
- [ ] M3 — reading value-add: thread summaries, translation

## Build from source

```bash
raco test tests/                     # everything must stay green (no network needed)

racket app/cli.rkt latest            # browse from the terminal
racket app/cli.rkt topic <id>        # read a thread
racket app/cli.rkt search "raco"     # search the archive
racket app/cli.rkt doctor            # local environment check (offline)
```

Threadly follows the [Rivet](https://github.com/turinglambdaai/rivet)
architecture: a Racket engine behind first-party native hosts. The macOS
shell lives in `macos-host/` and builds through `raco rivet build`.

## License

[AGPL-3.0](LICENSE)
