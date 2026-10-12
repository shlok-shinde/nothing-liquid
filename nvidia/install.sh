#!/usr/bin/env bash
# Nothing Liquid for NVIDIA RTX laptops (an Intel or AMD GPU for the screen, and an
# NVIDIA RTX / GTX 16 next to it):
#
#   nvidia/install.sh              install (asks for sudo)
#   nvidia/install.sh --uninstall  take the power setup out again (the driver stays)
#   nvidia/install.sh --status     what the GPU is doing now
#
# What it sets up:
#   - NVIDIA's driver, if there's none yet: the open kernel modules (what NVIDIA
#     recommends from Turing on; built for each of your kernels, with DKMS),
#     nvidia-utils, and nvidia-prime for prime-run <app>
#   - runtime power management (NVreg_DynamicPowerManagement=0x02): the GPU powers
#     off whenever nothing uses it, and on again when an app does
#   - SDDM's login screen on the integrated GPU (greeter-xorg.conf): its X server
#     otherwise takes the NVIDIA GPU too and keeps it through your whole session
#   - /dev/dri/nl-igpu and nl-dgpu (61-nothing-liquid-gpu.rules), so Hyprland can be
#     told to run on the integrated GPU: a Hyprland holding the NVIDIA GPU open keeps
#     it awake all the time (the dots' hyprland/gpu.lua does that at login)
#   - nothing-liquid-gpu-power.service (gpu-power): NVIDIA's Dynamic Boost in the
#     performance profile, off in the others. power-profiles-daemon is installed if
#     no profile daemon is there
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB=/usr/local/lib/nothing-liquid
UNIT=/etc/systemd/system/nothing-liquid-gpu-power.service
RULES=/etc/udev/rules.d/61-nothing-liquid-gpu.rules
MODPROBE=/etc/modprobe.d/nothing-liquid-nvidia.conf
GREETER_XORG=/etc/nothing-liquid/greeter-xorg.conf
SDDM_DROPIN=/etc/sddm.conf.d/30-nothing-liquid-gpu.conf
SDDM_CONF=/etc/sddm.conf

say()  { printf '\033[1m·\033[0m %s\n' "$*"; }
warn() { printf '\033[31m·\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m!\033[0m %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  --status)
    exec bash "$HERE/gpu-power" status ;;
  --uninstall)
    say "bringing the GPU back if an earlier version took it off the bus"
    [[ -x "$LIB/gpu-power" ]] && sudo "$LIB/gpu-power" on
    sudo systemctl disable --now nothing-liquid-gpu-power.service 2>/dev/null || true
    [[ -f "$SDDM_CONF" ]] && sudo sed -i "s| -config $GREETER_XORG||" "$SDDM_CONF"
    sudo rm -f "$UNIT" "$RULES" "$MODPROBE" "$LIB/gpu-power" "$GREETER_XORG" "$SDDM_DROPIN"
    sudo rmdir --ignore-fail-on-non-empty "$LIB" 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=drm
    say "done. NVIDIA's driver stays; Hyprland goes back to using both GPUs at the next login"
    exit 0 ;;
  "") ;;
  *) die "unknown option $1" ;;
esac

