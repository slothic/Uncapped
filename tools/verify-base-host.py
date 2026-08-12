#!/usr/bin/env python3
"""Prove the patch host serves exactly the base client the baseline describes.

WHY THIS EXISTS
---------------
On 2026-08-12 the launcher was found to be installing a client that its own
integrity check then rejected. The HTTP fallback pulled the Internet Archive's
WoW_3.3.5-12340 item, which is a DIFFERENT 3.3.5a build from the one
baseline.json was generated against: six required files differed, exactly those
six were flagged, and PLAY was permanently disabled for anyone whose network
blocked BitTorrent.

Acquisition now fetches those files from our own host instead, which makes the
two agree by construction -- but only for as long as the host really serves what
the baseline says. That is what this checks, and it is meant to be run before any
release that touches baseline.json, the base files on the host, or the
acquisition path.

It deliberately does NOT need a 16 GB download:

  * HEAD gives Content-Length, which catches a truncated or replaced upload.
  * A one-byte Range probe from a non-zero offset proves the host really supports
    resumption -- the launcher relies on it to survive a dropped connection
    partway through a 4 GB MPQ, and "Accept-Ranges" in a header is a claim, not
    evidence.
  * Every file under --hash-below is downloaded in full and hashed. That is the
    part that proves CONTENT rather than size, and at the default threshold it
    covers Data/enUS/base-enUS.MPQ plus every DLL and the exe for about 30 MB.

Exit code is non-zero if anything is wrong, so it can gate a release script.

USAGE
    python verify-base-host.py                      # local baseline.json
    python verify-base-host.py --baseline http://152.53.115.249/baseline.json
    python verify-base-host.py --hash-below 0       # size+range only, no hashing
    python verify-base-host.py --hash-all           # full 16 GB proof
"""

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'baseline.json')
TIMEOUT = 60


def load_baseline(source):
    if source.startswith('http://') or source.startswith('https://'):
        with urllib.request.urlopen(source, timeout=TIMEOUT) as r:
            return json.loads(r.read().decode('utf-8'))
    with open(source, encoding='utf-8-sig') as f:
        return json.load(f)


def head(url):
    """Content-Length and Accept-Ranges, or an exception."""
    req = urllib.request.Request(url, method='HEAD')
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return int(r.headers['Content-Length']), r.headers.get('Accept-Ranges', '-')


def range_probe(url, offset):
    """True when the host answers 206 to a real byte-range request.

    Probed from the LAST byte rather than the first: a host that ignores the
    header entirely would answer 200 and start streaming the whole file, which
    is exactly the case the launcher has to detect and restart from.
    """
    req = urllib.request.Request(url, headers={'Range': 'bytes=%d-%d' % (offset, offset)})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.status == 206, len(r.read())


def sha256_url(url):
    h = hashlib.sha256()
    got = 0
    with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
        while True:
            chunk = r.read(1024 * 256)
            if not chunk:
                break
            h.update(chunk)
            got += len(chunk)
    return h.hexdigest(), got


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--baseline', default=DEFAULT_BASELINE,
                    help='path or URL of baseline.json (default: the one beside this repo)')
    ap.add_argument('--hash-below', type=int, default=64 * 1024 * 1024, metavar='BYTES',
                    help='fully download and hash files smaller than this (default 64 MB; 0 disables)')
    ap.add_argument('--hash-all', action='store_true',
                    help='hash every required file, all ~16 GB of them')
    args = ap.parse_args()

    baseline = load_baseline(args.baseline)
    required = [f for f in baseline.get('files', []) if f.get('required')]

    print('baseline: %s' % args.baseline)
    print('build %s, locale %s, %d files, %d required'
          % (baseline.get('clientBuild'), baseline.get('locale'),
             len(baseline.get('files', [])), len(required)))
    print()

    problems = []
    hashed = 0
    hashed_bytes = 0

    print('%-44s %14s  %-7s %-6s %s' % ('served', 'size', 'range', 'hash', 'note'))
    print('-' * 96)

    for f in sorted(required, key=lambda x: x['path']):
        path = f['path']
        url = f.get('url')
        served = f.get('served') or (url.rsplit('/', 1)[-1] if url else '?')

        if not url:
            problems.append('%s: required but baseline publishes no url' % path)
            print('%-44s %14s  %-7s %-6s %s' % (served, '-', '-', '-', 'NO URL <<<'))
            continue

        # --- size ---
        try:
            size, accept = head(url)
        except Exception as e:
            problems.append('%s: HEAD failed - %s' % (path, e))
            print('%-44s %14s  %-7s %-6s %s' % (served, '-', '-', '-', 'HEAD FAILED: %s <<<' % e))
            continue

        size_ok = (size == f['size'])
        if not size_ok:
            problems.append('%s: host serves %d bytes, baseline says %d' % (path, size, f['size']))

        # --- resumability ---
        try:
            ok206, got = range_probe(url, max(0, size - 1))
            range_note = 'yes' if ok206 else 'NO'
            if not ok206:
                problems.append('%s: host ignored a Range request (no resume)' % path)
            if ok206 and got != 1:
                problems.append('%s: Range returned %d bytes, expected 1' % (path, got))
        except Exception as e:
            range_note = 'ERR'
            problems.append('%s: range probe failed - %s' % (path, e))

        # --- content ---
        hash_note = 'skip'
        if args.hash_all or (args.hash_below and f['size'] < args.hash_below):
            try:
                digest, got = sha256_url(url)
                hashed += 1
                hashed_bytes += got
                if digest.lower() == f['sha256'].lower():
                    hash_note = 'OK'
                else:
                    hash_note = 'BAD'
                    problems.append('%s: sha256 %s, baseline says %s' % (path, digest, f['sha256']))
            except Exception as e:
                hash_note = 'ERR'
                problems.append('%s: download failed - %s' % (path, e))

        note = '' if (size_ok and hash_note in ('OK', 'skip') and range_note == 'yes') else '<<<'
        print('%-44s %14s  %-7s %-6s %s' % (served, format(size, ','), range_note, hash_note, note))

    print()
    print('checked %d required file(s); fully hashed %d (%s bytes)'
          % (len(required), hashed, format(hashed_bytes, ',')))

    if problems:
        print()
        print('PROBLEMS (%d):' % len(problems))
        for p in problems:
            print('  - %s' % p)
        return 1

    print('OK - the host agrees with the baseline on every required file.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
