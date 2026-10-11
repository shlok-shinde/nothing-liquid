#!/usr/bin/env bash
# Nothing Liquid: get the installer and open it. Paste into a terminal:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/shlok-shinde/nothing-liquid/nvidia/installer/get.sh)
#
# It installs what the installer window needs (git, GTK 4 and libadwaita for
# Python), downloads Nothing Liquid to ~/.local/share/nothing-liquid/repo (or
# updates it there), adds "Nothing Liquid" to your apps menu and opens the
# installer. Nothing else changes until you choose to install in that window.
set -euo pipefail

REPO="${NL_REPO:-https://github.com/shlok-shinde/nothing-liquid.git}"
BRANCH="${NL_BRANCH:-nvidia}"  # (this branch: NVIDIA RTX laptops)
DEST="${NL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/nothing-liquid/repo}"

say()  { printf '\033[1;31m●\033[0m %s\n' "$*"; }
stop() { printf '\033[1;31m●\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || stop "Run this as yourself, not with sudo: it asks for your password when it needs it."
command -v pacman >/dev/null || stop "Nothing Liquid installs on Arch Linux and distros built on it (EndeavourOS, CachyOS, Garuda, Manjaro). This system has no pacman."
[[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]] || stop "Run this from a terminal on your desktop: the installer is a window."

need=()
command -v git >/dev/null || need+=(git)
python3 -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")' 2>/dev/null \
  || need+=(python python-gobject gtk4 libadwaita)
if ((${#need[@]})); then
  say "The installer needs a few small packages first: ${need[*]}"
  say "Type your password when asked (it doesn't show as you type), then press Enter."
  sudo pacman -S --needed --noconfirm "${need[@]}" \
    || stop "Couldn't install them. If your system hasn't been updated in a while, run: sudo pacman -Syu   then this command again."
fi

if [[ -d "$DEST/.git" ]]; then
  say "Updating Nothing Liquid in $DEST"
  git -C "$DEST" pull --ff-only --quiet && git -C "$DEST" submodule update --init --recursive --quiet \
    || say "Couldn't update it (no internet?): opening the copy you have."
else
  say "Downloading Nothing Liquid to $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone -b "$BRANCH" --recurse-submodules --quiet "$REPO" "$DEST"
fi

apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$apps"
# Named as the app (its Wayland app id), so docks find its icon
cat > "$apps/io.github.shlok_shinde.NothingLiquid.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Nothing Liquid
Comment=Install, update or remove the Nothing Liquid desktop
Exec=python3 "$DEST/installer/nothing-liquid-installer"
Icon=$DEST/installer/icon.svg
Terminal=false
Categories=System;Settings;
EOF

say "Opening the installer. You can close this terminal; it's also in your apps menu as Nothing Liquid."
setsid -f python3 "$DEST/installer/nothing-liquid-installer" >/dev/null 2>&1
