#!/usr/bin/env python3
r"""
Build-ClientPatch.py -- turn the base client plus client-patches.json into the
runnable client, and emit the "clientPatch" block New-Manifest.ps1 publishes.

    python C:\Wotlk\Launcher\tools\Build-ClientPatch.py
    python C:\Wotlk\Launcher\tools\Build-ClientPatch.py --out C:\some\where.dat

===============================================================================
* WHAT IT PRODUCES

  1. the derived client, written locally so it can be launched and tested BEFORE
     anything is published;
  2. the manifest block: base pin, result pin, and the patch list with the PE
     checksum appended as a final entry.

The result SHA-256 is the whole guarantee. The launcher applies the pokes and
then refuses to install the output unless it hashes to exactly this, so a patch
list that is wrong in any way produces a file that never reaches the player.

* WHY THE CHECKSUM IS COMPUTED HERE

Windows does not validate the PE checksum for user-mode images, so a stale one
would almost certainly go unnoticed -- but leaving a knowingly wrong value in a
file we just rewrote is the kind of thing that makes a later problem hard to
diagnose. The fold is implemented once, here, and shipped as data. The launcher
has no PE knowledge at all and cannot drift from this.

The implementation mirrors LargeAddressAware.RewriteChecksum in the launcher.
--self-test proves it by recomputing the checksum of the STOCK client, whose
stored value is Blizzard's own, and comparing.
===============================================================================
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys
from array import array

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

BASE = r"C:\Wotlk\backups\clientpatch\UncappedBase-2026.09.06a.dat"
PATCHES = r"C:\Wotlk\Launcher\tools\client-patches.json"
OUT = r"C:\Wotlk\backups\clientpatch\UncappedClient-derived.dat"
BLOCK = r"C:\Wotlk\Launcher\tools\client-patch-block.json"
STOCK = r"C:\Wotlk\Client\ChromieCraft_3.3.5a - Copy\Wow.exe"

# Where the base is published. It is byte-identical to the pre-mouse-cam client we
# already shipped, so it needs no upload -- the URL below is that same file, and
# published filenames are immutable, which is why the name says Client not Base.
BASE_URL = "http://152.53.115.249/patches/UncappedClient-2026.08.05a.dat"


def checksum_offset(d: bytes) -> int:
    """Optional header CheckSum: 64 bytes past the end of the COFF header."""
    e = struct.unpack_from("<I", d, 0x3C)[0]
    return e + 4 + 20 + 64


def pe_checksum(data: bytes, csum_off: int) -> int:
    """
    The CheckSumMappedFile fold: a 16-bit sum over the whole file with the
    checksum field itself treated as zero, plus the file length.

    Summing exactly and folding at the end is equivalent to folding as it goes,
    because 2^32-1 is a multiple of 2^16-1, so the intermediate reduction cannot
    change the final residue.
    """
    d = bytearray(data)
    d[csum_off:csum_off + 4] = b"\x00\x00\x00\x00"

    even = len(d) - (len(d) & 1)
    words = array("H")
    words.frombytes(bytes(d[:even]))
    if sys.byteorder != "little":
        words.byteswap()

    total = sum(words)
    if len(d) & 1:
        total += d[-1]

    total = (total & 0xFFFF) + (total >> 16)
    total = (total & 0xFFFF) + (total >> 16)
    total &= 0xFFFF
    return (total + len(d)) & 0xFFFFFFFF


def self_test() -> bool:
    """Recompute the stock client's checksum and compare with its stored value."""
    if not os.path.exists(STOCK):
        print("self-test skipped: stock client not present")
        return True

    d = open(STOCK, "rb").read()
    off = checksum_offset(d)
    stored = struct.unpack_from("<I", d, off)[0]
    computed = pe_checksum(d, off)
    ok = stored == computed
    print(f"self-test: stock checksum stored 0x{stored:08X} computed 0x{computed:08X} "
          f"-> {'MATCH' if ok else 'MISMATCH'}")
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description="Build the derived client and its manifest block.")
    ap.add_argument("--base", default=BASE)
    ap.add_argument("--patches", default=PATCHES)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--block", default=BLOCK)
    ap.add_argument("--base-url", default=BASE_URL)
    a = ap.parse_args()

    if not self_test():
        return sys.exit("the checksum fold does not reproduce a known-good value; "
                        "fix it before publishing anything computed with it")

    base = open(a.base, "rb").read()
    doc = json.load(open(a.patches, encoding="utf-8"))

    base_sha = hashlib.sha256(base).hexdigest()
    print(f"\nbase {os.path.basename(a.base)}")
    print(f"  {len(base):,} bytes  sha256 {base_sha}")

    out = bytearray(base)
    emitted = []

    print(f"\napplying {len(doc['patches'])} patch(es):")
    for p in doc["patches"]:
        off = int(p["offset"], 16)
        want = bytes.fromhex(p["expect"])
        new = bytes.fromhex(p["write"])

        if len(want) != len(new):
            return sys.exit(f"{p['id']}: expect and write differ in length "
                            f"({len(want)} vs {len(new)}) -- patches must preserve length")

        found = bytes(out[off:off + len(want)])
        if found != want:
            return sys.exit(f"{p['id']}: expected {want.hex().upper()} at 0x{off:06X} "
                            f"but found {found.hex().upper()}")

        out[off:off + len(new)] = new
        print(f"  {p['id']:28s} 0x{off:06X}  {len(new):3d} bytes")

        emitted.append({
            "id": p["id"],
            "offset": p["offset"],
            "expect": p["expect"],
            "write": p["write"],
        })

    # The checksum is computed over the finished file and shipped as a final poke.
    csum_off = checksum_offset(out)
    before = bytes(out[csum_off:csum_off + 4])
    value = pe_checksum(bytes(out), csum_off)
    after = struct.pack("<I", value)
    out[csum_off:csum_off + 4] = after

    print(f"  {'pe-checksum':28s} 0x{csum_off:06X}    4 bytes  "
          f"0x{struct.unpack('<I', before)[0]:08X} -> 0x{value:08X}")

    emitted.append({
        "id": "pe-checksum",
        "offset": f"0x{csum_off:06X}",
        "expect": before.hex().upper(),
        "write": after.hex().upper(),
    })

    out = bytes(out)
    result_sha = hashlib.sha256(out).hexdigest()

    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "wb") as fh:
        fh.write(out)

    print(f"\nderived {os.path.basename(a.out)}")
    print(f"  {len(out):,} bytes  sha256 {result_sha}")

    if len(out) != len(base):
        return sys.exit("the derived client changed length; every patch must preserve it")

    block = {
        "clientPatch": {
            "basePath": doc["basePath"],
            "outputPath": doc["outputPath"],
            "baseSha256": base_sha,
            "resultSha256": result_sha,
            "size": len(out),
            "patches": emitted,
        },
        "baseFile": {
            "path": doc["basePath"],
            "url": a.base_url,
            "sha256": base_sha,
            "size": len(base),
        },
    }
    with open(a.block, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(block, fh, indent=2)
        fh.write("\n")

    print(f"\nmanifest block written: {a.block}")
    print("  feed it to New-Manifest.ps1 -ClientPatchBlock")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
