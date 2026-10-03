#!/usr/bin/env bash
# Hot-swap a fresh plugin build into the nested session. The config loads the
# plugin from the sandbox home, so swap the file there and reload that path.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N=$(cat "$ROOT/sandbox/logs/nested-sig")
SO="$ROOT/sandbox/home/.local/lib/nothing-liquid/hyprglass.so"
hyprctl -i "$N" plugin unload "$SO" >/dev/null 2>&1
cp "$ROOT/hyprglass/hyprglass.so" "$SO.new" && mv -f "$SO.new" "$SO"
hyprctl -i "$N" plugin load "$SO"
[ -f "$ROOT/sandbox/glass.lua" ] && hyprctl -i "$N" eval "$(cat "$ROOT/sandbox/glass.lua")" >/dev/null
echo "configerrors: [$(hyprctl -i "$N" configerrors)]"
