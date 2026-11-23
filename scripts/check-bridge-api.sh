#!/usr/bin/env bash
# Verifies that the CI stub (Sources/InkBridgeStub) exposes the same public API
# as the real engine bridge (Sources/InkBridge). Run after editing either file.
set -euo pipefail
cd "$(dirname "$0")/.."

extract() {
  grep -E '^[[:space:]]*(@discardableResult[[:space:]]+)?public[[:space:]]' "$1" \
    | sed -E 's/@discardableResult[[:space:]]+//; s/[[:space:]]*\{.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    | sort
}

if diff -u <(extract Sources/InkBridge/InkBridge.swift) <(extract Sources/InkBridgeStub/InkBridge.swift); then
  echo "InkBridge and InkBridgeStub public APIs match."
else
  echo "error: InkBridgeStub differs from InkBridge (see diff above)." >&2
  exit 1
fi
