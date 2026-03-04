#!/usr/bin/env bash
# capture-displays.sh — run once after arranging displays correctly.
# Reads current display arrangement via displayplacer and writes data files
# used by wake-hook.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPLAYPLACER=/opt/homebrew/bin/displayplacer

if [[ $# -gt 0 ]]; then
  exec "$SCRIPT_DIR/capture-profile.sh" "$@"
fi

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

HOME_PROFILE_DIR="$SCRIPT_DIR/profiles/home"
if [[ -d "$HOME_PROFILE_DIR" ]] && [[ -n "$(ls -A "$HOME_PROFILE_DIR" 2>/dev/null)" ]]; then
  TS=$(date '+%Y%m%d-%H%M%S')
  cp -r "$HOME_PROFILE_DIR" "$SCRIPT_DIR/profiles/home.bak.$TS"
  echo "Previous home profile backed up to profiles/home.bak.$TS"
fi
mkdir -p "$HOME_PROFILE_DIR"

# Extract each quoted display arg onto its own line (strips surrounding quotes)
DISPLAY_ARGS_FILE="$SCRIPT_DIR/profiles/home/display.args"
echo "$DISPLAY_CMD" | grep -oE '"[^"]+"' | sed 's/^"//;s/"$//' > "$DISPLAY_ARGS_FILE"
echo "Display args saved to profiles/home/display.args"

# Extract and save display IDs for home detection
HOME_IDS_FILE="$SCRIPT_DIR/profiles/home/match.ids"
echo "$DISPLAY_CMD" | grep -oE 'id:[A-F0-9-]+' | sed 's/id://' > "$HOME_IDS_FILE"
echo "Home display IDs saved to profiles/home/match.ids"
