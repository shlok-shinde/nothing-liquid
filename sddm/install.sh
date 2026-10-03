#!/usr/bin/env bash
# Nothing Liquid login screen (SDDM). The theme lives in sddm/nothing-liquid;
# this assembles it with the shell's glass (component + compiled shader), your
# wallpaper and fonts (SDDM runs as its own user and can't read your home),
# installs it to /usr/share/sddm/themes/nothing-liquid and makes it current.
#
#   sddm/install.sh              install (asks for sudo) and switch to it
#   sddm/install.sh --preview    try it in a window first; installs nothing
#   sddm/install.sh --uninstall  switch back to the theme you had and remove it
#
# Your wallpaper is taken from the shell's config; pass another image to use that.
# The glass follows your current light or dark mode: reinstall after switching.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
II="$ROOT/dots/dots/.config/quickshell/ii"
DEST=/usr/share/sddm/themes/nothing-liquid
CONF=/etc/sddm.conf
SHELL_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/illogical-impulse/config.json"

say() { printf '\033[1m·\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!\033[0m %s\n' "$*" >&2; exit 1; }

current_theme() { sed -n 's/^Current=//p' "$CONF" 2>/dev/null | tail -1; }

if [[ "${1:-}" == "--uninstall" ]]; then
  previous="$(cat "$DEST/.previous-theme" 2>/dev/null || true)"
  [[ -n "$previous" ]] || die "don't know which theme to go back to ($DEST/.previous-theme is missing)"
  say "switching the login screen back to $previous"
  sudo sed -i "s/^Current=.*/Current=$previous/" "$CONF"
  sudo rm -f /etc/sddm.conf.d/10-nothing-liquid.conf
  sudo rm -rf "$DEST"
  say "done"
  exit 0
fi

PREVIEW=0
[[ "${1:-}" == "--preview" ]] && { PREVIEW=1; shift; }

# ── assemble ────────────────────────────────────────────────────────────────
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -r "$HERE/nothing-liquid/." "$STAGE/"
mkdir -p "$STAGE/components" "$STAGE/shaders" "$STAGE/fonts"
cp "$II/modules/common/widgets/LiquidGlassEffect.qml" "$STAGE/components/"
cp "$II/modules/common/shaders/liquidglass.frag.qsb" "$STAGE/shaders/"

font_file() { fc-match -f '%{file}' "$1" 2>/dev/null; }
dots="$(font_file 'Doto:style=Black')"; [[ "$dots" == *[Dd]oto* ]] || dots="$(font_file 'monospace')"
clock="$(font_file 'Google Sans Flex')"; [[ "$clock" == *[Gg]oogle* ]] || clock="$(font_file 'sans-serif:weight=black')"
cp "$dots" "$STAGE/fonts/Doto.ttf"
cp "$clock" "$STAGE/fonts/Clock.ttf"

setting() { # key from the shell's config.json, or empty
  python3 - "$SHELL_CONF" "$1" <<'EOF' 2>/dev/null || true
import json, sys
c = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    c = c.get(k, {}) if isinstance(c, dict) else {}
print(c if isinstance(c, str) else "")
EOF
}
wall="${1:-}"
if [[ -z "$wall" ]]; then
  wall="$(setting background.wallpaperPath)"
  case "$wall" in *.mp4|*.webm|*.mkv|*.avi|*.mov) wall="$(setting background.thumbnailPath)" ;; esac
fi
[[ -f "$wall" ]] || die "no wallpaper image to use (pass one: sddm/install.sh /path/to/image)"
if command -v magick >/dev/null; then
  magick "$wall" -resize '2560x2560>' -quality 92 "$STAGE/background.jpg"
else
  cp "$wall" "$STAGE/background.jpg"
fi

timefmt="$(setting time.format)"
[[ -n "$timefmt" ]] && sed -i "s|^timeFormat=.*|timeFormat=$timefmt|" "$STAGE/theme.conf"

# Light or dark, as the desktop is now (the shell's generated colours)
mode="$(python3 - "${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/user/generated/colors.json" <<'EOF' 2>/dev/null || true
import json, sys
bg = json.load(open(sys.argv[1]))["background"].lstrip("#")
r, g, b = (int(bg[i:i + 2], 16) / 255 for i in (0, 2, 4))
print("light" if 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5 else "dark")
EOF
)"
[[ -n "$mode" ]] && sed -i "s|^mode=.*|mode=$mode|" "$STAGE/theme.conf"

if ((PREVIEW)); then
  say "preview: close the window to quit (it is fullscreen: your close-window key); logging in does nothing here"
  sddm-greeter-qt6 --test-mode --theme "$STAGE"
  exit 0
fi

# ── install ─────────────────────────────────────────────────────────────────
previous="$(current_theme)"
# Reinstalling: the theme to go back to is the one recorded the first time
[[ "$previous" == nothing-liquid ]] && previous="$(cat "$DEST/.previous-theme" 2>/dev/null || true)"
say "installing the theme to $DEST (sudo)"
sudo rm -rf "$DEST"
sudo mkdir -p "$DEST"
sudo cp -r "$STAGE/." "$DEST/"
[[ -n "$previous" ]] && echo "$previous" | sudo tee "$DEST/.previous-theme" >/dev/null
sudo chmod -R a+rX "$DEST"

say "making it the login screen (undo goes back to: ${previous:-the default})"
if grep -q '^Current=' "$CONF" 2>/dev/null; then
  sudo sed -i 's/^Current=.*/Current=nothing-liquid/' "$CONF"
else
  printf '[Theme]\nCurrent=nothing-liquid\n' | sudo tee /etc/sddm.conf.d/10-nothing-liquid.conf >/dev/null
fi
say "done. You'll see it at the next login (undo: sddm/install.sh --uninstall)"
