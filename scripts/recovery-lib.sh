#!/usr/bin/env bash
# recovery-lib.sh — shared recovery functions sourced by fix.sh and wake-hook.sh.
# Callers must define log() before sourcing this file.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SWITCHAUDIO=/opt/homebrew/bin/SwitchAudioSource
DISPLAYPLACER=/opt/homebrew/bin/displayplacer
STREAM_DECK_APP="/Applications/Elgato Stream Deck.app"

DISPLAY_ARGS_FILE="$_LIB_DIR/profiles/home/display.args"
HOME_IDS_FILE="$_LIB_DIR/profiles/home/match.ids"
AV_CONF="$_LIB_DIR/av.conf"

# Load audio device config
if [[ -f "$AV_CONF" ]]; then
  # shellcheck source=av.conf
  source "$AV_CONF"
else
  log "WARNING: av.conf not found — audio device names will be empty."
fi
AUDIO_OUTPUT="${AUDIO_OUTPUT:-}"
AUDIO_INPUT="${AUDIO_INPUT:-}"

# ── is_home_setup ──────────────────────────────────────────────────────────────
is_home_setup() {
  [[ -f "$HOME_IDS_FILE" ]] || { log "No profiles/home/match.ids — skipping (run install.sh)"; return 1; }
  [[ -x "$DISPLAYPLACER" ]] || { log "displayplacer not found — cannot detect environment"; return 1; }
  local current_displays
  current_displays=$("$DISPLAYPLACER" list 2>/dev/null)
  while IFS= read -r home_id; do
    [[ -n "$home_id" ]] || continue
    echo "$current_displays" | grep -q "$home_id" || return 1
  done < "$HOME_IDS_FILE"
  return 0
}

# ── fix_display ────────────────────────────────────────────────────────────────
fix_display() {
  if [[ ! -x "$DISPLAYPLACER" ]]; then
    log "WARNING: displayplacer not found — skipping display restore."
    return
  fi
  if [[ ! -f "$DISPLAY_ARGS_FILE" ]]; then
    log "WARNING: profiles/home/display.args not found — run install.sh to capture displays."
    return
  fi
  local args=()
  while IFS= read -r arg; do [[ -n "$arg" ]] && args+=("$arg"); done < "$DISPLAY_ARGS_FILE"
  "$DISPLAYPLACER" "${args[@]}" \
    && log "Display arrangement applied." \
    || log "WARNING: displayplacer failed."
}

# ── fix_audio ──────────────────────────────────────────────────────────────────
fix_audio() {
  if [[ ! -x "$SWITCHAUDIO" ]]; then
    log "WARNING: SwitchAudioSource not found — skipping audio output."
    return
  fi
  "$SWITCHAUDIO" -s "$AUDIO_OUTPUT" -t output \
    && log "Audio output set to $AUDIO_OUTPUT." \
    || log "WARNING: Could not set output to $AUDIO_OUTPUT (device may be absent)."
}

# ── fix_mic ────────────────────────────────────────────────────────────────────
fix_mic() {
  if [[ ! -x "$SWITCHAUDIO" ]]; then
    log "WARNING: SwitchAudioSource not found — skipping $AUDIO_INPUT check."
    return
  fi
  if "$SWITCHAUDIO" -a -t input | grep -q "$AUDIO_INPUT"; then
    log "$AUDIO_INPUT present — no coreaudiod restart needed."
    "$SWITCHAUDIO" -s "$AUDIO_INPUT" -t input \
      && log "$AUDIO_INPUT set as default input." \
      || log "WARNING: $AUDIO_INPUT found but could not set as default input."
  else
    log "$AUDIO_INPUT absent — restarting coreaudiod to force USB audio re-scan..."
    sudo /usr/bin/killall coreaudiod > /dev/null 2>&1 \
      && log "coreaudiod restarted." \
      || log "ERROR: failed to restart coreaudiod (check sudoers entry)."

    log "Waiting 5s for coreaudiod to settle..."
    sleep 5

    if "$SWITCHAUDIO" -a -t input | grep -q "$AUDIO_INPUT"; then
      "$SWITCHAUDIO" -s "$AUDIO_INPUT" -t input \
        && log "$AUDIO_INPUT recovered and set as default input." \
        || log "WARNING: $AUDIO_INPUT found but could not set as default input."
    else
      log "WARNING: $AUDIO_INPUT still absent after coreaudiod restart."
    fi
  fi
}

