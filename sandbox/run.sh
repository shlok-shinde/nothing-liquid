#!/usr/bin/env bash
# Launch the fork in a NESTED Hyprland window with an isolated HOME.
REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LINK="${NL_LINK:-$XDG_RUNTIME_DIR/nothing-liquid}"; ln -sfn "$REAL_ROOT" "$LINK"; ROOT="$LINK"
REAL_HOME="$HOME" "$ROOT/sandbox/mkhome.sh" >/dev/null
H="$ROOT/sandbox/home"
export REAL_HOME="$HOME"
export HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_CACHE_HOME="$H/.cache" XDG_DATA_HOME="$H/.local/share" XDG_STATE_HOME="$H/.local/state"
export PATH="$ROOT/sandbox/shims:$PATH"
export HYPRLAND_NO_SD_VARS=1
unset HYPRLAND_INSTANCE_SIGNATURE
exec dbus-run-session -- Hyprland -c "$H/.config/hypr/hyprland.lua"
