#!/usr/bin/env bash
# capture-displays.sh — run once after arranging displays correctly.
# Reads current display arrangement via displayplacer and writes data files
# used by wake-hook.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPLAYPLACER=/opt/homebrew/bin/displayplacer

if [[ ! -x "$DISPLAYPLACER" ]]; then
  echo "ERROR: displayplacer not found at $DISPLAYPLACER. Run brew install displayplacer." >&2
  exit 1
fi

echo "Capturing current display arrangement..."
# displayplacer list prints a ready-to-use command on the last line
DISPLAY_CMD=$("$DISPLAYPLACER" list | grep '^displayplacer ')

if [[ -z "$DISPLAY_CMD" ]]; then
  echo "ERROR: Could not parse displayplacer output." >&2
  exit 1
fi

echo "Detected command:"
echo "  $DISPLAY_CMD"

mkdir -p "$SCRIPT_DIR/profiles/home"

# Extract each quoted display arg onto its own line (strips surrounding quotes)
DISPLAY_ARGS_FILE="$SCRIPT_DIR/profiles/home/display.args"
echo "$DISPLAY_CMD" | grep -oE '"[^"]+"' | sed 's/^"//;s/"$//' > "$DISPLAY_ARGS_FILE"
echo "Display args saved to profiles/home/display.args"

# Extract and save display IDs for home detection
HOME_IDS_FILE="$SCRIPT_DIR/profiles/home/match.ids"
echo "$DISPLAY_CMD" | grep -oE 'id:[A-F0-9-]+' | sed 's/id://' > "$HOME_IDS_FILE"
echo "Home display IDs saved to profiles/home/match.ids"
