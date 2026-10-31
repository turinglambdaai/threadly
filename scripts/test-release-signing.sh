#!/usr/bin/env bash
# Offline negative release test: an unrelated Ed25519 private key must never
# produce an update feed trusted by the shipped Racket/macOS clients.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
for name in "macos-arm64.zip" "macos-x64.zip" "windows-x64.zip" "linux-x64.tar.gz"; do
  : > "$TMP/threadly-$VERSION-$name"
done
openssl genpkey -algorithm Ed25519 -out "$TMP/untrusted.pem" >/dev/null 2>&1
if bash "$ROOT/scripts/make-update-manifest.sh" "v$VERSION" "$TMP" "$TMP/untrusted.pem" > "$TMP/log" 2>&1; then
  echo "release-security: untrusted Ed25519 signing key was accepted" >&2
  exit 1
fi
if ! grep -q "signing key does not match embedded" "$TMP/log"; then
  echo "release-security: failed for an unexpected reason" >&2
  cat "$TMP/log" >&2
  exit 1
fi
test ! -e "$TMP/update-manifest.json"
echo "release-security: unrelated signing key rejected before manifest creation"
