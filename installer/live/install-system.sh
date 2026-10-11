#!/usr/bin/env bash
# Nothing Liquid: install a small Arch Linux on this computer, next to Windows or
# on a whole disk, ready for the desktop to finish setting itself up at the first
# start. Runs as root from the Nothing Liquid USB (the installer window runs it).
#
# What it sets up: btrfs with subvolumes (@, @home, @snapshots, @log, @pkg) and
# snapper (snapshots before and after every pacman run, a few daily ones, and
# GRUB entries to start any of them), GRUB with Windows in its menu, zram for
# swap, NetworkManager (with the Wi-Fi from the USB), SDDM, the right CPU
# microcode and graphics driver, optional LUKS encryption. Nothing else: the
# desktop (Hyprland, end-4's shell, Nothing Liquid) comes at the first start.
#
# Settings, from the environment:
#   NL_DISK=/dev/nvme0n1    the disk
#   NL_MODE=free|whole      free: the largest free space (Windows stays; an
#                           earlier Nothing Liquid there is replaced); whole: wipe it
#   NL_USER, NL_FULLNAME, NL_HOST, NL_TZ (Europe/Berlin), NL_KEYMAP (console),
#   NL_XKB (keyboard layout for the desktop), NL_ENCRYPT=0|1
#   NL_SECRET               a file with the password; removed once read
#   NL_PREFS                JSON for the first start: accent, font, login, power
#   NL_REPO                 Nothing Liquid's git checkout to copy (with submodules)
# Steps print "@@NLSTEP <key>@@" so the window can follow along.
set -euo pipefail
shopt -s nullglob

: "${NL_DISK:?}" "${NL_MODE:?}" "${NL_USER:?}" "${NL_HOST:?}" "${NL_SECRET:?}"
NL_FULLNAME="${NL_FULLNAME:-$NL_USER}"
NL_TZ="${NL_TZ:-UTC}"
NL_KEYMAP="${NL_KEYMAP:-us}"
NL_XKB="${NL_XKB:-us}"
NL_ENCRYPT="${NL_ENCRYPT:-0}"
NL_PREFS="${NL_PREFS:-"{}"}"
NL_REPO="${NL_REPO:-/usr/share/nothing-liquid/repo}"
NL_REPO_URL="${NL_REPO_URL:-https://github.com/shlok-shinde/nothing-liquid.git}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=/mnt
MOUNT_OPTS="noatime,compress=zstd:1"

step() { printf '@@NLSTEP %s@@\n' "$1"; }
say()  { printf '· %s\n' "$*"; }
in_target() { arch-chroot "$T" "$@"; }
trap 'echo "!! stopped at line $LINENO: $BASH_COMMAND" >&2' ERR

PASSWORD="$(cat "$NL_SECRET")"
rm -f "$NL_SECRET"
[[ -n "$PASSWORD" ]] || { echo "no password given"; exit 1; }
[[ -b "$NL_DISK" ]] || { echo "$NL_DISK is not a disk"; exit 1; }
[[ -d /sys/firmware/efi ]] || { echo "this computer started the USB in old BIOS mode; Nothing Liquid needs UEFI"; exit 1; }

part_named() { lsblk -nrpo NAME,PARTLABEL "$NL_DISK" | awk -v l="$1" '$2 == l { print $1; exit }'; }
settle() { partprobe "$NL_DISK" 2>/dev/null || true; udevadm settle; sleep 1; }

# ── 0. a clean start (also after an attempt that stopped half way) ───────────
step prepare
umount -R "$T" 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true
swapoff -a 2>/dev/null || true

# ── 1. partitions ────────────────────────────────────────────────────────────
step partition
NEW_ESP=0
if [[ "$NL_MODE" == whole ]]; then
  say "erasing $NL_DISK"
  wipefs -af "$NL_DISK" >/dev/null
  sgdisk --zap-all "$NL_DISK" >/dev/null
  sgdisk -n 1:0:+1G -t 1:ef00 -c 1:NothingLiquidEFI -n 2:0:0 -t 2:8300 -c 2:NothingLiquid "$NL_DISK"
  NEW_ESP=1
