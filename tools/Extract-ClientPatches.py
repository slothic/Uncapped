#!/usr/bin/env python3
r"""
Extract-ClientPatches.py -- split the shipped client .dat into a BASE file plus a
byte-level PATCH LIST, so the launcher can derive the runnable client locally
instead of us hosting a whole patched 7.7 MB executable per change.

    python C:\Wotlk\Launcher\tools\Extract-ClientPatches.py

===============================================================================
* WHY THIS EXISTS

Until now every client-side hex patch was baked into UncappedClient.dat offline
and published as a whole file, which meant a 7.7 MB re-download for every player
for the sake of a handful of bytes. Worse, SyncService.IsCurrentAsync re-hashes
the installed client against the manifest pin on EVERY launch, so a launcher
that patched the file in place would re-download it every launch, forever.

The split is what makes local patching safe:

  base   -- stock Wow.exe + the .unc import-table section + the LAA header bit.
            STRUCTURAL, changes essentially never, pinned in the manifest and
            synced exactly like any other file. IsCurrentAsync is untouched.
  patch  -- the byte pokes (mouse-cam, .zdata NX, whatever comes next). Data in
            the manifest, not bytes on a CDN. A new patch costs a manifest edit
            and ZERO client download.

* WHAT COUNTS AS BASE AND WHAT COUNTS AS PATCH

The rule is mechanical and is applied here rather than left to judgement: a
differing region lands in the BASE if it is in the PE headers or past the end of
stock (the appended .unc section and its padding), and in the PATCH LIST if it
falls inside a section -- in practice .text. Structural edits change the shape of
the file and cannot be expressed as same-length pokes; code edits can, and are
exactly what we want to iterate on without a re-download.

* WHY THE PATCHES ARE LENGTH-PRESERVING AND EXPECT-CHECKED

Every entry carries the bytes it expects to find. The launcher refuses to write
if what is there is not what we predicted, which is what makes a build-locked
patch safe: the mouse-cam patch is a set of hardcoded displacements correct for
exactly one build, and under this scheme it cannot be applied to a different one.

* THE CHECKSUM IS A PATCH ENTRY, NOT LAUNCHER CODE

Build-ClientPatch.py computes the derived file's PE checksum and emits it as one
more 4-byte poke. That keeps every scrap of PE knowledge in this toolchain: the
launcher only copies a file, writes N byte ranges, and checks a SHA-256. There is
deliberately no second implementation of the checksum fold to drift out of sync.
===============================================================================
"""

from __future__ import annotations

import hashlib
import json
import os
import struct
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

STOCK = r"C:\Wotlk\Client\ChromieCraft_3.3.5a - Copy\Wow.exe"
SHIPPED = r"C:\Wotlk\Client\ChromieCraft_3.3.5a\UncappedClient.dat"

OUT_DIR = r"C:\Wotlk\backups\clientpatch"
OUT_BASE = os.path.join(OUT_DIR, "UncappedBase-2026.09.06a.dat")
OUT_PATCHES = r"C:\Wotlk\Launcher\tools\client-patches.json"

# Runs of identical bytes shorter than this inside a differing region are kept as
# part of that region rather than splitting it. A patch is easier to read and to
# audit as one contiguous block than as four fragments separated by two bytes.
MERGE_GAP = 16


def sections(d: bytes):
    e = struct.unpack_from("<I", d, 0x3C)[0]
    n = struct.unpack_from("<H", d, e + 6)[0]
    optsize = struct.unpack_from("<H", d, e + 20)[0]
    tbl = e + 24 + optsize
    out = []
    for i in range(n):
        o = tbl + i * 40
        name = d[o:o + 8].rstrip(b"\x00").decode("latin1")
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", d, o + 8)
        out.append((name, raddr, rsize, vaddr))
    return out


def locate(secs, off: int):
    """(section name, virtual address) for a file offset, or (None, None)."""
    for name, raddr, rsize, vaddr in secs:
        if raddr <= off < raddr + rsize:
            return name, 0x400000 + vaddr + (off - raddr)
    return None, None


def diff_regions(a: bytes, b: bytes):
    n = min(len(a), len(b))
    runs = []
    i = 0
    while i < n:
        if a[i] != b[i]:
            j = i
            while j < n and a[j] != b[j]:
                j += 1
            if runs and i - runs[-1][1] < MERGE_GAP:
                runs[-1] = (runs[-1][0], j)
            else:
                runs.append((i, j))
            i = j
        else:
            i += 1
    return runs


def main() -> int:
    stock = open(STOCK, "rb").read()
    shipped = open(SHIPPED, "rb").read()
    secs = sections(shipped)

    print(f"stock   {len(stock):,} bytes  {hashlib.sha256(stock).hexdigest()[:16]}")
    print(f"shipped {len(shipped):,} bytes  {hashlib.sha256(shipped).hexdigest()[:16]}")

    # The base starts as the shipped file: it already carries every structural
    # change. Code patches are then REVERTED out of it, which is what makes it a
    # clean source the patch list can be replayed onto.
    base = bytearray(shipped)
    patches = []

    for a, b in diff_regions(stock, shipped):
        name, va = locate(secs, a)
        if name is None:
            print(f"  base (header)  0x{a:06X}..0x{b:06X}  {b - a:4d} bytes")
            continue

        base[a:b] = stock[a:b]
        patches.append({
            "id": f"{name.lstrip('.')}-{va:08x}",
            "note": "",
            "offset": f"0x{a:06X}",
            "section": name,
            "va": f"0x{va:08X}",
            "expect": stock[a:b].hex().upper(),
            "write": shipped[a:b].hex().upper(),
        })
        print(f"  PATCH {name:8s} 0x{a:06X}..0x{b:06X}  {b - a:4d} bytes  va=0x{va:08X}")

    tail = len(shipped) - len(stock)
    if tail:
        print(f"  base (appended) {tail} bytes past the end of stock (.unc + padding)")

    base = bytes(base)

    # Replaying the list onto the base must reproduce the shipped file EXACTLY.
    # If it does not, the split is wrong and nothing below is trustworthy.
    replay = bytearray(base)
    for p in patches:
        off = int(p["offset"], 16)
        want = bytes.fromhex(p["expect"])
        new = bytes.fromhex(p["write"])
        if replay[off:off + len(want)] != want:
            sys.exit(f"FAILED: {p['id']} does not match the base it was cut from")
        replay[off:off + len(new)] = new
    if bytes(replay) != shipped:
        sys.exit("FAILED: base + patches does not reproduce the shipped client")

    print("\nverified: base + patches reproduces the shipped client byte for byte")

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_BASE, "wb") as fh:
        fh.write(base)

    print(f"\nbase written: {OUT_BASE}")
    print(f"  {len(base):,} bytes  sha256 {hashlib.sha256(base).hexdigest()}")

    doc = {
        "_comment": [
            "Byte patches the launcher applies to the base client to produce the",
            "runnable one. Length-preserving and expect-checked; see",
            "Extract-ClientPatches.py for why the split is shaped this way.",
            "Offsets are FILE offsets into the base, not virtual addresses.",
        ],
        "basePath": "UncappedBase.dat",
        "outputPath": "UncappedClient.dat",
        "patches": patches,
    }
    with open(OUT_PATCHES, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")

    print(f"patch list written: {OUT_PATCHES}  ({len(patches)} entries)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
