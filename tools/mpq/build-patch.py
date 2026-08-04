"""Build the consolidated client patch by ADDING to a copy of the current one.

    python build-patch.py --base current-U.MPQ --out new-U.MPQ \
        --from-mpq "DBFilesClient\\Item.dbc=other.MPQ" \
        --from-file "DBFilesClient\\Spell.dbc=C:\\work\\Spell.dbc"

There is no "pack these files into a new archive" mode, on purpose. The
consolidated archive accumulates DBCs over time, and a repack from a file list
silently drops anything not on the list -- producing an archive that looks fine
and breaks something nobody thinks to test. Starting from the live archive and
adding to it cannot lose what it does not touch.

Always follow with verify-stack.py before publishing.
"""
import argparse
import hashlib
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mpqlib


def split(spec, what):
    if '=' not in spec:
        raise SystemExit('%s: expected <entry>=<source>, got %r' % (what, spec))
    return spec.split('=', 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', required=True,
                    help='the archive to start from -- normally the currently published one')
    ap.add_argument('--out', required=True)
    ap.add_argument('--from-mpq', action='append', default=[], metavar='ENTRY=ARCHIVE',
                    help='copy ENTRY out of ARCHIVE and into the output')
    ap.add_argument('--from-file', action='append', default=[], metavar='ENTRY=PATH',
                    help='add PATH into the output as ENTRY')
    a = ap.parse_args()

    if os.path.exists(a.out):
        raise SystemExit('refusing to overwrite %s -- remove it or pick another name' % a.out)

    shutil.copy2(a.base, a.out)
    print('base   %s (%d bytes)' % (a.base, os.path.getsize(a.base)))

    entries = []
    for spec in a.from_mpq:
        entry, src = split(spec, '--from-mpq')
        data = mpqlib.extract(src, entry)
        print('  + %-44s %9d bytes  <- %s' % (entry, len(data), os.path.basename(src)))
        entries.append((entry, data))
    for spec in a.from_file:
        entry, src = split(spec, '--from-file')
        with open(src, 'rb') as fh:
            data = fh.read()
        print('  + %-44s %9d bytes  <- %s' % (entry, len(data), os.path.basename(src)))
        entries.append((entry, data))

    if not entries:
        raise SystemExit('nothing to add -- pass --from-mpq and/or --from-file')

    mpqlib.add_files(a.out, entries)

    # Read every added entry back OUT of the finished archive and compare. Writing
    # is not proof it landed: this is.
    for entry, data in entries:
        got = mpqlib.extract(a.out, entry)
        if got != data:
            raise SystemExit('VERIFY FAILED: %s reads back differently than it was written'
                             % entry)
    print('\nall added entries read back byte-identical')

    print('\n%s (%d bytes)' % (a.out, os.path.getsize(a.out)))
    for name, size in sorted(mpqlib.content_files(a.out)):
        print('   %-52s %10d' % (name, size))

    with open(a.out, 'rb') as fh:
        digest = hashlib.sha256(fh.read()).hexdigest()
    print('\nsha256 %s' % digest)
    print('\nNext: verify-stack.py, then upload and publish.sh with that hash.')


if __name__ == '__main__':
    main()