else
  # Next to what's there: only on GPT. sgdisk would turn an MBR disk into GPT, and a
  # Windows started the old (BIOS) way wouldn't start any more
  [[ "$(lsblk -dnro PTTYPE "$NL_DISK")" == gpt ]] || { echo "$NL_DISK isn't GPT: can't add Linux next to what's on it"; exit 1; }
  # An earlier Nothing Liquid on this disk goes first (only partitions this installer named)
  for label in NothingLiquid NothingLiquidEFI; do
    while p="$(part_named "$label")" && [[ -n "$p" ]]; do
      num="$(cat "/sys/class/block/${p##*/}/partition")"
      say "removing the earlier $label ($p)"
      wipefs -af "$p" >/dev/null || true
      sgdisk -d "$num" "$NL_DISK" >/dev/null
      settle
    done
  done
  read -r first last < <(python3 "$HERE/../nldisks.py" free "$NL_DISK")
  esp="$(lsblk -nrpo NAME,PARTTYPE "$NL_DISK" | awk 'tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" { print $1; exit }')"
  esp_free=0
  if [[ -n "$esp" ]]; then
    mkdir -p /tmp/nl-esp
    mount "$esp" /tmp/nl-esp
    esp_free="$(df -B1M --output=avail /tmp/nl-esp | tail -1 | tr -d ' ')"
    umount /tmp/nl-esp
  fi
  if (( esp_free < 16 )); then   # no EFI partition, or too full for GRUB: one of our own
    say "making an EFI partition (${esp:-none found}${esp:+ has ${esp_free} MB free})"
    sgdisk -n "0:$first:+512M" -t 0:ef00 -c 0:NothingLiquidEFI "$NL_DISK"
    first=$(( first + 512 * 1024 * 1024 / $(blockdev --getss "$NL_DISK") ))
    NEW_ESP=1
  fi
  say "using the free space on $NL_DISK: sectors $first to $last"
  sgdisk -n "0:$first:$last" -t 0:8300 -c 0:NothingLiquid "$NL_DISK"
fi
settle
ROOTPART="$(part_named NothingLiquid)"
if (( NEW_ESP )); then
  ESP="$(part_named NothingLiquidEFI)"
  mkfs.fat -F 32 -n EFI "$ESP" >/dev/null
else
  ESP="$esp"
fi
[[ -b "$ROOTPART" && -b "$ESP" ]] || { echo "the new partitions didn't show up"; exit 1; }
say "Linux: $ROOTPART, EFI: $ESP"

# ── 2. encryption (if chosen) and the file system ───────────────────────────
step format
DEV="$ROOTPART"
if [[ "$NL_ENCRYPT" == 1 ]]; then
  say "encrypting $ROOTPART"
  # pbkdf2: the only kind GRUB can open (it starts the computer from inside it)
  printf '%s' "$PASSWORD" | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf pbkdf2 \
    --iter-time 1000 --label NothingLiquidCrypt "$ROOTPART" --key-file=-
  printf '%s' "$PASSWORD" | cryptsetup open "$ROOTPART" cryptroot --key-file=-
  DEV=/dev/mapper/cryptroot
fi
mkfs.btrfs -f -L NothingLiquid "$DEV" >/dev/null
mount "$DEV" "$T"
for sv in @ @home @snapshots @log @pkg; do btrfs -q subvolume create "$T/$sv"; done
umount "$T"
mount -o "$MOUNT_OPTS,subvol=@" "$DEV" "$T"
mkdir -p "$T"/{home,.snapshots,var/log,var/cache/pacman/pkg,efi}
mount -o "$MOUNT_OPTS,subvol=@home" "$DEV" "$T/home"
mount -o "$MOUNT_OPTS,subvol=@snapshots" "$DEV" "$T/.snapshots"
mount -o "$MOUNT_OPTS,subvol=@log" "$DEV" "$T/var/log"
mount -o "$MOUNT_OPTS,subvol=@pkg" "$DEV" "$T/var/cache/pacman/pkg"
mount "$ESP" "$T/efi"

# ── 3. the base system ───────────────────────────────────────────────────────
step base
pkgs=(base linux linux-firmware sof-firmware btrfs-progs dosfstools ntfs-3g
      grub grub-btrfs inotify-tools efibootmgr
      snapper snap-pac zram-generator pacman-contrib
      networkmanager polkit sudo nano git man-db
      sddm xorg-server
      cage python-gobject python-cairo gtk4 libadwaita adwaita-fonts)   # cage and the window: the first start
grep -q GenuineIntel /proc/cpuinfo && pkgs+=(intel-ucode)
grep -q AuthenticAMD /proc/cpuinfo && pkgs+=(amd-ucode)
[[ "$NL_ENCRYPT" == 1 ]] && pkgs+=(cryptsetup)
NVIDIA=0
for v in /sys/class/drm/card[0-9]*/device/vendor; do
  case "$(cat "$v")" in
    0x10de) NVIDIA=1 ;;
    0x8086) pkgs+=(mesa vulkan-intel intel-media-driver) ;;
    0x1002) pkgs+=(mesa vulkan-radeon) ;;
  esac
