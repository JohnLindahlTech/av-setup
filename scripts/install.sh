#!/usr/bin/env bash
# install.sh — one-time setup for the AV restore system.
# Run from any location; paths are resolved relative to this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BREW=/opt/homebrew/bin/brew

# ── 1. Install dependencies ───────────────────────────────────────────────────
echo "[install] Installing Homebrew dependencies from Brewfile..."
"$BREW" bundle --file="$REPO_DIR/Brewfile"
echo "[install] Dependencies installed."

# ── 1b. Bootstrap av.conf from example if not present ─────────────────────────
if [ ! -f "$SCRIPT_DIR/av.conf" ]; then
  cp "$SCRIPT_DIR/av.conf.example" "$SCRIPT_DIR/av.conf"
  echo ""
  echo "[install] Created av.conf from template — edit it with your audio device names before continuing."
  echo "  Run: SwitchAudioSource -a   to list available devices"
  echo "  Then edit: $SCRIPT_DIR/av.conf"
  echo ""
  exit 1
fi

# ── 2. Capture current display arrangement ────────────────────────────────────
echo "[install] Capturing display arrangement into profiles/home/..."
"$SCRIPT_DIR/capture-displays.sh"
echo "[install] Display arrangement captured."

# ── 3. Install wake hook ──────────────────────────────────────────────────────
echo "[install] Installing wake hook to ~/.wakeup..."
cat > "$HOME/.wakeup" << EOF
#!/usr/bin/env bash
exec "$SCRIPT_DIR/wake-hook.sh" "\$@"
EOF
chmod +x "$HOME/.wakeup"
echo "[install] Wake hook installed at $HOME/.wakeup"

# ── 4. Add sudoers entry for passwordless coreaudiod restart ─────────────────
SUDOERS_FILE=/etc/sudoers.d/coreaudiod-restart
SUDOERS_LINE="$(whoami) ALL=(root) NOPASSWD: /usr/bin/killall coreaudiod"

echo "[install] Adding sudoers entry for coreaudiod restart (requires sudo)..."
echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 440 "$SUDOERS_FILE"
# Validate the sudoers file is syntactically correct
sudo visudo -cf "$SUDOERS_FILE" \
  && echo "[install] Sudoers entry added: $SUDOERS_FILE" \
  || { echo "[install] ERROR: sudoers file invalid — removing."; sudo rm "$SUDOERS_FILE"; exit 1; }

# ── 5. Start sleepwatcher service ─────────────────────────────────────────────
echo "[install] Starting sleepwatcher service..."
"$BREW" services start sleepwatcher \
  && echo "[install] sleepwatcher service started." \
  || echo "[install] WARNING: sleepwatcher service start failed — check 'brew services list'."

# ── 6. Install fix command ────────────────────────────────────────────────────
mkdir -p "$HOME/.local/bin"
chmod +x "$SCRIPT_DIR/fix.sh"
ln -sf "$SCRIPT_DIR/fix.sh" "$HOME/.local/bin/fix"
echo "[install] fix command installed at ~/.local/bin/fix"
echo "[install] Ensure ~/.local/bin is in your PATH."

echo ""
echo "[install] Done. Verify with:"
echo "  brew services list | grep sleepwatcher"
echo "  fix               (runs all AV fixes interactively)"
echo "  cat ~/.local/log/wake-av.log  (after next wake from sleep)"
