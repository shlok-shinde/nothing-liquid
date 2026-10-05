#!/usr/bin/env python3
"""Brightness, volume and mute keys where no desktop is listening for them.

Inside your Hyprland session its own binds handle these keys. At the login
screen (SDDM) and on a text console nothing does, so this small root service
reads the keys straight from the keyboards and acts on them, but only while
no graphical session is in front: it never doubles a step Hyprland takes.

After each change it writes the level to /run/nothing-liquid/login-osd, which
the login screen shows. Standard library only; run by
nothing-liquid-login-keys.service.
"""
import glob
import json
import os
import re
import select
import struct
import subprocess
import time

KEY_MUTE, KEY_VOLUMEDOWN, KEY_VOLUMEUP = 113, 114, 115
KEY_BRIGHTNESSDOWN, KEY_BRIGHTNESSUP, KEY_MICMUTE = 224, 225, 248
KEYS = {KEY_MUTE, KEY_VOLUMEDOWN, KEY_VOLUMEUP, KEY_BRIGHTNESSDOWN, KEY_BRIGHTNESSUP, KEY_MICMUTE}
REPEATS = {KEY_VOLUMEDOWN, KEY_VOLUMEUP, KEY_BRIGHTNESSDOWN, KEY_BRIGHTNESSUP}  # holding the key keeps going
EVENT = struct.Struct("llHHi")  # struct input_event: timeval, type, code, value
EV_KEY = 1

BRIGHTNESS_STEP = 0.05  # like the session's binds (5%)
BRIGHTNESS_FLOOR = 0.02  # never all the way to a black screen
VOLUME_STEP = "2%"
OSD_FILE = "/run/nothing-liquid/login-osd"


def key_capable(event_path):
    """Does this input device have any of our keys? (sysfs capability bitmap)"""
    name = os.path.basename(event_path)
    try:
        with open(f"/sys/class/input/{name}/device/capabilities/key") as f:
            words = f.read().split()
    except OSError:
        return False
    bits = 0
    for word in words:  # most significant long first
        bits = (bits << 64) | int(word, 16)
    return any(bits >> key & 1 for key in KEYS)


def open_devices(devices):
    """Add the keyboards that aren't open yet (unplugged ones drop out when a read fails)."""
    have = set(devices.values())
    for path in sorted(glob.glob("/dev/input/event*")):
        if path not in have and key_capable(path):
            try:
                devices[os.open(path, os.O_RDONLY | os.O_NONBLOCK)] = path
            except OSError:
                pass


_front = (0.0, True)


def desktop_in_front():
    """A graphical user session (Hyprland) is the active one on seat0: its binds have the keys."""
    global _front
    now = time.monotonic()
    if now - _front[0] < 0.5:
        return _front[1]
    graphical = False
    try:
        session = subprocess.run(["loginctl", "show-seat", "seat0", "-p", "ActiveSession", "--value"],
                                 capture_output=True, text=True, timeout=2).stdout.strip()
        if session:
            props = dict(line.split("=", 1) for line in subprocess.run(
                ["loginctl", "show-session", session, "-p", "Class", "-p", "Type"],
                capture_output=True, text=True, timeout=2).stdout.splitlines() if "=" in line)
            graphical = props.get("Class") == "user" and props.get("Type") in ("wayland", "x11", "mir")
    except (OSError, subprocess.SubprocessError):
        graphical = True  # can't tell: stay out of the way
    _front = (now, graphical)
    return graphical


def backlight():
    """The panel's backlight (firmware > platform > raw, as the kernel docs advise)."""
    rank = {"firmware": 0, "platform": 1, "raw": 2}
    found = []
    for path in glob.glob("/sys/class/backlight/*"):
        try:
            with open(f"{path}/type") as f:
                found.append((rank.get(f.read().strip(), 3), path))
        except OSError:
            pass
    return min(found)[1] if found else None


def step_brightness(direction):
    path = backlight()
    if not path:
        return None
    with open(f"{path}/max_brightness") as f:
        top = int(f.read())
    with open(f"{path}/brightness") as f:
        now = int(f.read())
    step = max(1, round(top * BRIGHTNESS_STEP))
    value = min(top, max(max(1, round(top * BRIGHTNESS_FLOOR)), now + direction * step))
    with open(f"{path}/brightness", "w") as f:
        f.write(str(value))
    return {"kind": "brightness", "value": round(100 * value / top)}


def sound_card():
    """The first card with a Master control (the default ALSA device goes through PipeWire,
    which has no server for root)."""
    for card in sorted(glob.glob("/proc/asound/card[0-9]*")):
        index = card.rsplit("card", 1)[1]
        controls = subprocess.run(["amixer", "-c", index, "scontrols"], capture_output=True, text=True).stdout
        if "'Master'" in controls:
            return index
    return None


def mixer_state(card, control):
    out = subprocess.run(["amixer", "-c", card, "sget", control], capture_output=True, text=True).stdout
    level = re.search(r"\[(\d+)%\]", out)
    return (int(level.group(1)) if level else 0), "[off]" in out


def change_sound(code):
    card = sound_card()
    if card is None:
        return None
    control = "Capture" if code == KEY_MICMUTE else "Master"
    action = {KEY_VOLUMEUP: VOLUME_STEP + "+", KEY_VOLUMEDOWN: VOLUME_STEP + "-"}.get(code, "toggle")
    subprocess.run(["amixer", "-q", "-c", card, "sset", control, action], capture_output=True)
    level, muted = mixer_state(card, control)
    return {"kind": "microphone" if code == KEY_MICMUTE else "volume", "value": level, "muted": muted}


def handle(code):
    if code in (KEY_BRIGHTNESSUP, KEY_BRIGHTNESSDOWN):
        return step_brightness(1 if code == KEY_BRIGHTNESSUP else -1)
    return change_sound(code)


def show(state, seq):
    """Tell the login screen what changed (it reads this when it sees the key)."""
    os.makedirs(os.path.dirname(OSD_FILE), mode=0o755, exist_ok=True)
    tmp = OSD_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(dict(state, seq=seq), f)
    os.chmod(tmp, 0o644)
    os.replace(tmp, OSD_FILE)


def main():
    devices = {}
    open_devices(devices)
    rescan_at = time.monotonic() + 10
    seq = 0
    while True:
        timeout = max(0.0, rescan_at - time.monotonic())
        try:
            ready, _, _ = select.select(list(devices), [], [], timeout)
        except (OSError, ValueError):
            ready = []
        for fd in ready:
            try:
                data = os.read(fd, EVENT.size * 64)
            except BlockingIOError:
                continue
            except OSError:  # unplugged
                os.close(fd)
                devices.pop(fd, None)
                continue
            for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                _sec, _usec, kind, code, value = EVENT.unpack_from(data, offset)
                if kind != EV_KEY or code not in KEYS:
                    continue
                if value == 1 or (value == 2 and code in REPEATS):
                    if desktop_in_front():
                        continue
                    try:
                        state = handle(code)
                    except (OSError, ValueError, subprocess.SubprocessError):
                        state = None
                    if state:
                        seq += 1
                        show(state, seq)
        if time.monotonic() >= rescan_at:  # keyboards come and go
            open_devices(devices)
            rescan_at = time.monotonic() + 10


if __name__ == "__main__":
    main()
