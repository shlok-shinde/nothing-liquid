#!/usr/bin/env bash
# run a command inside the nested session's environment: nenv.sh <cmd...>
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
N=$(cat "$ROOT/sandbox/logs/nested-sig")
P=$(for p in $(pgrep -u "$USER" -x Xwayland; pgrep -u "$USER" -x qs; pgrep -u "$USER" -x quickshell); do tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -q "HYPRLAND_INSTANCE_SIGNATURE=$N" && echo $p && break; done)
[ -z "$P" ] && { echo "no nested client process found" >&2; exit 1; }
set -a; while IFS= read -r -d '' kv; do case "$kv" in HOME=*|XDG_*|PATH=*|WAYLAND_DISPLAY=*|DISPLAY=*|HYPRLAND_INSTANCE_SIGNATURE=*|DBUS_SESSION_BUS_ADDRESS=*|REAL_HOME=*|qsConfig=*) eval "$(printf '%s=%q' "${kv%%=*}" "${kv#*=}")";; esac; done < /proc/$P/environ; set +a
exec "$@"
