# Threadly

A native client for the Racket community forum — browse, read, and
search [racket.discourse.group](https://racket.discourse.group) without
opening a browser tab. The forum is where Racket's design decisions,
proposals, and ecosystem news actually happen; Threadly gives those long
technical threads the reading experience they deserve, on the desktop
today and on iOS, iPadOS, and Android next.

[![CI](https://github.com/turinglambdaai/threadly/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/threadly/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/turinglambdaai/threadly)](https://github.com/turinglambdaai/threadly/releases/latest) [![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-blue)](https://github.com/turinglambdaai/threadly/releases/latest) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE) ![Racket](https://img.shields.io/badge/Racket-9.3-9D00FF?logo=racket&logoColor=white)

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
3. **Anonymous reading first.** Public reading needs no account. Signed-in
   actions use Discourse's user API key flow; credentials stay local and must
   never appear in caches, logs or feedback.
4. **Long-form first.** The reading experience is the product; chrome is
   the thing being removed.

## Status & roadmap

Working today: the Discourse engine (latest / topic / search / categories),
the TTL disk cache with offline fallback, a terminal CLI, and native hosts
for macOS, Windows and Linux. Signed-in actions and BYOK AI are implemented;
packaged workflow evidence remains a separate delivery gate.

- [x] M0 — Discourse engine, disk cache, CLI, macOS SwiftUI shell
- [x] M1 — Windows and Linux native hosts
- [x] M2 — signed-in mode: user API key flow, replies, likes (with the
      forum's own like state), notifications, mark-as-read — on all
      three desktop platforms
- [x] M3 — reading value-add: AI thread summaries and translation over
      any OpenAI-compatible endpoint (configurable via the CLI)
- [ ] Mobile is a deferred option, gated on user demand, maintenance capacity
      and Rivet device-delivery evidence; it is not a current commitment.

## AI features (M3)

Summaries and translation run over any OpenAI-compatible
chat-completions endpoint. Configure once from the terminal; every host
and the CLI pick it up:

```bash
racket app/cli.rkt ai-config --base-url https://api.openai.com/v1 \
    --api-key sk-... --model gpt-4o-mini --target-lang Chinese
racket app/cli.rkt summary 4416      # AI summary of a thread
racket app/cli.rkt translate 4416    # AI translation of a thread
```

The key is stored 0600 in the data directory and never leaves the
machine except to the configured endpoint. In the desktop apps, open a
thread and use the Summarize / Translate toolbar buttons.

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

## Delivery priorities (2026-10-23)

The current product review issue linked from AGENTS owns the next bounded slice and its acceptance scenarios. Follow the existing product specification and the [family delivery standard](https://github.com/turinglambdaai/turinglambdaai.github.io/blob/master/docs/PRODUCT-STANDARD.md). Hardware, native-platform and live-payment gates remain explicit; this documentation update does not claim they passed.

## Feedback and diagnostics

Report reproducible bugs and feature requests through [GitHub Issues](https://github.com/turinglambdaai/threadly/issues). Include the release, OS/architecture and steps; inspect and redact diagnostics before sharing. Do not post API keys, license files, vault contents or private documents. For sensitive security reports, follow SECURITY.md when present; otherwise request a private contact route without disclosing sensitive details. Nothing is uploaded automatically.
