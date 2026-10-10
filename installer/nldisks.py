"""
Disks, for the installer on the Nothing Liquid USB: what is on each one
(Windows, BitLocker, an EFI partition, free space, an earlier Nothing Liquid)
and where Linux can go. Read-only: it changes nothing.

  python3 nldisks.py               every disk it could install to, as JSON
  python3 nldisks.py free /dev/sda the free space it would use: first and last
                                   sector, 1 MiB aligned ("ours" counts as free)
"""

import json
import subprocess
import sys

MIB = 1024 * 1024
GIB = 1024 * MIB
MIN_BYTES = 30 * GIB          # less than this can't hold the desktop
ESP_TYPE = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
OURS = ("NothingLiquid", "NothingLiquidEFI")  # partition names this installer gives


def run_json(cmd):
    try:
        return json.loads(subprocess.run(cmd, capture_output=True, text=True, check=True).stdout or "{}")
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return {}


def free_regions(table, ours_free=False):
    """Gaps in a partition table (sfdisk -J), in sectors, aligned to 1 MiB.
    With ours_free, an earlier Nothing Liquid's partitions count as free too."""
    sector = table.get("sectorsize", 512)
    align = MIB // sector
    first, last = table.get("firstlba", 2048), table.get("lastlba", 0)
    used = sorted((p["start"], p["start"] + p["size"] - 1) for p in table.get("partitions", [])
                  if not (ours_free and p.get("name") in OURS))
    gaps, cursor = [], first
    for start, end in used + [(last + 1, last + 1)]:
        lo = -(-cursor // align) * align           # round up
        hi = (start // align) * align - 1          # round down, inclusive
        if hi - lo + 1 >= align:
            gaps.append((lo, hi))
        cursor = max(cursor, end + 1)
    return [(lo, hi, (hi - lo + 1) * sector) for lo, hi in gaps]


def largest_free(table, ours_free=False):
    gaps = free_regions(table, ours_free)
    return max(gaps, key=lambda g: g[2]) if gaps else None


def describe(dev, table):
    """What a disk (an lsblk -J entry with its children) holds, for the installer."""
    parts = dev.get("children") or []
    fstypes = {p.get("fstype") for p in parts}
    windows = "ntfs" in fstypes or "BitLocker" in fstypes
    esp = next((p["path"] for p in parts if (p.get("parttype") or "").lower() == ESP_TYPE), None)
    ours = [p["path"] for p in parts if p.get("partlabel") in OURS]
    free = largest_free(table) if table else None
    again = largest_free(table, ours_free=True) if table and ours else None
    return {
        "path": dev["path"],
        "model": (dev.get("model") or "").strip() or ("USB drive" if dev.get("tran") == "usb" else "Disk"),
        "size": dev["size"],
        "removable": bool(dev.get("rm")) or dev.get("tran") == "usb",
        "gpt": dev.get("pttype") == "gpt",
        "empty": not parts,
        "windows": windows,
        "bitlocker": "BitLocker" in fstypes,
        "esp": esp,
        "ours": ours,
        "free": free[2] if free else 0,
        "free_again": again[2] if again else 0,  # with an earlier Nothing Liquid removed
        "parts": [{"path": p["path"], "size": p["size"], "fstype": p.get("fstype") or "",
                   "label": p.get("label") or p.get("partlabel") or "",
                   "ours": p.get("partlabel") in OURS, "esp": p["path"] == esp}
                  for p in parts],
        "layout": [(p.get("start", 0), p.get("size", 0), p.get("name", "")) for p in table.get("partitions", [])]
        if table else [],
        "sectors": table.get("lastlba", 0) + 34 if table else dev["size"] // 512,
    }


def disks():
    tree = run_json(["lsblk", "-J", "-b", "-p", "-o",
                     "NAME,PATH,SIZE,TYPE,MODEL,TRAN,RM,RO,PTTYPE,FSTYPE,PARTTYPE,PARTLABEL,LABEL,MOUNTPOINTS"])
    found = []
    for dev in tree.get("blockdevices", []):
        if dev.get("type") != "disk" or dev.get("ro") or dev["size"] < MIN_BYTES:
            continue
        mounts = [m for p in [dev] + (dev.get("children") or []) for m in (p.get("mountpoints") or []) if m]
        if any(m.startswith("/run/archiso") for m in mounts):
            continue  # the USB stick this runs from
        table = run_json(["sfdisk", "-J", dev["path"]]).get("partitiontable", {})
        found.append(describe(dev, table))
    return found


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "free":
        table = run_json(["sfdisk", "-J", sys.argv[2]]).get("partitiontable", {})
        gap = largest_free(table, ours_free=True)
        if not gap or gap[2] < MIN_BYTES:
            sys.exit("no free space of 30 GB or more on " + sys.argv[2])
        print(gap[0], gap[1])
    else:
        print(json.dumps(disks(), indent=2))