# ── the GPU ──────────────────────────────────────────────────────────────────
# (from sysfs: lspci isn't on every fresh Arch)
gpu="" other=""
for d in /sys/bus/pci/devices/*; do
  [[ "$(<"$d/class")" == 0x03* ]] || continue
  if [[ "$(<"$d/vendor")" == 0x10de ]]; then gpu="${gpu:-$d}"; else other="$d"; fi
done
[[ -n "$gpu" ]] || die "no NVIDIA GPU here"
id="$(<"$gpu/device")"
# Turing (RTX 20, GTX 16) and newer start at 0x1e00; the open modules need them
(( id >= 0x1e00 )) || die "this NVIDIA GPU ($id) is older than an RTX 20 / GTX 16: NVIDIA's open driver doesn't support it"
[[ -n "$other" ]] || warn "no integrated GPU next to it (a desktop PC?): the driver goes in, but the GPU stays on all the time"

# ── the driver ───────────────────────────────────────────────────────────────
pkgs=()
if grep -qE '^nvidia(-[0-9]+xx)?-utils$' < <(pacman -Qq); then
  say "NVIDIA's driver is installed: keeping it"
else
  # One headers package per installed kernel, for DKMS to build the module against
  mapfile -t kernels < <(pacman -Qqo /usr/lib/modules/*/pkgbase 2>/dev/null | sort -u)
  ((${#kernels[@]})) || die "couldn't tell which kernels are installed"
  pkgs+=(nvidia-open-dkms nvidia-utils)
  for k in "${kernels[@]}"; do pkgs+=("$k-headers"); done
  say "NVIDIA's driver, for ${kernels[*]}"
fi
pacman -Qq nvidia-prime >/dev/null 2>&1 || pkgs+=(nvidia-prime)
if grep -qx multilib < <(pacman-conf --repo-list 2>/dev/null); then
  grep -qE '^lib32-nvidia(-[0-9]+xx)?-utils$' < <(pacman -Qq) || pkgs+=(lib32-nvidia-utils)  # (Steam and 32-bit games)
fi
# The power profiles: power-profiles-daemon, or tuned's stand-in for it; TLP and
# auto-cpufreq do the same job their own way and conflict with it
if ! pacman -Qq power-profiles-daemon >/dev/null 2>&1 && ! pacman -Qq tuned-ppd >/dev/null 2>&1; then
  if pacman -Qq tlp >/dev/null 2>&1 || pacman -Qq auto-cpufreq >/dev/null 2>&1; then
    warn "TLP or auto-cpufreq manages power here: the GPU stays on demand (no power profiles to follow)"
  else
    pkgs+=(power-profiles-daemon)
  fi
fi
if ((${#pkgs[@]})); then
  say "installing ${pkgs[*]}"
  sudo pacman -S --needed --noconfirm "${pkgs[@]}"
fi
if pacman -Qq power-profiles-daemon >/dev/null 2>&1; then
  sudo systemctl enable --now power-profiles-daemon.service >/dev/null 2>&1 || true
fi

# ── power ────────────────────────────────────────────────────────────────────
say "runtime power management: the GPU powers off when nothing uses it"
printf '%s\n' "# Nothing Liquid (nvidia/install.sh): the GPU powers off when idle (runtime D3)" \
  "options nvidia NVreg_DynamicPowerManagement=0x02" | sudo tee "$MODPROBE" >/dev/null
# (rebuilt only where the driver is part of the initramfs, as some setups have it)
if grep -qE '^MODULES=.*nvidia' /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/*.conf 2>/dev/null; then
  say "the driver starts early here: rebuilding the initramfs"
  sudo mkinitcpio -P
fi

say "names for the two GPUs: /dev/dri/nl-igpu and nl-dgpu"
sudo install -D -m 644 "$HERE/61-nothing-liquid-gpu.rules" "$RULES"
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=drm --action=change
sudo udevadm settle

# SDDM's X server: the integrated GPU alone. /etc/sddm.conf wins over the drop-ins,
# so a ServerArguments line there gets the option itself.
dm="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)" .service)"
sddm_server="$(cat /usr/lib/sddm/sddm.conf.d/*.conf /etc/sddm.conf.d/*.conf "$SDDM_CONF" 2>/dev/null \
  | sed -n 's/^DisplayServer=//p' | tail -1)"
if [[ "$dm" == sddm && "${sddm_server:-x11}" == x11 ]]; then
  say "the login screen on the integrated GPU (from the next time it shows)"
  sudo install -D -m 644 "$HERE/greeter-xorg.conf" "$GREETER_XORG"
  if grep -q '^ServerArguments=' "$SDDM_CONF" 2>/dev/null; then
    grep -q -- "-config $GREETER_XORG" "$SDDM_CONF" \
      || sudo sed -i "s|^ServerArguments=.*|& -config $GREETER_XORG|" "$SDDM_CONF"
  else
    printf '%s\n' "# Nothing Liquid (nvidia/install.sh): the login screen's X server on the integrated GPU" \
      "[X11]" "ServerArguments=-nolisten tcp -config $GREETER_XORG" | sudo tee "$SDDM_DROPIN" >/dev/null
  fi
fi

say "Dynamic Boost in the performance profile (nothing-liquid-gpu-power.service)"
sudo install -D -m 755 "$HERE/gpu-power" "$LIB/gpu-power"
sudo install -D -m 644 "$HERE/nothing-liquid-gpu-power.service" "$UNIT"
# Dynamic Boost runs in the performance profile only: gpu-power starts and stops it
if systemctl cat nvidia-powerd.service >/dev/null 2>&1; then
  sudo systemctl disable nvidia-powerd.service >/dev/null 2>&1 || true
fi
sudo systemctl daemon-reload
sudo systemctl enable nothing-liquid-gpu-power.service >/dev/null
sudo systemctl restart nothing-liquid-gpu-power.service

if [[ -n "$other" ]]; then
  say "done. Log out and in again: from then on Hyprland and the login screen run on the"
  say "  integrated GPU, and the NVIDIA one"
  say "  is off whenever nothing uses it, and on for the apps that do."
  say "  Run an app on it: prime-run <app>.  See what it's doing: nvidia/install.sh --status"
fi
[[ -d /sys/module/nvidia ]] || say "restart the computer to load NVIDIA's driver"
