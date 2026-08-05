#!/usr/bin/env bash
#
# Uploads the required baseline files to the patch host under their served names.
#
# No local staging tree: the files are 16 GB and copying them once to rename them
# would cost the same disk again for nothing. scp renames on the way up.
#
# Idempotent. A file already on the host with the right size is skipped, so a
# re-run after an interrupted upload only moves what is missing.
#
# Usage:  ./Publish-Baseline.sh [path-to-baseline.json] [client-dir]

set -euo pipefail

BASELINE="${1:-C:/Wotlk/Launcher/baseline.json}"
CLIENT="${2:-C:/Wotlk/Client/ChromieCraft_3.3.5a - Copy}"
HOST="root@152.53.115.249"
DEST="/srv/uncapped-patches/public/base"

echo "baseline: $BASELINE"
echo "client:   $CLIENT"
echo "dest:     $HOST:$DEST"
echo

ssh "$HOST" "mkdir -p '$DEST'"

# What is already up there, as "name size" pairs.
existing="$(ssh "$HOST" "cd '$DEST' 2>/dev/null && stat -c '%n %s' * 2>/dev/null || true")"

# path<TAB>served<TAB>size, required entries only.
#
# tr -d '\r' is load-bearing: Python on Windows writes CRLF, which leaves the trailing
# carriage return glued to $size and turns the byte count into a string arithmetic
# cannot evaluate. Same trap as the CRLF-in-a-URL-list one that made curl report 000.
plan="$(python -c "
import json, sys
b = json.load(open(r'''$BASELINE''', encoding='utf-8'))
for f in b['files']:
    if f.get('required'):
        print(f\"{f['path']}\t{f['served']}\t{f['size']}\")
" | tr -d '\r')"

total=$(printf '%s\n' "$plan" | wc -l)
n=0
uploaded=0
skipped=0

while IFS=$'\t' read -r path served size; do
    n=$((n + 1))
    [ -z "$path" ] && continue

    if printf '%s\n' "$existing" | grep -qxF "$served $size"; then
        printf '[%2d/%2d] skip   %s (already %s bytes)\n' "$n" "$total" "$served" "$size"
        skipped=$((skipped + 1))
        continue
    fi

    src="$CLIENT/$path"
    if [ ! -f "$src" ]; then
        echo "MISSING LOCALLY: $src" >&2
        exit 1
    fi

    printf '[%2d/%2d] upload %s (%s MB)\n' "$n" "$total" "$served" "$((size / 1000000))"
    scp -q "$src" "$HOST:$DEST/$served"
    uploaded=$((uploaded + 1))
done <<< "$plan"

echo
echo "uploaded $uploaded, skipped $skipped"

# Read-only, matching the permissions the existing patch files carry.
ssh "$HOST" "chmod 444 '$DEST'/* && chown root:root '$DEST'/*"

# ---------------------------------------------------------------------------
# Prove what is on the host, do not assume it.
#
# publish.sh (the MPQ path) verifies every byte before making a file live, and
# this must not be the weaker sibling: these are the bytes a repair replaces a
# player's game files with. scp reports success on a truncated transfer often
# enough to matter, and a short MPQ that hashes wrong would turn Repair into a
# loop -- download, fail verification, offer Repair again.
#
# Hashed on the HOST, so what is checked is what is actually stored there.
# ---------------------------------------------------------------------------
echo
echo "verifying hashes on the host…"

expected="$(python -c "
import json
b = json.load(open(r'''$BASELINE''', encoding='utf-8'))
for f in b['files']:
    if f.get('required'):
        print(f\"{f['sha256']}  {f['served']}\")
" | tr -d '\r')"

actual="$(printf '%s\n' "$expected" | awk '{print $2}' \
    | ssh "$HOST" "cd '$DEST' && xargs sha256sum" | tr -s ' ')"

bad=0
while read -r want name; do
    got="$(printf '%s\n' "$actual" | awk -v n="$name" '$2 == n {print $1}')"
    if [ "$got" != "$want" ]; then
        echo "  MISMATCH $name" >&2
        echo "    want $want" >&2
        echo "    got  ${got:-<absent>}" >&2
        bad=$((bad + 1))
    fi
done <<< "$expected"

if [ "$bad" -gt 0 ]; then
    echo >&2
    echo "$bad file(s) on the host do not match baseline.json. NOT SAFE TO PUBLISH." >&2
    exit 1
fi

echo "  all $(printf '%s\n' "$expected" | wc -l) file(s) match baseline.json"
echo
ssh "$HOST" "du -sh '$DEST'"
