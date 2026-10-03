#!/usr/bin/env bash
# After run.sh: find the nested instance, park its window on ws 9 of the real session,
# and add a 1920x1080 headless output for screenshots.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REAL="$HYPRLAND_INSTANCE_SIGNATURE"
for i in $(seq 1 60); do N=$(hyprctl instances -j | python3 -c "import json,sys; r=[i['instance'] for i in json.load(sys.stdin) if i['instance']!='$REAL']; print(r[-1] if r else '')"); [ -n "$N" ] && break; sleep 0.25; done
[ -z "$N" ] && { echo "no nested instance"; exit 1; }
echo "$N" > "$ROOT/sandbox/logs/nested-sig"
for i in $(seq 1 60); do A=$(hyprctl -i "$REAL" clients -j | python3 -c "import json,sys; r=[c['address'] for c in json.load(sys.stdin) if c['class']=='aquamarine' and c['workspace']['id']!=9]; print(r[0] if r else '')"); [ -n "$A" ] && break; sleep 0.25; done
[ -n "$A" ] && hyprctl -i "$REAL" dispatch "hl.dsp.window.move({ workspace = 9, follow = false, window = \"address:$A\" })" >/dev/null
hyprctl -i "$N" eval 'hl.monitor({ output = "HEADLESS-2", mode = "1920x1080@60", position = "3000x0", scale = 1 })' >/dev/null
hyprctl -i "$N" output create headless HEADLESS-2 >/dev/null
sleep 2
echo "nested=$N window=$A"; hyprctl -i "$N" monitors | grep -E "^Monitor"