done
(( NVIDIA )) && pkgs+=(nvidia-open nvidia-utils)
mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | awk '!seen[$0]++')
say "installing: ${pkgs[*]}"
# The USB's mirror list starts out empty (all commented). Arch's worldwide CDN
# first (fast nearly everywhere, and never a stale mirror), then the fastest
# recent mirrors as a fallback. The installed system keeps this list.
if ! grep -q '^Server' /etc/pacman.d/mirrorlist; then
  say "finding fast download servers"
  ranked="$(reflector --protocol https --latest 10 --sort rate --connection-timeout 3 --download-timeout 5 \
    2>/dev/null | grep '^Server' || true)"
  printf '# Nothing Liquid: Arch'"'"'s CDN, then the fastest mirrors when it was installed\n%s\n%s\n' \
    'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' "$ranked" > /etc/pacman.d/mirrorlist
fi
pacman -Sy --noconfirm archlinux-keyring >/dev/null
pacstrap -K "$T" "${pkgs[@]}"

# ── 4. settings ──────────────────────────────────────────────────────────────
step configure
genfstab -U "$T" | sed -E 's/,subvolid=[0-9]+//' >> "$T/etc/fstab"   # by name: snapshots can be rolled back to
ln -sf "/usr/share/zoneinfo/$NL_TZ" "$T/etc/localtime"
WINDOWS=0
lsblk -nro FSTYPE | grep -qE '^(ntfs|BitLocker)$' && WINDOWS=1
# Windows keeps the hardware clock in local time; Linux follows, or one of them is always off
if (( WINDOWS )); then in_target hwclock --systohc --localtime; else in_target hwclock --systohc; fi
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$T/etc/locale.gen"
in_target locale-gen >/dev/null
echo "LANG=en_US.UTF-8" > "$T/etc/locale.conf"
echo "KEYMAP=$NL_KEYMAP" > "$T/etc/vconsole.conf"
mkdir -p "$T/etc/X11/xorg.conf.d"
cat > "$T/etc/X11/xorg.conf.d/00-keyboard.conf" <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$NL_XKB"
EndSection
EOF
echo "$NL_HOST" > "$T/etc/hostname"
printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$NL_HOST" "$NL_HOST" >> "$T/etc/hosts"
sed -i 's/^#Color/Color/' "$T/etc/pacman.conf"

