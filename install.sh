#!/usr/bin/env bash
# Installer for claude-statusline (Linux/macOS). Idempotent.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but was not found on PATH." >&2
  echo "  Debian/Ubuntu: sudo apt install jq" >&2
  echo "  macOS:         brew install jq" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"

cp "$SCRIPT_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"

CMD="bash $CLAUDE_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
ENTRY="$(jq -n --arg cmd "$CMD" '{type: "command", command: $cmd}')"

if [ -f "$SETTINGS" ]; then
  tmp="$(mktemp)"
  jq --argjson sl "$ENTRY" '. + {statusLine: $sl}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
else
  jq -n --argjson sl "$ENTRY" '{statusLine: $sl}' > "$SETTINGS"
fi

echo "Installed statusline.sh -> $CLAUDE_DIR/statusline.sh"
echo "settings.json statusLine.command = $CMD"
