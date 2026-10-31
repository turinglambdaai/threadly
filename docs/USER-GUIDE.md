# Threadly user guide

**English** · [简体中文](USER-GUIDE.zh-CN.md)

Read and search the Racket community forum in a native desktop window.

## Availability

Free community reader in maintenance mode under AGPL-3.0. No commercial account or paid mobile offer.

## Platforms and installation

Desktop maintenance scope: macOS, Windows and Linux. Mobile and watch clients are not current deliveries.

Use [official Releases](https://github.com/turlamai/threadly/releases), select an explicitly listed OS/architecture asset, read its release notes and check supplied checksums. An absent asset/platform is not a delivery promise. Current macOS packages are ad-hoc signed, **not** Developer ID signed or notarized. Windows MSI/portable ZIP packages are unsigned; SmartScreen may warn. Linux packages do not require a paid developer account. Do not disable system-wide security protections to install a package. In-app updates require an Ed25519-signed manifest and a matching artifact hash.

## Your first successful session

1. Open the latest topics without signing in and read one thread.
2. Search a known phrase and follow the original forum link to confirm attribution and current content.
3. If using login, replies or AI, check that the selected build actually provides the flow and review its credential/provider behavior first.

## Data, backup and recovery

The forum remains the authoritative content source. Local caches can be stale and are not a full forum archive. Back up personal settings before reinstalling, and keep tokens out of shared backups and diagnostics.

## Network, keys and privacy

Browsing/search contact the public Discourse forum; login/reply operations act on your forum account. Optional BYOK AI sends selected text to its provider. Respect rate limits and do not send private forum content without permission.

## Known limits

Reading, searching, sign-in, replies, likes, notifications and BYOK AI are implemented; when a thread fails to load, the reader offers Retry and Back-to-list, and unsent replies are kept as drafts per thread until they post. Packaged-install qualification of these flows on every release channel is still pending — verify against the release notes of the build you use. Cached content may differ from edited/deleted source posts.

## Updates and removal

Back up data and read the destination release notes first. An in-app update check does not necessarily install an update for your channel; follow the manual for portable, installer and source paths. Never bypass a failed signature check or replace the program with an untrusted artifact. On failure, preserve data and the error, then recover with a trusted release. Removing the program does not necessarily erase its separate data directory; verify your backup before deleting personal data.

## Get help

Report problems in [GitHub Issues](https://github.com/turlamai/threadly/issues), in English or Chinese. Include the version, OS/architecture, installation channel, steps, expected result and actual result. Reproduce with synthetic input first; do not attach keys, credentials, databases, private source documents or complete logs. Public support has no guaranteed response time.

## Further reading

- [Reading manual](../site/guide.html)
- [Project overview and development](../README.md)
- [Current licence](../LICENSE)