say "your account: $NL_USER"
in_target useradd -m -G wheel -c "$NL_FULLNAME" -s /bin/bash "$NL_USER"
printf '%s:%s\n' "$NL_USER" "$PASSWORD" | in_target chpasswd
in_target passwd -l root >/dev/null   # sudo, from your account, instead
echo '%wheel ALL=(ALL:ALL) ALL' > "$T/etc/sudoers.d/10-wheel"
chmod 440 "$T/etc/sudoers.d/10-wheel"

cat > "$T/etc/systemd/zram-generator.conf" <<'EOF'
# Swap in compressed memory: no swap partition to set aside
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF

# The Wi-Fi the USB used, so the first start is online too
for f in /var/lib/iwd/*.psk /var/lib/iwd/*.open; do
  ssid="$(basename "${f%.*}")"
  [[ "$ssid" == =* ]] && continue   # hex-named (unusual characters): skip
  conn="$T/etc/NetworkManager/system-connections/$ssid.nmconnection"
  mkdir -p "$(dirname "$conn")"
  { printf '[connection]\nid=%s\ntype=wifi\n\n[wifi]\nmode=infrastructure\nssid=%s\n\n' "$ssid" "$ssid"
    psk="$(sed -n 's/^Passphrase=//p' "$f")"
    [[ -n "$psk" ]] && printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$psk"
    printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'; } > "$conn"
  chmod 600 "$conn"
  say "Wi-Fi: $ssid"
done

# ── 5. starting up: initramfs and GRUB ───────────────────────────────────────
step boot
hooks="base udev autodetect microcode modconf kms keyboard keymap consolefont block"
cmdline="loglevel=3 quiet"
if [[ "$NL_ENCRYPT" == 1 ]]; then
  hooks+=" encrypt"
  # GRUB asks for the password to start; a key file inside the (encrypted) system
  # lets Linux open it again without asking twice
  install -m 000 /dev/null "$T/crypto_keyfile.bin"
  head -c 512 /dev/urandom > "$T/crypto_keyfile.bin"
  printf '%s' "$PASSWORD" | cryptsetup luksAddKey "$ROOTPART" "$T/crypto_keyfile.bin" --key-file=-
  sed -i 's|^FILES=.*|FILES=(/crypto_keyfile.bin)|' "$T/etc/mkinitcpio.conf"
  luks_uuid="$(blkid -s UUID -o value "$ROOTPART")"
  cmdline+=" cryptdevice=UUID=$luks_uuid:cryptroot cryptkey=rootfs:/crypto_keyfile.bin"
fi
hooks+=" filesystems fsck grub-btrfs-overlayfs"   # the last: snapshots start writable
sed -i "s|^HOOKS=.*|HOOKS=($hooks)|" "$T/etc/mkinitcpio.conf"
(( NVIDIA )) && cmdline+=" nvidia_drm.modeset=1"
in_target mkinitcpio -P
chmod 600 "$T"/boot/initramfs-*.img

sed -i -e 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Nothing Liquid"/' \
       -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' \
       -e "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$cmdline\"|" "$T/etc/default/grub"
[[ "$NL_ENCRYPT" == 1 ]] && sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' "$T/etc/default/grub"
# Windows comes from our 35_windows (by its firmware entry, so BitLocker stays
# quiet), not os-prober; and no menu entry for every firmware boot option
printf '\n# Nothing Liquid: Windows is in the menu through /etc/grub.d/35_windows\nGRUB_DISABLE_OS_PROBER=true\nGRUB_DISABLE_BOOTNEXT=true\n' \
  >> "$T/etc/default/grub"
install -m 755 "$HERE/35_windows" "$T/etc/grub.d/35_windows"
sed -i 's|^#\?GRUB_BTRFS_SUBMENUNAME=.*|GRUB_BTRFS_SUBMENUNAME="Nothing Liquid snapshots"|' "$T/etc/default/grub-btrfs/config"
in_target grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Nothing Liquid" --recheck
in_target grub-mkconfig -o /boot/grub/grub.cfg

# ── 6. snapshots ─────────────────────────────────────────────────────────────
step snapshots
# snapper makes its own .snapshots; ours (@snapshots, outside @) is what rollbacks need
umount "$T/.snapshots"
rmdir "$T/.snapshots"
in_target snapper --no-dbus -c root create-config /
btrfs -q subvolume delete "$T/.snapshots"
mkdir "$T/.snapshots"
mount -o "$MOUNT_OPTS,subvol=@snapshots" "$DEV" "$T/.snapshots"
chmod 750 "$T/.snapshots"
sed -i -e 's/^ALLOW_GROUPS=.*/ALLOW_GROUPS="wheel"/' \
       -e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="0"/' \
       -e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="5"/' \
       -e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="2"/' \
       -e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' \
       -e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
       -e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/' \
       -e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="5"/' "$T/etc/snapper/configs/root"
