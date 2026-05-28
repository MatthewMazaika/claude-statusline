#!/usr/bin/env bash
# Installer for claude-statusline (Linux/macOS). Idempotent.
# Works two ways:
#   from a clone:    bash install.sh           (copies the sibling statusline.sh)
#   piped remotely:  curl -fsSL .../install.sh | bash   (fetches statusline.sh)
set -euo pipefail

# Moving major tag; fetch mode always pulls the latest v2.x release (the release
# workflow force-moves this tag on each release). Pin a vX.Y.Z tag for a fixed version.
REF="v2"
RAW_BASE="https://raw.githubusercontent.com/MatthewMazaika/claude-statusline/$REF"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but was not found on PATH." >&2
  echo "  Debian/Ubuntu: sudo apt install jq" >&2
  echo "  macOS:         brew install jq" >&2
  exit 1
fi

fetch() {  # url dest
  if   command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
  else echo "Error: need curl or wget to download statusline.sh." >&2; exit 1; fi
}

CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"
DEST="$CLAUDE_DIR/statusline.sh"

# Dual-mode: copy the sibling script when run from a clone, otherwise fetch it.
SOURCE="${BASH_SOURCE[0]:-$0}"
LOCAL_SL=""
if [ -f "$SOURCE" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  [ -f "$SCRIPT_DIR/statusline.sh" ] && LOCAL_SL="$SCRIPT_DIR/statusline.sh"
fi

if [ -n "$LOCAL_SL" ]; then
  cp "$LOCAL_SL" "$DEST"
  echo "Installed statusline.sh (from clone) -> $DEST"
else
  fetch "$RAW_BASE/statusline.sh" "$DEST"
  echo "Installed statusline.sh (fetched) -> $DEST"
fi
chmod +x "$DEST"

CMD="bash $DEST"
SETTINGS="$CLAUDE_DIR/settings.json"
ENTRY="$(jq -n --arg cmd "$CMD" '{type: "command", command: $cmd}')"

if [ -f "$SETTINGS" ]; then
  tmp="$(mktemp)"
  jq --argjson sl "$ENTRY" '. + {statusLine: $sl}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
else
  jq -n --argjson sl "$ENTRY" '{statusLine: $sl}' > "$SETTINGS"
fi

echo "settings.json statusLine.command = $CMD"
