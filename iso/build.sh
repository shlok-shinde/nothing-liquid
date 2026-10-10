#!/usr/bin/env bash
# Build the Nothing Liquid USB image: an Arch live system that opens the
# installer by itself. Needs archiso, and root (mkarchiso does):
#
#   sudo iso/build.sh [OUT_DIR] [WORK_DIR]       defaults: iso/out, iso/work
#
# It starts from archiso's releng profile (what the official Arch ISO is made
# from), so it keeps up with archiso, and adds: the kiosk and the installer
# window (packages.x86_64), the session that opens it (airootfs, zlogin), a copy
# of this repository as committed (the window, the install script, and what
# gets installed), and the Doto font. Downloads go to WORK_DIR, which is removed
# at the end: only the ISO is left in OUT_DIR. On a disk without Unix permissions
# (NTFS, exFAT), WORK_DIR is a temporary ext4 image there instead (sparse, ~5 GB
# used at most), so the build takes no room on the system disk.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run it with sudo (mkarchiso needs root)"; exit 1; }
command -v mkarchiso >/dev/null || { echo "needs archiso: sudo pacman -S archiso"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
OUT="$(realpath -m "${1:-$HERE/out}")"
WORK="$(realpath -m "${2:-$HERE/work}")"
RELENG=/usr/share/archiso/configs/releng
REPO_URL=https://github.com/shlok-shinde/nothing-liquid.git
DOTO_URL='https://raw.githubusercontent.com/google/fonts/main/ofl/doto/Doto%5BROND%2Cwght%5D.ttf'
PROFILE="$WORK/profile"
say() { printf '\033[1;31m●\033[0m %s\n' "$*"; }

cleanup() {
  mountpoint -q "$WORK" && umount -R "$WORK"
  rm -rf "$WORK" "$WORK.img"
}
trap cleanup EXIT
cleanup
mkdir -p "$WORK" "$OUT"
case "$(stat -f -c %T "$WORK")" in
  ext2/ext3|btrfs|xfs|tmpfs) ;;
  *) say "$WORK can't hold a Linux system (no Unix permissions there): building in an ext4 image"
     truncate -s 16G "$WORK.img"
     mkfs.ext4 -q -F "$WORK.img"
     mount -o loop "$WORK.img" "$WORK" ;;
esac
mkdir -p "$PROFILE" "$WORK/pkg"
cp -a "$RELENG/." "$PROFILE/"

say "profile: releng + Nothing Liquid"
grep -v '^#' "$HERE/packages.x86_64" | sed '/^$/d' >> "$PROFILE/packages.x86_64"
cp -a "$HERE/airootfs/." "$PROFILE/airootfs/"
cat "$HERE/zlogin" >> "$PROFILE/airootfs/root/.zlogin"
sed -i -e 's|^iso_name=.*|iso_name="nothing-liquid"|' \
       -e 's|^iso_label=.*|iso_label="NL_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"|' \
       -e 's|^iso_publisher=.*|iso_publisher="Nothing Liquid <https://github.com/shlok-shinde/nothing-liquid>"|' \
       -e 's|^iso_application=.*|iso_application="Nothing Liquid installer"|' \
       -e 's|^file_permissions=(|file_permissions=(\n  ["/usr/local/bin/nothing-liquid-live-session"]="0:0:755"|' \
       "$PROFILE/profiledef.sh"
# A serial console besides the screen: a VM can test the image without a display
echo 'kernel_params_x86_64="console=ttyS0,115200 console=tty0"' >> "$PROFILE/profiledef.sh"
# Boot menus: its name
while IFS= read -r -d '' f; do
  sed -i 's/Arch Linux install medium/Nothing Liquid installer/g' "$f"
done < <(find "$PROFILE/efiboot" "$PROFILE/grub" "$PROFILE/syslinux" -type f \( -name '*.conf' -o -name '*.cfg' \) -print0 2>/dev/null)
# Its downloads in WORK, not in this computer's pacman cache
sed -i "s|^#\?CacheDir.*|CacheDir = $WORK/pkg/|" "$PROFILE/pacman.conf"
grep -q '^CacheDir' "$PROFILE/pacman.conf" || sed -i "/^\[options\]/a CacheDir = $WORK/pkg/" "$PROFILE/pacman.conf"

say "a copy of Nothing Liquid (as committed) for the installer to put on the disk"
repo="$PROFILE/airootfs/usr/share/nothing-liquid/repo"
git() { command git -c safe.directory='*' -c protocol.file.allow=always "$@"; }
git clone -q --no-hardlinks "$ROOT" "$repo"
for sub in dots hyprglass; do git -C "$repo" config "submodule.$sub.url" "$ROOT/$sub"; done
git -C "$repo" submodule -q update --init
git -C "$repo" remote set-url origin "$REPO_URL"
for sub in dots hyprglass; do git -C "$repo" config --unset "submodule.$sub.url"; done
git -C "$repo" submodule -q sync
say "  $(git -C "$repo" log --oneline -1)"

say "the Doto font, for the window's titles"
mkdir -p "$PROFILE/airootfs/usr/share/fonts/nothing-liquid"
curl -fsSL --retry 3 -o "$PROFILE/airootfs/usr/share/fonts/nothing-liquid/Doto.ttf" "$DOTO_URL" \
  || say "  (couldn't download it: the titles fall back to monospace)"

say "building (mkarchiso)"
mkarchiso -v -r -w "$WORK/build" -o "$OUT" "$PROFILE"
chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$OUT"
say "done: $(ls -1t "$OUT"/*.iso | head -1)"
