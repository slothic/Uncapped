"""Prove a change to the patch set changed nothing a player can see.

Builds the effective, post-load-order view of the client's custom patch stack
BEFORE and AFTER a change, and diffs them by SHA-256 of the actual decompressed
bytes -- not by filename, not by size, not by "looks right".

Load order in 3.3.5a: patch-<locale>.MPQ, then the numbered archives 2..9, then
the lettered archives A..Z. Later wins, WHOLESALE, per file: a DBC present in two
archives is not merged, the later archive's copy simply replaces the earlier one.
That is why "the file is still in there somewhere" is not the question worth
asking -- "which copy does the client actually read" is.

Usage:
    python verify-stack.py --before 4=a.mpq 5=b.mpq R=c.mpq \
                           --after  U=out.mpq

Each argument is <letter>=<path>. Exit 0 only when nothing was lost and nothing
changed bytes.
"""
import argparse
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mpqlib

ORDER = '123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'


def parse(pairs, label):
    out = []
    for p in pairs:
        if '=' not in p:
            raise SystemExit('%s: expected <letter>=<path>, got %r' % (label, p))
        letter, path = p.split('=', 1)
        letter = letter.upper()
        if letter not in ORDER:
            raise SystemExit('%s: %r is not a valid archive letter' % (label, letter))
        if not os.path.exists(path):
            raise SystemExit('%s: no such archive %s' % (label, path))
        out.append((letter, path))
    return sorted(out, key=lambda x: ORDER.index(x[0]))


def effective(stack):
    """{entry_lower: (winning_letter, sha256, size)} after load order is applied."""
    view = {}
    for letter, path in stack:
        for name, _ in mpqlib.content_files(path):
            data = mpqlib.extract(path, name)
            view[name.lower()] = (letter, hashlib.sha256(data).hexdigest(), len(data))
    return view


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--before', nargs='+', required=True, metavar='LETTER=PATH')
    ap.add_argument('--after', nargs='+', required=True, metavar='LETTER=PATH')
    ap.add_argument('--quiet', action='store_true',
                    help='only print the verdict and anything wrong')
    a = ap.parse_args()

    bstack, astack = parse(a.before, '--before'), parse(a.after, '--after')
    print('BEFORE: ' + ' '.join('%s=%s' % (l, os.path.basename(p)) for l, p in bstack))
    print('AFTER : ' + ' '.join('%s=%s' % (l, os.path.basename(p)) for l, p in astack))
    print('\nhashing (this reads every entry in every archive) ...', flush=True)

    before, after = effective(bstack), effective(astack)
    print('reachable entries: before=%d  after=%d' % (len(before), len(after)))

    missing = sorted(set(before) - set(after))
    added   = sorted(set(after) - set(before))
    changed = sorted(n for n in set(before) & set(after) if before[n][1] != after[n][1])
    moved   = sorted(n for n in set(before) & set(after)
                     if before[n][0] != after[n][0] and before[n][1] == after[n][1])

    if not a.quiet:
        print('\n--- every .dbc reachable in either stack ---')
        for n in sorted(set(before) | set(after)):
            if not n.endswith('.dbc'):
                continue
            b, af = before.get(n), after.get(n)
            fmt = lambda v: '%s %s %d' % (v[0], v[1][:16], v[2]) if v else '-- ABSENT'
            ok = 'OK  ' if b and af and b[1] == af[1] else '****'
            print('  %s %-44s before[%s]  after[%s]' % (ok, n, fmt(b), fmt(af)))

    print('\n--- verdict ---')
    print('  no longer reachable : %d %s' % (len(missing), ' '.join(missing)))
    print('  newly reachable     : %d %s' % (len(added), ' '.join(added)))
    print('  CHANGED bytes       : %d %s' % (len(changed), ' '.join(changed)))
    print('  same bytes, moved   : %d' % len(moved))
    for n in moved:
        print('      %-44s %s -> %s' % (n, before[n][0], after[n][0]))

    # `added` is not a failure: consolidating deliberately gives one archive files
    # it did not have. Losing a file, or changing one without meaning to, is.
    if missing or changed:
        print('\n  RESULT: FAIL -- see above. Do not publish this.')
        return 1
    print('\n  RESULT: PASS -- nothing lost, nothing altered')
    return 0


if __name__ == '__main__':
    sys.exit(main())
