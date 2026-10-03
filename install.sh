#!/usr/bin/env bash
# Nothing Liquid — install onto an existing end-4 (illogical-impulse) setup.
#
#   ./install.sh            apply (backs up everything it replaces)
#   ./install.sh --dry-run  show what would change, change nothing
#
# What it does:
#   1. builds the glass plugin (hyprglass fork, branch nothing-liquid) if needed, against
#      your Hyprland's headers, and
#      installs a stripped copy (~1 MB) to ~/.local/lib/nothing-liquid/hyprglass.so
#   2. copies the files the dots fork changes into ~/.config, refusing to touch
#      any file you have edited yourself (unless --force). Running it again
#      updates an earlier install.
#   3. turns on appearance.liquidGlass in ~/.config/illogical-impulse/config.json
#   4. swaps in the new plugin, reloads Hyprland, restarts the shell and has
#      kitty re-read its config
# Your files as they were before the first install are kept in
# ~/.local/share/nothing-liquid/original. Undo with ./uninstall.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTS="$ROOT/dots"
PLUGIN_SRC="$ROOT/hyprglass"
# What to install: the dots fork's checked-out commit, or another ref named in
# that repo's own git config (e.g. a branch with your personal tweaks on top):
#   git -C dots config nothing-liquid.installRef my-branch
REF="${NL_REF:-$(git -C "$DOTS" config --get nothing-liquid.installRef 2>/dev/null || echo HEAD)}"
# The fork point: the end-4 commit just before the fork's first commit.
FIRST="$(git -C "$DOTS" log --reverse --format=%H --grep='^ii: add appearance.liquidGlass' "$REF" | head -1)"
[[ -n "$FIRST" ]] || { echo "dots/ is not the nothing-liquid fork (no 'ii: add appearance.liquidGlass' commit in $REF)"; exit 1; }
BASE_COMMIT="$(git -C "$DOTS" rev-parse "$FIRST^")"
STAMP="$(date +%Y%m%d-%H%M%S)"
STATE="$HOME/.local/share/nothing-liquid"
BACKUP="$STATE/backup-$STAMP"   # this run's backup
ORIG="$STATE/original"          # before the first install; what uninstall puts back
SO="$HOME/.local/lib/nothing-liquid/hyprglass.so"
DRY=0; FORCE=0
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; --force) FORCE=1 ;; *) echo "unknown option $a"; exit 2 ;; esac; done

say()  { printf '\033[1m·\033[0m %s\n' "$*"; }
warn() { printf '\033[31m·\033[0m %s\n' "$*"; }
run()  { if ((DRY)); then echo "  would: $*"; else "$@"; fi; }

# ── 0. sanity ────────────────────────────────────────────────────────────────
have="$(Hyprland --version 2>/dev/null | sed -n 's/^Hyprland \([0-9.]*\).*/\1/p' | head -1)"
case "$have" in
  0.56.*) ;;
  *) warn "this targets Hyprland 0.56.x (its Lua config and plugin API); found '${have:-none}'"
     ((FORCE)) || exit 1 ;;
esac
command -v make >/dev/null && [[ -d /usr/include/hyprland ]] || {
  warn "building the plugin needs make, a C++ compiler and Hyprland's headers (/usr/include/hyprland)"; exit 1; }

# ── 1. plugin ────────────────────────────────────────────────────────────────
# Rebuilt from scratch whenever Hyprland changes (the plugin is ABI-bound to it),
# and incrementally when its sources change.
BUILT_FOR="$ROOT/.hyprglass-built-for"
if [[ "$(cat "$BUILT_FOR" 2>/dev/null)" != "$have" ]]; then
  say "building the glass plugin for Hyprland $have"
  run make -C "$PLUGIN_SRC" clean >/dev/null
  run make -C "$PLUGIN_SRC" -j"$(nproc)"
  ((DRY)) || echo "$have" > "$BUILT_FOR"
elif [[ ! -f "$PLUGIN_SRC/hyprglass.so" || -n "$(find "$PLUGIN_SRC/src" -newer "$PLUGIN_SRC/hyprglass.so" -print -quit)" ]]; then
  say "building the glass plugin"
  run make -C "$PLUGIN_SRC" -j"$(nproc)"
fi
say "installing plugin -> ~/.local/lib/nothing-liquid/hyprglass.so"
run mkdir -p "$HOME/.local/lib/nothing-liquid"
run strip --strip-debug -o "$SO.new" "$PLUGIN_SRC/hyprglass.so"
run mv -f "$SO.new" "$SO"   # a rename, never an overwrite: the running Hyprland has the old one mapped

# ── 2. dotfiles ──────────────────────────────────────────────────────────────
# The first install (before original/ existed) kept the originals in its backup.
ORIG_SEEN="$ORIG"   # where originals are looked up (a dry run has not copied them yet)
if [[ ! -d "$ORIG" && -f "$STATE/last-backup" && -d "$(cat "$STATE/last-backup")" ]]; then
  say "keeping the first install's backup as the originals"
  run cp -a "$(cat "$STATE/last-backup")" "$ORIG"
  ((DRY)) && ORIG_SEEN="$(cat "$STATE/last-backup")"
fi

