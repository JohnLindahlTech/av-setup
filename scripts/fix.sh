#!/usr/bin/env bash
# fix.sh — on-demand AV recovery CLI.
# Usage: fix [display|audio|mic|deck|all]

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
LOG_DIR="$HOME/.local/log"
LOG="$LOG_DIR/wake-av.log"

mkdir -p "$LOG_DIR"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG"
}

# shellcheck source=recovery-lib.sh
source "$SCRIPT_DIR/recovery-lib.sh"

cmd="${1:-all}"

case "$cmd" in
  display)
    log "=== fix display ==="
    if [[ -n "${2:-}" ]]; then
      fix_display_profile "$2"
    else
      _p=$(detect_extra_profile)
      [[ -n "$_p" ]] && fix_display_profile "$_p" || log "No matching display profile found."
    fi
    ;;
  audio)
    log "=== fix audio ==="
    fix_audio
    ;;
  mic)
    log "=== fix mic ==="
    fix_mic
    ;;
  deck)
    log "=== fix deck ==="
    fix_deck
    ;;
  all)
    log "=== fix all ==="
    _p=$(detect_extra_profile)
    [[ -n "$_p" ]] && fix_display_profile "$_p" || log "No matching display profile found."
    fix_audio
    fix_mic
    fix_deck
    ;;
  capture)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: fix capture <name> [--by ids|attrs] [--with-brand-model]"
      exit 1
    fi
    exec "$SCRIPT_DIR/capture-profile.sh" "${@:2}"
    ;;
  *)
    echo "Usage: fix [display [<profile>]|audio|mic|deck|all|capture <name>]"
    echo "  display            Auto-detect and restore monitor arrangement"
    echo "  display <name>     Force a specific named profile"
    echo "  audio              Set audio output device"
    echo "  mic                Recover microphone input (restarts coreaudiod if needed)"
    echo "  deck               Relaunch Stream Deck"
    echo "  all                Run all of the above (default)"
    echo "  capture <name>     Save current display arrangement as a named profile"
    echo "    --by ids|attrs       Match by persistent IDs (default) or display attributes"
    echo "    --with-brand-model   Include brand/model in attribute match (slow)"
    exit 1
    ;;
esac

log "=== fix complete ==="
