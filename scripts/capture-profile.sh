#!/usr/bin/env bash
# capture-profile.sh — capture a named display profile for multi-profile matching.
# Usage: capture-profile.sh <name> [--by ids|attrs] [--with-brand-model]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPLAYPLACER=/opt/homebrew/bin/displayplacer

# ── Parse args ────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: capture-profile.sh <name> [--by ids|attrs] [--with-brand-model]"
  echo "  <name>             Profile name (e.g. work-dell)"
  echo "  --by ids           Match by persistent UUIDs (default)"
  echo "  --by attrs         Match by display attributes (res, type, brand, model)"
  echo "  --with-brand-model Also capture brand/model from system_profiler (slow; --by attrs only)"
  exit 1
}

[[ $# -lt 1 ]] && usage
PROFILE_NAME="$1"
shift

BY="ids"
WITH_BRAND_MODEL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --by)
      [[ $# -lt 2 ]] && usage
      BY="$2"
      shift 2
      ;;
    --with-brand-model)
      WITH_BRAND_MODEL=1
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$BY" == "ids" || "$BY" == "attrs" ]] || { echo "ERROR: --by must be 'ids' or 'attrs'" >&2; exit 1; }

if [[ ! -x "$DISPLAYPLACER" ]]; then
  echo "ERROR: displayplacer not found at $DISPLAYPLACER. Run: brew install displayplacer" >&2
  exit 1
fi

PROFILE_DIR="$SCRIPT_DIR/profiles/$PROFILE_NAME"
if [[ -d "$PROFILE_DIR" ]] && [[ -n "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ]]; then
  TS=$(date '+%Y%m%d-%H%M%S')
  cp -r "$PROFILE_DIR" "$SCRIPT_DIR/profiles/${PROFILE_NAME}.bak.$TS"
  echo "Previous profile '$PROFILE_NAME' backed up to profiles/${PROFILE_NAME}.bak.$TS"
fi
mkdir -p "$PROFILE_DIR"

echo "Capturing display info..."
DISPLAY_OUTPUT=$("$DISPLAYPLACER" list 2>/dev/null)

# ── Extract the ready-to-use command line ─────────────────────────────────────
DISPLAY_CMD=$(echo "$DISPLAY_OUTPUT" | grep '^displayplacer ')
if [[ -z "$DISPLAY_CMD" ]]; then
  echo "ERROR: Could not parse displayplacer output." >&2
  exit 1
fi

# ── Parse per-display blocks from displayplacer list output ───────────────────
# Each block starts at "Persistent screen id:" and contains contextual id,
# type string, and resolution. Output lines: "contextual_id|persistent_id|type|res"
parse_blocks() {
  local p_id="" c_id="" type_str="" res_str="" in_block=0

  do_flush() {
    [[ -z "$p_id" ]] && return
    local dtype dres
    if echo "$type_str" | grep -qi "built.in"; then dtype="builtin"; else dtype="external"; fi
    dres=$(echo "$res_str" | tr -d ' ')
    echo "${c_id}|${p_id}|${dtype}|${dres}"
    p_id=""; c_id=""; type_str=""; res_str=""; in_block=0
  }

  while IFS= read -r line; do
    if echo "$line" | grep -q "^Persistent screen id:"; then
      do_flush
      p_id=$(echo "$line" | sed 's/Persistent screen id: *//')
      in_block=1
    elif [[ $in_block -eq 1 ]]; then
      if echo "$line" | grep -q "^Contextual screen id:"; then
        c_id=$(echo "$line" | sed 's/Contextual screen id: *//')
      elif echo "$line" | grep -q "^Type:"; then
        type_str=$(echo "$line" | sed 's/Type: *//')
      elif echo "$line" | grep -q "^Resolution:"; then
        res_str=$(echo "$line" | sed 's/Resolution: *//')
      fi
    fi
  done <<< "$DISPLAY_OUTPUT"
  do_flush
}

# Sort blocks by contextual ID so DISP_N index is consistent with port/connection order
mapfile -t BLOCKS < <(parse_blocks | sort -t'|' -k1,1n)

if [[ ${#BLOCKS[@]} -eq 0 ]]; then
  echo "ERROR: No display blocks found in displayplacer output." >&2
  exit 1
fi

echo "Found ${#BLOCKS[@]} display(s):"
for b in "${BLOCKS[@]}"; do
  IFS='|' read -r c_id p_id dtype dres <<< "$b"
  echo "  [ctx:${c_id}] ${p_id}  type:${dtype}  res:${dres}"
done
echo ""

# ── IDs mode ──────────────────────────────────────────────────────────────────
if [[ "$BY" == "ids" ]]; then
  : > "$PROFILE_DIR/match.ids"
  for b in "${BLOCKS[@]}"; do
    IFS='|' read -r c_id p_id dtype dres <<< "$b"
    echo "$p_id" >> "$PROFILE_DIR/match.ids"
  done
  echo "Saved profiles/$PROFILE_NAME/match.ids (${#BLOCKS[@]} IDs)."

  echo "$DISPLAY_CMD" | grep -oE '"[^"]+"' | sed 's/^"//;s/"$//' > "$PROFILE_DIR/display.args"
  echo "Saved profiles/$PROFILE_NAME/display.args."

  echo ""
  echo "Profile '$PROFILE_NAME' captured (ID-based)."
  echo "  Verify:  cat scripts/profiles/$PROFILE_NAME/match.ids"
  echo "  Apply:   fix display $PROFILE_NAME"
  exit 0
fi

# ── Attrs mode ────────────────────────────────────────────────────────────────

# Optionally gather brand/model from system_profiler, keyed by resolution
declare -A RES_TO_BRAND
declare -A RES_TO_MODEL

if [[ $WITH_BRAND_MODEL -eq 1 ]]; then
  echo "Running system_profiler SPDisplaysDataType (may be slow)..."
  SP_OUTPUT=$(system_profiler SPDisplaysDataType 2>/dev/null)

  # Each display appears as an indented name ("  DisplayName:") followed by
  # its attributes including "  Resolution: W x H @ Hz".
  cur_name=""
  while IFS= read -r line; do
    # Display name line: 4 spaces, word chars, colon, end of line
    if echo "$line" | grep -qE '^\s{4}[A-Za-z].*:$'; then
      cur_name=$(echo "$line" | sed 's/^ *//;s/:$//')
    elif echo "$line" | grep -qE '^\s+Resolution:'; then
      sp_res=$(echo "$line" | sed 's/.*Resolution: *//;s/ x /x/;s/ @.*//' | tr -d ' ')
      if [[ -n "$cur_name" && -n "$sp_res" ]]; then
        RES_TO_BRAND["$sp_res"]=$(echo "$cur_name" | awk '{print $1}')
        RES_TO_MODEL["$sp_res"]=$(echo "$cur_name" | awk '{$1=""; print $0}' | sed 's/^ //')
        cur_name=""
      fi
    fi
  done <<< "$SP_OUTPUT"
fi

# Write match.attrs — one line per display, sorted by contextual ID
{
  echo "# Profile: $PROFILE_NAME"
  for b in "${BLOCKS[@]}"; do
    IFS='|' read -r c_id p_id dtype dres <<< "$b"
    entry="res:${dres} type:${dtype}"
    if [[ $WITH_BRAND_MODEL -eq 1 ]]; then
      brand="${RES_TO_BRAND[$dres]:-}"
      model="${RES_TO_MODEL[$dres]:-}"
      [[ -n "$brand" ]] && entry="$entry brand:$brand"
      [[ -n "$model" ]] && entry="$entry model:$model"
    fi
    echo "$entry"
  done
} > "$PROFILE_DIR/match.attrs"
echo "Saved profiles/$PROFILE_NAME/match.attrs."

# Write display.args with DISP_N placeholders substituted for persistent IDs
# Build persistent_id → DISP_N mapping
declare -A PID_TO_PLACEHOLDER
i=0
for b in "${BLOCKS[@]}"; do
  IFS='|' read -r c_id p_id dtype dres <<< "$b"
  PID_TO_PLACEHOLDER["$p_id"]="DISP_${i}"
  (( i++ ))
done

{
  while IFS= read -r arg; do
    [[ -z "$arg" ]] && continue
    new_arg="$arg"
    for pid in "${!PID_TO_PLACEHOLDER[@]}"; do
      placeholder="${PID_TO_PLACEHOLDER[$pid]}"
      new_arg="${new_arg/id:$pid/id:$placeholder}"
    done
    echo "$new_arg"
  done < <(echo "$DISPLAY_CMD" | grep -oE '"[^"]+"' | sed 's/^"//;s/"$//')
} > "$PROFILE_DIR/display.args"
echo "Saved profiles/$PROFILE_NAME/display.args (with DISP_N placeholders)."

echo ""
echo "Profile '$PROFILE_NAME' captured (attribute-based)."
echo ""
echo "match.attrs:"
cat "$PROFILE_DIR/match.attrs"
echo ""
echo "display.args:"
cat "$PROFILE_DIR/display.args"
echo ""
echo "  Verify:  cat scripts/profiles/$PROFILE_NAME/match.attrs"
echo "  Apply:   fix display $PROFILE_NAME"