# ── fix_deck ───────────────────────────────────────────────────────────────────
fix_deck() {
  if [[ ! -d "$STREAM_DECK_APP" ]]; then
    log "Stream Deck not installed — skipping."
    return
  fi
  if pgrep -x "Stream Deck" > /dev/null 2>&1; then
    log "Relaunching Stream Deck to recover USB connection..."
    killall "Stream Deck" 2>/dev/null || true
    sleep 2
    open -g "$STREAM_DECK_APP" \
      && log "Stream Deck relaunched (background)." \
      || log "WARNING: Could not relaunch Stream Deck."
  else
    log "Stream Deck not running — skipping."
  fi
}

# ── _parse_disp_blocks ─────────────────────────────────────────────────────────
# Parses `displayplacer list` output and emits one line per display:
#   "contextual_id|persistent_id|type|resolution"
# Output is sorted by contextual_id ascending.
_parse_disp_blocks() {
  local dp_output
  dp_output=$("$DISPLAYPLACER" list 2>/dev/null)
  local p_id="" c_id="" type_str="" res_str="" in_block=0

  _pdb_flush() {
    [[ -z "$p_id" ]] && return
    local dtype dres
    if echo "$type_str" | grep -qi "built.in"; then dtype="builtin"; else dtype="external"; fi
    dres=$(echo "$res_str" | tr -d ' ')
    echo "${c_id}|${p_id}|${dtype}|${dres}"
    p_id=""; c_id=""; type_str=""; res_str=""; in_block=0
  }

  while IFS= read -r line; do
    if echo "$line" | grep -q "^Persistent screen id:"; then
      _pdb_flush
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
  done <<< "$dp_output"
  _pdb_flush
}

