#!/usr/bin/env bash
# Nothing Liquid — undo ./install.sh: put back your files as they were before
# the first install (~/.local/share/nothing-liquid/original), or from a backup
# directory passed as the first argument.
set -euo pipefail

say() { printf '\033[1m·\033[0m %s\n' "$*"; }

STATE="$HOME/.local/share/nothing-liquid"
if [[ -n "${1:-}" ]]; then
  BACKUP="$1"
elif [[ -d "$STATE/original" ]]; then
  BACKUP="$STATE/original"
else
  BACKUP="$(cat "$STATE/last-backup" 2>/dev/null || true)"   # installs from before original/ existed
fi
[[ -d "$BACKUP" ]] || { echo "no backup found (pass its path as the first argument)"; exit 1; }

# files that existed before: put the originals back
while IFS= read -r -d '' f; do
  rel="${f#"$BACKUP"/}"
  [[ "$rel" == .new/* ]] && continue
  mkdir -p "$(dirname "$HOME/$rel")"
  cp -a "$f" "$HOME/$rel"
  say "restored ~/$rel"
done < <(find "$BACKUP" -type f -print0)

# files the install added: remove them
if [[ -d "$BACKUP/.new" ]]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$BACKUP/.new"/}"
    rm -f "$HOME/$rel"
    say "removed ~/$rel"
  done < <(find "$BACKUP/.new" -type f -print0)
fi

SO="$HOME/.local/lib/nothing-liquid/hyprglass.so"
hyprctl plugin unload "$SO" >/dev/null 2>&1 || true
rm -f "$SO"
say "removed the plugin"

# a later install starts from whatever you have then
[[ "$BACKUP" == "$STATE/original" ]] && mv "$STATE/original" "$STATE/uninstalled-$(date +%Y%m%d-%H%M%S)"

hyprctl reload >/dev/null || true
qs -c ii kill >/dev/null 2>&1 || true
setsid -f qs -c ii >/dev/null 2>&1 || true
pkill -USR1 -x kitty 2>/dev/null || true
say "done"
