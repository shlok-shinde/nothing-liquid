#!/usr/bin/env bash
# After run.sh: the comparison scene. kitty and Dolphin as floating windows
# (both draw see-through backgrounds, so they are glass), dock and bar as usual.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/sandbox/post.sh" >/dev/null || exit 1
N=$(cat "$ROOT/sandbox/logs/nested-sig")
for i in $(seq 1 60); do [ "$(hyprctl -i "$N" layers | grep -c 'quickshell:bar')" -ge 1 ] && break; sleep 2; done
"$ROOT/sandbox/reload-plugin.sh" >/dev/null
d(){ hyprctl -i "$N" dispatch "$1" >/dev/null; }
MX=$(hyprctl -i "$N" monitors -j | python3 -c "import json,sys; print([m['x'] for m in json.load(sys.stdin) if m['name']=='HEADLESS-2'][0])")
addr(){ hyprctl -i "$N" clients -j | python3 -c "import json,sys; r=[c['address'] for c in json.load(sys.stdin) if c['class']=='$1']; print(r[-1] if r else '')"; }
place(){ # class x y w h
  local A=""; for i in $(seq 1 40); do A=$(addr "$1"); [ -n "$A" ] && break; sleep 0.5; done
  [ -z "$A" ] && { echo "no $1 window"; return; }
  d "hl.dsp.window.fullscreen_state({ internal = 0, client = 0, window = \"address:$A\" })"
  [ "$(hyprctl -i "$N" clients -j | python3 -c "import json,sys; print([c['floating'] for c in json.load(sys.stdin) if c['address']=='$A'][0])")" = True ] || d "hl.dsp.window.float({ action = \"toggle\", window = \"address:$A\" })"
  d "hl.dsp.window.resize({ x = $4, y = $5, \"exact\", window = \"address:$A\" })"
  d "hl.dsp.window.move({ x = $((MX + $2)), y = $3, \"exact\", window = \"address:$A\" })"
  echo "$1 $A"
}
d 'hl.dsp.focus({ monitor = "HEADLESS-2" })'
d "hl.dsp.exec_cmd(\"kitty $ROOT/sandbox/home/demo-card.sh\")"
place kitty 110 120 880 560
d 'hl.dsp.exec_cmd("dolphin /usr/share/wallpapers")'
place org.kde.dolphin 900 320 900 600
