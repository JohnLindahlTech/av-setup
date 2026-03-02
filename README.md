# AV Setup — AV Restore Scripts

Restores display arrangement and audio defaults after connecting monitors or waking from sleep.
Auto-runs on wake via `sleepwatcher`.

## Problem

- External displays daisy-chained via DisplayPort: arrangement drifts after wake/reconnect
- USB audio input disappears from macOS after wake — a USB re-enumeration bug where
  `coreaudiod` misses the device coming back online

## Dependencies

Installed automatically by `install.sh` via `Brewfile`:

| Tool              | Purpose                                                |
| ----------------- | ------------------------------------------------------ |
| `displayplacer`   | Captures and restores display resolution + arrangement |
| `switchaudio-osx` | Sets macOS default audio input/output from the CLI     |
| `sleepwatcher`    | Runs `~/.wakeup` on every wake from sleep              |

## Setup

On first run, `install.sh` creates `scripts/av.conf` from the example template and then
exits so you can fill in your device names:

```sh
# List available audio devices
SwitchAudioSource -a

# Edit av.conf with your device names
nano scripts/av.conf
```

`scripts/av.conf` is gitignored — it holds your machine-specific device names. See
`scripts/av.conf.example` for the expected format. It contains two variables:
`AUDIO_OUTPUT` and `AUDIO_INPUT`.

## Quick Start

```sh
cd av-setup
bash scripts/install.sh
```

This does everything in one shot — see [What install.sh does](#what-installsh-does) below.

## File Layout

```
av-setup/
├── Brewfile
├── README.md
└── scripts/
    ├── av.conf.example       # template; copied to av.conf on first install
    ├── av.conf               # gitignored; your device names
    ├── capture-displays.sh   # snapshots home display arrangement
    ├── capture-profile.sh    # creates additional named profiles
    ├── fix.sh                # on-demand recovery CLI (linked to ~/.local/bin/fix)
    ├── install.sh            # one-time setup
    ├── recovery-lib.sh       # shared functions (sourced by fix.sh + wake-hook.sh)
    ├── wake-hook.sh          # runs on wake from sleep (~/.wakeup)
    └── profiles/
        └── home/
            ├── display.args  # display arrangement args for displayplacer
            └── match.ids     # persistent display IDs used for profile detection
```

## What install.sh Does

1. `brew bundle` — installs `displayplacer`, `switchaudio-osx`, `sleepwatcher`
2. Checks for `av.conf` — creates it from `av.conf.example` if missing (then exits so you can edit it)
3. Runs `capture-displays.sh` — snapshots current display arrangement into `profiles/home/`
4. Installs `~/.wakeup` as a wrapper that delegates to `wake-hook.sh` (sleepwatcher's convention)
5. Adds `/etc/sudoers.d/coreaudiod-restart` — allows passwordless restart of `coreaudiod`
6. Starts `sleepwatcher` as a brew service
7. Links `fix.sh` → `~/.local/bin/fix` for on-demand use

## Manual Use: the `fix` command

`install.sh` links `fix.sh` to `~/.local/bin/fix`. Ensure `~/.local/bin` is in your `PATH`.

```
Usage: fix [display [<profile>]|audio|mic|deck|all]
  display          Auto-detect and restore monitor arrangement
  display <name>   Force a specific named profile
  audio            Set audio output device
  mic              Recover microphone input (restarts coreaudiod if needed)
  deck             Relaunch Stream Deck
  all              Run all of the above (default)
```

`all` is the default — running `fix` with no arguments runs every subcommand in sequence.
Output is printed to the terminal and also appended to `~/.local/log/wake-av.log`.

If you rearrange your displays, re-capture the new arrangement:

```sh
bash scripts/capture-displays.sh
```

This updates `profiles/home/display.args` and `profiles/home/match.ids`. No other steps are required.

## Wake Behavior

On every wake from sleep, `~/.wakeup` runs automatically:

1. Waits 8 seconds for USB buses to settle
2. Checks all display profiles (home first, then others alphabetically) for a match
3. If a profile matches: restores display arrangement, audio output, microphone, and Stream Deck
4. If no profile matches: exits immediately with no side effects

All results are logged to `~/.local/log/wake-av.log`.

## Scenarios

### Home (all external monitors connected)

`wake-hook.sh` detects all monitors via their stable display IDs and runs the full AV restore:
display arrangement, audio output, and audio input recovery (including `coreaudiod`
restart if the input device is missing). Stream Deck is also relaunched to recover its
USB connection.

### Away / work (any other monitor setup)

`wake-hook.sh` finds no matching profile and exits immediately with
no side effects — no audio glitch, no `coreaudiod` restart, no failed commands. The log entry
reads: `No display profile matched — skipping AV restore.`

### How detection works

Each display has a stable "persistent screen id" derived from EDID + port. These IDs are captured
by `capture-displays.sh` and saved to `scripts/profiles/home/match.ids`. On wake (after the 8s USB
settle), `displayplacer list` reports all connected displays. If every ID in `match.ids`
appears in that output, the home profile is confirmed. `home` is always checked first; any
additional profiles are checked alphabetically by name.

Audio devices are intentionally **not** used for detection: the USB audio input may be temporarily
absent even at home (which is exactly the problem this script fixes), so it cannot serve as a
reliable signal.

### Stream Deck recovery

`fix deck` (and `fix all`) relaunches the Elgato Stream Deck application if it is currently
running. This recovers the USB connection that is often lost after wake from sleep. If Stream
Deck is not installed or is not running, the step is silently skipped.

### Re-running capture-displays.sh

If you rearrange, replace, or add monitors, re-run:

```sh
bash scripts/capture-displays.sh
```

This updates both `profiles/home/display.args` (the restore command) and
`profiles/home/match.ids` (the detection file). No other steps are required.

## Adding Extra Profiles

`capture-profile.sh` creates profiles beyond the default `home` profile. Use this when you
regularly connect to a second known display setup (e.g. a work dock) and want automatic
detection and restoration there too.

```sh
# Capture a new profile matched by persistent display IDs (default)
bash scripts/capture-profile.sh work-dell

# Capture a profile matched by display attributes (resolution, type, brand, model)
bash scripts/capture-profile.sh work-dell --by attrs

# Include brand and model in the attribute match (slow — calls system_profiler)
bash scripts/capture-profile.sh work-dell --by attrs --with-brand-model
```

Profiles are stored in `scripts/profiles/<name>/`. ID-based profiles contain `match.ids`
and `display.args`. Attribute-based profiles contain `match.attrs` and `display.args`
(with `DISP_N` placeholders substituted for the current persistent IDs at apply time).

Apply a profile manually at any time:

```sh
fix display work-dell
```

## Verification

```sh
# Confirm sleepwatcher is running
brew services list | grep sleepwatcher

# Confirm fix is on PATH
which fix

# Test all AV fixes interactively
fix

# Check current audio defaults
SwitchAudioSource -c -t output
SwitchAudioSource -c -t input

# After a sleep/wake cycle (~15s after waking)
cat ~/.local/log/wake-av.log
```
