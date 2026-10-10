#!/usr/bin/env bash
# What the USB installer's --demo runs instead of install-system.sh: the same
# steps, said out loud, with nothing touched.
set -euo pipefail
rm -f "$NL_SECRET"
for s in prepare partition format base configure boot snapshots desktop finish; do
  printf '@@NLSTEP %s@@\n' "$s"
  case $s in
    partition) echo "· (demo) would make a partition in the free space on $NL_DISK ($NL_MODE)" ;;
    base) for i in $(seq 1 30); do printf '\r(%2d/30) installing demo-package-%02d' "$i" "$i"; sleep 0.1; done; echo ;;
    configure) echo "· (demo) your account: $NL_USER on $NL_HOST, $NL_TZ, keyboard $NL_XKB" ;;
    *) echo "· (demo) $s" ;;
  esac
  sleep 1
done
echo "· done"
