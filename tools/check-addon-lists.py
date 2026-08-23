#!/usr/bin/env python3
"""
check-addon-lists.py — every addon of OURS that ships must be in BOTH manifest lists.

LA-07. This exact bug has now shipped FIVE times, and New-Manifest.ps1's own comments
record the first four:

  #766  Uncapped64bitUI  — in ownedPaths, not force-enabled. Anyone who ever unticked it
                           lost every 64-bit number and all combat-text controls, forever.
  #925  UncappedPanel    — same failure, reported as "the command bar has disappeared".
        UncappedLootFeed — in NEITHER list: its Dashboard tab and /lootfeed did nothing.
        (ownedPaths)     — three addons shipped unlisted and became impossible to prune.

The two lists do different jobs and a miss fails differently:

  forceEnableAddOns  ticks the addon in AddOns.txt on every launch. MISSING -> a player
                     who ever unticked it stays unticked forever, silently, with nothing
                     that will ever restore it.
  ownedPaths         permits pruning under that folder. MISSING -> a renamed or dropped
                     file stays on every player's disk forever and loads alongside the new
                     copy. This is why devUncapped64 and UncappedTempo are still listed.

⚠ ASYMMETRIC ON PURPOSE. An entry in a list with no matching payload folder is NOT an
error: retired names (devUncapped64, UncappedTempo, and the six Dashboard-bundled folders)
are deliberately KEPT in ownedPaths because that listing is the only thing that deletes
them from players' clients. Only ships-but-unlisted is a failure.

Third-party addons (Dominos, Postal, GTFO, ...) are install-only and must NOT be in
either list — we do not force-tick or delete addons we did not write. "Ours" is defined
as a folder that exists in the server repo's client_addons/, which is where our addons
are authored.

    python C:/Wotlk/Launcher/tools/check-addon-lists.py     # exit 1 on a miss
"""

import io
import os
import re
import sys

PAYLOAD = "C:/Wotlk/Launcher/payload/Interface/AddOns"
SOURCES = "C:/Wotlk/Server/azerothcore-wotlk/client_addons"
MANIFEST_PS1 = "C:/Wotlk/Launcher/tools/New-Manifest.ps1"


def ps_array(text, name):
    """Pull a PowerShell @('a', 'b', ...) literal, which may span many lines.

    ⚠ Comments are stripped BEFORE the paren scan, not after. Scanning raw text meant a
    lone "(" inside a body comment -- and this file's house style puts prose comments
    inside ownedPaths, with parens in them -- ran the scan past the array's real close and
    swallowed unrelated strings. That direction fails OPEN: the list reads as containing
    more than it does, so a genuinely missing addon looks present and the check goes
    quietly green. Strip first and that whole class disappears.
    """
    text = re.sub(r"#[^\n]*", "", text)
    m = re.search(re.escape(name) + r"\s*=\s*@\(", text)
    if not m:
        return None
    depth, i = 1, m.end()
    while i < len(text) and depth:
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return set(re.findall(r"'([^']+)'", text[m.end():i]))


def folders(path):
    if not os.path.isdir(path):
        return None
    return {d for d in os.listdir(path) if os.path.isdir(os.path.join(path, d))}


def main():
    payload = folders(PAYLOAD)
    ours = folders(SOURCES)
    if payload is None:
        # exit 2, NOT 0. Returning 0 here made preflight print a green "addon lists agree
        # with the staged payload" and reach "All checks passed" having compared nothing --
        # a check that passes when it cannot run, which preflight-release.sh:173-180 already
        # calls out by name as worse than no check because it is trusted.
        print("SKIP  no staged payload at %s -- run Build-Payload first." % PAYLOAD)
        print("      This check cannot pass or fail without one; do not read that as OK.")
        return 2
    if ours is None:
        sys.exit("cannot read %s -- is the server repo present?" % SOURCES)

    text = io.open(MANIFEST_PS1, encoding="utf-8-sig", errors="replace").read()
    force = ps_array(text, "forceEnableAddOns")
    owned = ps_array(text, "ownedPaths")
    if force is None or owned is None:
        sys.exit("could not parse forceEnableAddOns / ownedPaths out of New-Manifest.ps1 "
                 "-- the check is BROKEN, not passing. Fix the parser.")

    owned_addons = {p.split("/")[-1] for p in owned if p.startswith("Interface/AddOns/")}
    shipping = sorted(payload & ours)          # ours AND actually staged

    missing_force = [a for a in shipping if a not in force]
    missing_owned = [a for a in shipping if a not in owned_addons]

    print("  staged addons          %d" % len(payload))
    print("  of those, ours         %d" % len(shipping))
    print("  forceEnableAddOns      %d" % len(force))
    print("  ownedPaths (addons)    %d" % len(owned_addons))

    # A third-party addon in either list would make us force-tick or DELETE something we
    # did not write. Worth saying out loud; not fatal on its own.
    third_party = sorted((force | owned_addons) & (payload - ours))
    for a in third_party:
        print("  ! %s is third-party but appears in one of our lists" % a)

    bad = False
    for a in missing_force:
        print("  FAIL %s ships but is NOT in forceEnableAddOns -- anyone who unticked it "
              "stays unticked forever" % a)
        bad = True
    for a in missing_owned:
        print("  FAIL %s ships but is NOT in ownedPaths -- nothing under it can ever be "
              "pruned or renamed" % a)
        bad = True

    if bad:
        print("\nEdit BOTH lists in New-Manifest.ps1 before publishing.")
        return 1
    print("  ok: every shipping addon of ours is in both lists")
    return 0


if __name__ == "__main__":
    sys.exit(main())