# ── _match_attrs_profile ───────────────────────────────────────────────────────
# Returns 0 if current connected displays satisfy all requirements in
# <profile_dir>/match.attrs (multiset match: each required line must be
# satisfied by a distinct display). Invokes system_profiler only when
# match.attrs contains brand: or model: fields.
_match_attrs_profile() {
  local profile_dir="$1"
  local attrs_file="$profile_dir/match.attrs"
  [[ -f "$attrs_file" ]] || return 1

  mapfile -t _mab_blocks < <(_parse_disp_blocks | sort -t'|' -k1,1n)
  [[ ${#_mab_blocks[@]} -eq 0 ]] && return 1

  local -a disp_types disp_ress
  local idx=0
  for b in "${_mab_blocks[@]}"; do
    IFS='|' read -r _cid _pid dtype dres <<< "$b"
    disp_types[$idx]="$dtype"
    disp_ress[$idx]="$dres"
    (( idx++ ))
  done
  local n_disps=$idx

  # Only call system_profiler if match.attrs uses brand/model attributes
  local -A res_to_brand res_to_model
  if grep -qE '\b(brand|model):' "$attrs_file"; then
    local sp_out cur_name=""
    sp_out=$(system_profiler SPDisplaysDataType 2>/dev/null)
    while IFS= read -r line; do
      if echo "$line" | grep -qE '^\s{4}[A-Za-z].*:$'; then
        cur_name=$(echo "$line" | sed 's/^ *//;s/:$//')
      elif echo "$line" | grep -qE '^\s+Resolution:'; then
        local sp_res
        sp_res=$(echo "$line" | sed 's/.*Resolution: *//;s/ x /x/;s/ @.*//' | tr -d ' ')
        if [[ -n "$cur_name" && -n "$sp_res" ]]; then
          res_to_brand["$sp_res"]=$(echo "$cur_name" | awk '{print $1}')
          res_to_model["$sp_res"]=$(echo "$cur_name" | awk '{$1=""; print $0}' | sed 's/^ //')
          cur_name=""
        fi
      fi
    done <<< "$sp_out"
  fi

  # Multiset matching: each non-comment line in match.attrs must be satisfied
  # by exactly one as-yet-unmatched display.
  local -a used
  for (( i=0; i<n_disps; i++ )); do used[$i]=0; done

  while IFS= read -r req_line; do
    [[ -z "$req_line" || "$req_line" == \#* ]] && continue
    local matched=0
    for (( j=0; j<n_disps; j++ )); do
      [[ ${used[$j]} -eq 1 ]] && continue
      local ok=1
      for token in $req_line; do
        local key="${token%%:*}" val="${token#*:}"
        case "$key" in
          res)   [[ "${disp_ress[$j]}"  == "$val" ]] || { ok=0; break; } ;;
          type)  [[ "${disp_types[$j]}" == "$val" ]] || { ok=0; break; } ;;
          brand)
            local b="${res_to_brand[${disp_ress[$j]}]:-}"
            [[ "$b" == "$val" ]] || { ok=0; break; }
            ;;
          model)
            local m="${res_to_model[${disp_ress[$j]}]:-}"
            [[ "$m" == "$val" ]] || { ok=0; break; }
            ;;
        esac
      done
      if [[ $ok -eq 1 ]]; then
        used[$j]=1
        matched=1
        break
      fi
    done
    [[ $matched -eq 1 ]] || return 1
  done < "$attrs_file"

  return 0
}

# ── detect_extra_profile ───────────────────────────────────────────────────────
# Echoes the name of the first matching profile, or nothing if none match.
# "home" is always checked first; remaining profiles are checked alphabetically.
detect_extra_profile() {
  local profiles_dir="$_LIB_DIR/profiles"
  [[ -d "$profiles_dir" ]] || return 0

  local dp_output
  dp_output=$("$DISPLAYPLACER" list 2>/dev/null)

  _dep_check_profile() {
    local profile_path="$1"
    local name
    name=$(basename "$profile_path")
    if [[ -f "$profile_path/match.ids" ]]; then
      local all_match=1
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        echo "$dp_output" | grep -q "$id" || { all_match=0; break; }
      done < "$profile_path/match.ids"
      [[ $all_match -eq 1 ]] && { echo "$name"; return 0; }
    elif [[ -f "$profile_path/match.attrs" ]]; then
      _match_attrs_profile "$profile_path" && { echo "$name"; return 0; }
    fi
    return 1
  }

  # Home is the default — always tried first
  if [[ -d "$profiles_dir/home" ]]; then
    _dep_check_profile "$profiles_dir/home" && return 0
  fi

  # All other profiles, alphabetically
  for profile_path in "$profiles_dir"/*/; do
    [[ -d "$profile_path" ]] || continue
    [[ $(basename "$profile_path") == "home" ]] && continue
    _dep_check_profile "$profile_path" && return 0
  done
  return 0
}

# ── fix_display_profile ────────────────────────────────────────────────────────
# Applies the display arrangement for a named profile. If display.args contains
# DISP_N placeholders, resolves them to current persistent IDs (matched by
# contextual ID order, consistent with how the profile was captured).
fix_display_profile() {
  local name="$1"
  local profile_dir="$_LIB_DIR/profiles/$name"
  local args_file="$profile_dir/display.args"

  if [[ ! -f "$args_file" ]]; then
    log "WARNING: No display.args found for profile '$name'."
    return 1
  fi
  if [[ ! -x "$DISPLAYPLACER" ]]; then
    log "WARNING: displayplacer not found — skipping display restore."
    return 1
  fi

  local -a final_args=()

  if grep -q "DISP_[0-9]" "$args_file"; then
    # Resolve DISP_N → current persistent IDs, sorted by contextual ID
    mapfile -t _fdp_blocks < <(_parse_disp_blocks | sort -t'|' -k1,1n)
    local -a ordered_pids
    local idx=0
    for b in "${_fdp_blocks[@]}"; do
      IFS='|' read -r _cid pid _dtype _dres <<< "$b"
      ordered_pids[$idx]="$pid"
      (( idx++ ))
    done

    while IFS= read -r arg; do
      [[ -z "$arg" ]] && continue
      local new_arg="$arg"
      for (( i=0; i<${#ordered_pids[@]}; i++ )); do
        new_arg="${new_arg//DISP_${i}/${ordered_pids[$i]}}"
      done
      final_args+=("$new_arg")
    done < "$args_file"
  else
    while IFS= read -r arg; do
      [[ -n "$arg" ]] && final_args+=("$arg")
    done < "$args_file"
  fi

  "$DISPLAYPLACER" "${final_args[@]}" \
    && log "Display profile '$name' applied." \
    || log "WARNING: displayplacer failed for profile '$name'."
}