# A live file is ours to replace if it is the fork point's version (untouched
# since you forked) or any version this fork ever shipped (an earlier install).
known_version() {
  local f="$1" live="$2" c
  git -C "$DOTS" show "$BASE_COMMIT:$f" 2>/dev/null | cmp -s - "$live" && return 0
  for c in $(git -C "$DOTS" rev-list "$BASE_COMMIT..$REF" -- "$f"); do
    git -C "$DOTS" show "$c:$f" 2>/dev/null | cmp -s - "$live" && return 0
  done
  return 1
}

mapfile -t files < <(git -C "$DOTS" diff --name-only --diff-filter=d "$BASE_COMMIT".."$REF" -- dots/)
blocked=0
for f in "${files[@]}"; do
  rel="${f#dots/}"; live="$HOME/$rel"
  if [[ -e "$live" ]] && ! known_version "$f" "$live"; then
    warn "you have edited ~/$rel yourself"
    blocked=1
  fi
done
if ((blocked && !FORCE)); then
  warn "refusing to overwrite edited files; merge them by hand or rerun with --force (they still get backed up)"
  exit 1
fi

for f in "${files[@]}"; do
  rel="${f#dots/}"; live="$HOME/$rel"
  git -C "$DOTS" show "$REF:$f" | cmp -s - "$live" 2>/dev/null && continue   # already up to date
  if [[ -e "$live" ]]; then
    run mkdir -p "$(dirname "$BACKUP/$rel")"
    run cp -a "$live" "$BACKUP/$rel"
  fi
  # the first time we replace (or add) a file, remember what was there before
  if [[ ! -e "$ORIG_SEEN/$rel" && ! -e "$ORIG_SEEN/.new/$rel" ]]; then
    if [[ -e "$live" ]]; then
      run mkdir -p "$(dirname "$ORIG/$rel")"; run cp -a "$live" "$ORIG/$rel"
    else
      run mkdir -p "$(dirname "$ORIG/.new/$rel")"; run touch "$ORIG/.new/$rel"
    fi
  fi
  run mkdir -p "$(dirname "$live")"
  if ((DRY)); then echo "  would: write $REF:$f to $live"; else git -C "$DOTS" show "$REF:$f" > "$live"; fi
  say "updated ~/$rel"
done

# ── 3. shell config ──────────────────────────────────────────────────────────
CFG="$HOME/.config/illogical-impulse/config.json"
if [[ -f "$CFG" ]]; then
  run mkdir -p "$BACKUP/.config/illogical-impulse"
  run cp -a "$CFG" "$BACKUP/.config/illogical-impulse/config.json"
  if [[ ! -e "$ORIG_SEEN/.config/illogical-impulse/config.json" ]]; then
    run mkdir -p "$ORIG/.config/illogical-impulse"; run cp -a "$CFG" "$ORIG/.config/illogical-impulse/config.json"
  fi
  if ((DRY)); then
    echo "  would: set appearance.liquidGlass.enable = true in $CFG"
  else
    python3 - "$CFG" <<'EOF'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
glass = cfg.setdefault("appearance", {}).setdefault("liquidGlass", {})
glass.setdefault("tint", 0.10)
glass.setdefault("contentTransparency", 0.78)
glass.setdefault("accentColor", "#D71921")
glass["enable"] = True
json.dump(cfg, open(path, "w"), indent=2)
EOF
    say "enabled appearance.liquidGlass"
  fi
fi

((DRY)) && { say "dry run: nothing changed"; exit 0; }
[[ -d "$BACKUP" ]] && echo "$BACKUP" > "$STATE/last-backup"

# ── 4. apply ─────────────────────────────────────────────────────────────────
say "reloading Hyprland and the glass plugin, restarting the shell"
if hyprctl plugin list 2>/dev/null | grep -q '^Plugin hyprglass'; then
  # already running an older build: swap it (a config reload alone keeps the old one)
  hyprctl plugin unload "$SO" >/dev/null 2>&1 || true
  hyprctl plugin load "$SO" >/dev/null 2>&1 || true
fi
hyprctl reload >/dev/null || true
qs -c ii kill >/dev/null 2>&1 || true
setsid -f qs -c ii >/dev/null 2>&1 || true
pkill -USR1 -x kitty 2>/dev/null || true   # open kitty windows re-read kitty.conf (see-through background)
say "done. Windows are glass where apps draw see-through: kitty and foot now, Dolphin and other Qt apps once reopened."
say "SUPER+H minimizes into the dock, SUPER+SHIFT+H brings it back. Click glass to light it."
say "originals: $ORIG   (undo: ./uninstall.sh)"

# ── 5. does light/dark reach the apps? ──────────────────────────────────────
# The shell's switch sets GNOME's colour scheme. Firefox, Electron and GTK4 apps
# read it through the GTK portal; a session-wide GTK_THEME pins GTK apps to one
# theme (and to Adwaita's light one when that theme isn't installed).
if [[ "$(systemctl --user is-enabled xdg-desktop-portal-gtk.service 2>/dev/null)" == masked ]]; then
  warn "xdg-desktop-portal-gtk is masked, so apps never hear light/dark. Fix: systemctl --user unmask xdg-desktop-portal-gtk.service"
fi
if [[ -n "${GTK_THEME:-}" ]]; then
  warn "GTK_THEME=$GTK_THEME is set for the whole session (look in /etc/environment), so GTK apps ignore light/dark. Remove it and log in again"
fi