in_target systemctl enable NetworkManager sddm systemd-timesyncd fstrim.timer paccache.timer \
  snapper-timeline.timer snapper-cleanup.timer grub-btrfsd >/dev/null

# ── 7. the desktop, at the first start ───────────────────────────────────────
step desktop
home="$T/home/$NL_USER"
repo="$home/.local/share/nothing-liquid/repo"
say "copying Nothing Liquid to ~/.local/share/nothing-liquid/repo"
mkdir -p "$(dirname "$repo")"
git -c safe.directory='*' clone -q --no-hardlinks "$NL_REPO" "$repo"
for sub in dots hyprglass; do
  git -c safe.directory='*' -C "$repo" config "submodule.$sub.url" "$NL_REPO/$sub"
done
git -c safe.directory='*' -c protocol.file.allow=always -C "$repo" submodule -q update --init
git -C "$repo" remote set-url origin "$NL_REPO_URL"
git -C "$repo" config --unset submodule.dots.url
git -C "$repo" config --unset submodule.hyprglass.url
git -C "$repo" submodule -q sync   # back to GitHub, for updates
in_target chown -R "$NL_USER:$NL_USER" "/home/$NL_USER/.local"
# The USB's dot-matrix font, for the first start's screen and the desktop's titles
[[ -d /usr/share/fonts/nothing-liquid ]] && cp -r /usr/share/fonts/nothing-liquid "$T/usr/share/fonts/"
mkdir -p "$T/etc/nothing-liquid"
printf '%s\n' "$NL_PREFS" > "$T/etc/nothing-liquid/first-boot.json"

# The first start logs straight in to a screen that finishes the setup (the desktop
# installer, in the cage kiosk), which then removes all this again
install -Dm 755 /dev/stdin "$T/usr/local/bin/nothing-liquid-first-boot" <<'EOF'
#!/bin/sh
# Plain software drawing: works on any graphics, before the desktop's drivers settle
export WLR_RENDERER=pixman GSK_RENDERER=cairo
exec cage -s -- python3 "$HOME/.local/share/nothing-liquid/repo/installer/nothing-liquid-installer" --first-boot
EOF
install -Dm 644 /dev/stdin "$T/usr/share/wayland-sessions/nothing-liquid-setup.desktop" <<'EOF'
[Desktop Entry]
Name=Nothing Liquid setup
Comment=Finishes setting up Nothing Liquid
Exec=/usr/local/bin/nothing-liquid-first-boot
Type=Application
EOF
install -Dm 644 /dev/stdin "$T/etc/sddm.conf.d/zz-nothing-liquid-first-boot.conf" <<EOF
[Autologin]
User=$NL_USER
Session=nothing-liquid-setup
EOF

# ── 8. done ──────────────────────────────────────────────────────────────────
step finish
in_target snapper --no-dbus -c root create -d "Fresh install" -c number
mkdir -p "$T/var/log/nothing-liquid"
cp /run/nothing-liquid/*.log "$T/var/log/nothing-liquid/" 2>/dev/null || true
sync
umount -R "$T"
[[ "$NL_ENCRYPT" == 1 ]] && cryptsetup close cryptroot
unset PASSWORD
say "done"
