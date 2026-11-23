#!/usr/bin/env bash
# Checks (and where possible prepares) everything `xtool dev` needs on Linux / WSL.
set -uo pipefail
cd "$(dirname "$0")/.."

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=1; }
FAILED=0

echo "Note iPad — build environment"

if command -v swift >/dev/null 2>&1; then
  ok "Swift: $(swift --version 2>/dev/null | head -1)"
else
  fail "Swift toolchain not found — https://swift.org/install/linux"
fi

if command -v xtool >/dev/null 2>&1; then
  ok "xtool: $(command -v xtool)"
  if swift sdk list 2>/dev/null | grep -q darwin; then
    ok "Darwin Swift SDK installed"
  else
    fail "Darwin SDK missing — run: xtool setup (needs Xcode.xip)"
  fi
else
  fail "xtool not found — see docs/BUILD_WSL.md §2"
fi

if command -v usbmuxd >/dev/null 2>&1; then
  ok "usbmuxd installed"
else
  warn "usbmuxd not found — sudo apt-get install usbmuxd (needed to install on the iPad)"
fi

if [ -n "${NOTE_CORE_PATH:-}" ]; then
  core="$NOTE_CORE_PATH"
else
  core="../note-core"
fi
if [ -f "$core/Package.swift" ]; then
  ok "note-core: $(cd "$core" && pwd) ($(git -C "$core" log -1 --format=%h 2>/dev/null || echo '?'))"
  if ! grep -q "ink_editor_render_over_rgba" "$core/engine/include/ink/ink_c.h" 2>/dev/null; then
    fail "note-core is too old for this app — git -C $core pull"
  fi
else
  if [ -z "${NOTE_CORE_PATH:-}" ] && [ ! -e "$core" ]; then
    warn "note-core not found next to note-ipad — cloning…"
    if git clone https://github.com/lemon7679/note-core.git "$core"; then
      ok "note-core cloned to $(cd "$core" && pwd)"
    else
      fail "could not clone note-core"
    fi
  else
    fail "note-core not found at $core"
  fi
fi

if [ "$FAILED" = 0 ]; then
  echo
  echo "Ready. Connect the iPad (usbipd attach on Windows) and run: xtool dev"
else
  echo
  echo "Fix the items above, then run this script again."
  exit 1
fi
