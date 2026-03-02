#!/usr/bin/env bash
# wake-hook.sh — triggered by sleepwatcher on every wake from sleep.
# Install location: ~/.wakeup (sleepwatcher's convention).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$HOME/.local/log"
LOG="$LOG_DIR/wake-av.log"

mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# shellcheck source=recovery-lib.sh
source "$SCRIPT_DIR/recovery-lib.sh"

log "=== Wake event ==="

# ── Wait for USB buses to settle ──────────────────────────────────────────────
log "Waiting 8s for USB to settle..."
sleep 8

# ── Detect matching display profile (home first, then others) ─────────────────
_profile=$(detect_extra_profile)

if [[ -n "$_profile" ]]; then
  log "Matched profile '$_profile' — proceeding with AV restore."
  fix_display_profile "$_profile"
  fix_audio
  fix_mic
  fix_deck
  log "=== Wake handling complete (profile: $_profile) ==="
else
  log "No display profile matched — skipping AV restore."
  log "=== Wake handling complete (away) ==="
fi
