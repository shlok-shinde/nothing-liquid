#!/usr/bin/env bash
# Build/refresh an isolated HOME that runs the forked end-4 shell in a nested Hyprland.
# Nothing here writes to the real ~/.config.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # project root (via clean symlink if invoked through one)
H="$ROOT/sandbox/home"; REAL="${REAL_HOME:-/home/$USER}"
mkdir -p "$H/.config" "$H/.local/share" "$H/.local/state/quickshell/user" "$H/.cache" "$H/Pictures"
# 1) dotfiles from the fork. quickshell is a symlink so edits hot-reload; the rest is copied like the installer would.
ln -sfn "$ROOT/dots/dots/.config/quickshell" "$H/.config/quickshell"
for d in hypr matugen kitty fuzzel fontconfig foot wlogout Kvantum; do
  [ -e "$ROOT/dots/dots/.config/$d" ] && { mkdir -p "$H/.config/$d"; cp -rT "$ROOT/dots/dots/.config/$d" "$H/.config/$d"; }
done
# 2) user-specific bits from the real install (read-only copies): shell config, custom hypr overrides, generated colours
mkdir -p "$H/.config/illogical-impulse"
[ -f "$H/.config/illogical-impulse/config.json" ] || cp "$REAL/.config/illogical-impulse/config.json" "$H/.config/illogical-impulse/"
cp -n "$REAL/.config/illogical-impulse/"{installed_true,installed_listfile} "$H/.config/illogical-impulse/" 2>/dev/null || true
cp -rn "$REAL/.config/hypr/custom/." "$H/.config/hypr/custom/" 2>/dev/null || true
[ -d "$H/.local/state/quickshell/user/generated" ] || cp -r "$REAL/.local/state/quickshell/user/generated" "$H/.local/state/quickshell/user/"
cp -n "$REAL/.local/state/quickshell/user/first_run.txt" "$H/.local/state/quickshell/user/" 2>/dev/null || true
for f in hypr/hyprland/colors.lua hypr/hyprlock/colors.conf; do [ -f "$H/.config/$f.sandbox-kept" ] || { cp "$REAL/.config/$f" "$H/.config/$f" 2>/dev/null && touch "$H/.config/$f.sandbox-kept"; } || true; done
cp "$ROOT/dots/dots/.config/darklyrc" "$H/.config/darklyrc"            # Qt style translucency (fork)
[ -f "$H/.config/kdeglobals" ] || cp "$REAL/.config/kdeglobals" "$H/.config/kdeglobals"   # their colour scheme + Darkly
for d in gtk-3.0 gtk-4.0 qt5ct qt6ct; do [ -e "$H/.config/$d" ] || cp -r "$REAL/.config/$d" "$H/.config/$d" 2>/dev/null || true; done
# 3) fonts & icons: reuse the real ones without copying
ln -sfn "$REAL/.local/share/fonts" "$H/.local/share/fonts"
[ -d "$REAL/.local/share/color-schemes" ] && ln -sfn "$REAL/.local/share/color-schemes" "$H/.local/share/color-schemes" || true
[ -d "$REAL/.local/share/icons" ] && ln -sfn "$REAL/.local/share/icons" "$H/.local/share/icons" || true
# 4) the glass plugin where hyprland/liquidglass.lua looks for it
mkdir -p "$H/.local/lib/nothing-liquid"
# copy-then-rename: overwriting a loaded .so in place crashes the Hyprland that has it mapped
[ -f "$ROOT/hyprglass/hyprglass.so" ] && cp "$ROOT/hyprglass/hyprglass.so" "$H/.local/lib/nothing-liquid/hyprglass.so.new" && mv -f "$H/.local/lib/nothing-liquid/hyprglass.so.new" "$H/.local/lib/nothing-liquid/hyprglass.so"
cp "$ROOT/sandbox/demo-card.sh" "$H/demo-card.sh"   # what scene*.sh show in kitty
echo "sandbox home ready: $H"
