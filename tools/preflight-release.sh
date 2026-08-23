#!/usr/bin/env bash
#
# preflight-release.sh -- refuse to ship a release that would lock players out.
#
# Run this BEFORE New-Manifest.ps1 and before any deploy. It is read-only: it
# touches nothing, publishes nothing, and its only output is a verdict.
#
# ─────────────────────────────────────────────────────────────────────────────
# ★ WHY THIS EXISTS
#
# On 2026-08-09 UncappedCT-2026.08.09a.dll was built, hand-copied to the VPS,
# and served correctly at its URL -- while external-files.json and manifest.json
# both still pinned 2026.08.07b. Every player kept running a two-day-old DLL and
# nothing anywhere complained, because every check in the pipeline verifies that
# the pinned file is HONEST and none of them verifies that the pin is CURRENT.
#
#   publish.sh      -- refuses anything that is not patch-enUS-<X>-<ver>.MPQ, so
#                      the DLL has NO safe publishing path at all. It is scp'd by
#                      hand, bypassing the sha256 check, the immutability guard,
#                      the magic-byte check and any record that it happened.
#   New-Manifest    -- downloads each external file, checks PE/MPQ magic bytes,
#                      and verifies its sha256 against the pin. All correct. But
#                      external-files.json is HAND-EDITED, so a DLL nobody
#                      remembered to pin is simply invisible to it.
#
# That cost a missed fix. It is about to cost far more: with client attestation
# enforcing, the server and the DLL must carry the SAME variant set, so a stale
# pin stops being "players miss a fix" and becomes "every player on the realm
# fails attestation at once and cannot log in".
#
# This script is the missing question: is the thing we are about to ship the
# thing we actually built?
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

WOTLK=${WOTLK:-/c/Wotlk}
LAUNCHER=$WOTLK/Launcher
REPO=$WOTLK/Server/azerothcore-wotlk
EXTERNAL=$LAUNCHER/tools/external-files.json
MANIFEST=$LAUNCHER/manifest.json
VPS=${VPS:-root@152.53.115.249}

# The locally built DLL -- the artifact a release is supposed to be shipping.
#
# This is the BUILD OUTPUT, not the copy sitting in a client directory. There is
# a stale 2026-08-07 copy at Client/Uncapped_NativeCT/UncappedCT.dll whose hash
# matches neither published DLL; pointing this at a client-side copy would
# compare the pin against whatever a local install happens to be running, which
# is not the question. Override with BUILT_DLL= if the build moves.
BUILT_DLL=${BUILT_DLL:-$WOTLK/NativeCT/build/UncappedCT.dll}

FAIL=0
WARN=0

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

fail() { red   "  FAIL  $*"; FAIL=$((FAIL+1)); }
warn() { amber "  WARN  $*"; WARN=$((WARN+1)); }
ok()   { green "  ok    $*"; }

# Pull a field out of external-files.json for a given path, without needing jq.
# The file is small, hand-maintained and regularly shaped, so python is the
# honest tool here rather than a regex that breaks on the first reformat.
#
# ⚠ THE PATH MUST BE CONVERTED. The python on PATH here is native Windows
# python, which cannot open a git-bash '/c/...' path -- it fails silently and
# every lookup comes back empty, which reads as "there is no DLL pinned" and is
# indistinguishable from the real thing this script exists to catch. cygpath is
# the difference between a check and a lie.
EXTERNAL_WIN=$(cygpath -w "$EXTERNAL" 2>/dev/null || echo "$EXTERNAL")

ext_field() {
    python -c "
import json,sys
entries = json.load(open(r'$EXTERNAL_WIN'))
for e in entries:
    if e.get('path') == '$1':
        print(e.get('$2') or '')
        break
" 2>/dev/null
}

# Prove the reader works before trusting anything it says. Without this, a
# broken lookup is reported as a missing pin -- a false alarm that would send
# someone hunting a problem that is not there, or worse, teach them to ignore it.
if [ -z "$(ext_field 'Data/enUS/patch-enUS-M.MPQ' 'url')" ]; then
    red "PREFLIGHT IS BROKEN: cannot read $EXTERNAL"
    red "  Every check below would report a false result. Fix this first."
    exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "1. The injected DLL -- pin vs build vs what the host actually serves"
# ─────────────────────────────────────────────────────────────────────────────
#
# Three values have to agree, and each disagreement has a different meaning:
#   built   -- what the last compile produced
#   pinned  -- what external-files.json tells players to fetch
#   served  -- what that URL really returns today
#
# built != pinned  ->  THE LOCKOUT CASE. A new DLL exists and nobody pinned it.
# pinned != served ->  the host was overwritten, or the URL is wrong.

PIN_URL=$(ext_field "UncappedCT.dll" "url")
PIN_SHA=$(ext_field "UncappedCT.dll" "sha256" | tr 'A-Z' 'a-z')

if [ -z "$PIN_URL" ]; then
    fail "UncappedCT.dll has NO entry in external-files.json. Players receive no DLL at all."
else
    ok "pinned url    $PIN_URL"
    [ -n "$PIN_SHA" ] && ok "pinned sha    ${PIN_SHA:0:16}..." \
                      || fail "UncappedCT.dll is pinned with NO sha256 -- New-Manifest will publish whatever the host serves."
fi

if [ -f "$BUILT_DLL" ]; then
    BUILT_SHA=$(sha256sum "$BUILT_DLL" | cut -d' ' -f1 | tr 'A-Z' 'a-z')
    ok "built sha     ${BUILT_SHA:0:16}...  ($BUILT_DLL)"
    if [ -n "$PIN_SHA" ] && [ "$BUILT_SHA" != "$PIN_SHA" ]; then
        fail "★ THE LOCKED-OUT-REALM CASE: the built DLL is NOT the pinned DLL."
        red  "        built  $BUILT_SHA"
        red  "        pinned $PIN_SHA"
        red  "        Publish the new DLL and update BOTH url and sha256 in"
        red  "        external-files.json before regenerating the manifest."
    elif [ -n "$PIN_SHA" ]; then
        ok "built DLL matches the pin"
    fi
else
    warn "no built DLL at $BUILT_DLL -- cannot prove the pin is current."
    warn "      Set BUILT_DLL=<path> if the build output lives elsewhere."
fi

if [ -n "$PIN_URL" ]; then
    SERVED_SHA=$(curl -fsS --max-time 60 "$PIN_URL" 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [ -z "$SERVED_SHA" ] || [ "$SERVED_SHA" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
        fail "the pinned URL served nothing. Players cannot fetch the DLL."
    elif [ -n "$PIN_SHA" ] && [ "$SERVED_SHA" != "$PIN_SHA" ]; then
        fail "the pinned URL serves DIFFERENT bytes than the pin claims."
        red  "        served $SERVED_SHA"
        red  "        pinned $PIN_SHA"
    else
        ok "the pinned URL serves exactly the pinned bytes"
    fi
fi

# manifest.json is what players actually read. external-files.json is only the
# input to it, so a manifest regenerated before the pin was edited still carries
# the old URL -- and the manifest is the one that counts.
if [ -f "$MANIFEST" ] && [ -n "$PIN_URL" ]; then
    if grep -qF "$PIN_URL" "$MANIFEST"; then
        ok "manifest.json carries the same DLL url"
    else
        fail "manifest.json does NOT carry the pinned DLL url -- it is stale."
        red  "        Regenerate it with New-Manifest.ps1 after editing external-files.json."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "2. Orphans -- a DLL published to the host that nothing points at"
# ─────────────────────────────────────────────────────────────────────────────
#
# This is the smoking gun that would have caught 08.09a on the day. A file
# newer than the pinned one, sitting served and unreferenced, is almost always
# a release someone built and forgot to finish.

PUBLISHED=$(ssh -o ConnectTimeout=10 "$VPS" \
    'ls -1t /srv/uncapped-patches/public/UncappedCT-*.dll 2>/dev/null | head -5' 2>/dev/null)

if [ -z "$PUBLISHED" ]; then
    warn "could not list published DLLs on the host (ssh failed?)."
elif [ -z "$PIN_URL" ]; then
    # Guarded explicitly rather than folded into the comparison below. An
    # earlier draft of this script let an empty pin fall through to the else
    # branch and print a green "the newest published DLL is the pinned one" --
    # a check reporting success because it had nothing to compare. A check that
    # passes when it cannot run is worse than no check, because it is trusted.
    fail "cannot check for orphans: nothing is pinned (see section 1)."
else
    NEWEST=$(echo "$PUBLISHED" | head -1)
    NEWEST_BASE=$(basename "$NEWEST")
    if [ "$(basename "$PIN_URL")" != "$NEWEST_BASE" ]; then
        fail "the NEWEST published DLL is not the pinned one."
        red  "        newest published  $NEWEST_BASE"
        red  "        pinned            $(basename "$PIN_URL")"
        red  "        Either pin the newer file or delete it -- an unreferenced"
        red  "        DLL on the host is an unfinished release."
    else
        ok "the newest published DLL is the pinned one"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "3. Client version gate -- four copies that must agree"
# ─────────────────────────────────────────────────────────────────────────────
#
# REQUIRED_CLIENT_VERSION (server) and CLIENT_VERSION (addon) are compared
# directly at login: a mismatch disconnects the player ~25s in. Four places hold
# a copy and all four have to line up by the time the server restarts.
#
# ⚠ repo != payload is NORMAL before a build -- the payload is rebuilt at
# release time. It is only fatal if you are about to deploy without rebuilding.

# ⚠ LA-10. The addon patterns carry a negative lookbehind, and it is load-bearing.
# A bare 'CLIENT_VERSION\s*=\s*' ALSO matches REQUIRED_CLIENT_VERSION, and `head -1`
# takes whichever line comes first. The moment anyone adds a REQUIRED_CLIENT_VERSION
# line to the addon -- which the coupling below makes tempting -- this gate would be
# comparing a number to itself and passing unconditionally. (?<![A-Z_]) means the match
# must not be preceded by another constant-name character.
VG_REPO=$(grep -oP 'REQUIRED_CLIENT_VERSION\s*=\s*\K[0-9]+' "$REPO/lua_scripts/version_gate.lua" 2>/dev/null | head -1)
AD_REPO=$(grep -oP '(?<![A-Z_])CLIENT_VERSION\s*=\s*\K[0-9]+' "$REPO/client_addons/UncappedVersion/UncappedVersion.lua" 2>/dev/null | head -1)
AD_PAY=$(grep -oP '(?<![A-Z_])CLIENT_VERSION\s*=\s*\K[0-9]+' "$LAUNCHER/payload/Interface/AddOns/UncappedVersion/UncappedVersion.lua" 2>/dev/null | head -1)
VG_LIVE=$(ssh -o ConnectTimeout=10 "$VPS" \
    "grep -oP 'REQUIRED_CLIENT_VERSION\s*=\s*\K[0-9]+' /opt/azerothcore-wotlk/lua_scripts/version_gate.lua 2>/dev/null | head -1" 2>/dev/null)

printf "  server gate (repo)   %s\n" "${VG_REPO:-?}"
printf "  addon      (repo)    %s\n" "${AD_REPO:-?}"
printf "  addon      (payload) %s\n" "${AD_PAY:-?}"
printf "  server gate (LIVE)   %s\n" "${VG_LIVE:-?}"

if [ -n "$VG_REPO" ] && [ -n "$AD_REPO" ] && [ "$VG_REPO" != "$AD_REPO" ]; then
    fail "server gate and addon disagree IN THE REPO -- every player would be kicked."
elif [ -n "$VG_REPO" ]; then
    ok "server gate and addon agree in the repo"
fi

if [ -n "$AD_REPO" ] && [ -n "$AD_PAY" ] && [ "$AD_REPO" != "$AD_PAY" ]; then
    warn "payload addon ($AD_PAY) is older than the repo ($AD_REPO)."
    warn "      Expected before a build. FATAL if you deploy without running Build-Payload."
fi

# ─────────────────────────────────────────────────────────────────────────────
# ★★ LA-05. VG_LIVE vs the payload -- AND THE DIRECTION IS THE WHOLE CHECK.
# ─────────────────────────────────────────────────────────────────────────────
#
# VG_LIVE used to be fetched, printed, and then never compared to anything: the one
# copy of the four that actually decides whether players get kicked was decoration.
#
# ⚠ THE FIRST ATTEMPT AT FIXING THAT WAS WORSE THAN THE HOLE. It used `!=`, which is
# a string test and cannot tell ahead from behind, and it called BOTH directions a
# fail -- so it hard-blocked the realm's own mandated release order and told the
# operator to invert it. This realm publishes CLIENT FIRST and restarts second:
#
#   PUBLISHING-PATCHES.md:297-303 -- "Payload published and CDN-verified FIRST,
#   server restarted SECOND. … The reverse -- a restarted server meeting clients
#   still on the old DLL -- is the one that LOCKS PEOPLE OUT."
#
# So at the exact moment CLAUDE.md requires this script to be green, on a gate-bump
# release, the CORRECT state is AD_PAY new and VG_LIVE old. That is a warn, not a fail.
#
#   AD_PAY <  VG_LIVE  -> FAIL. The realm has already restarted onto a newer gate and
#                         you are about to publish a payload it will evict on sight.
#   AD_PAY >  VG_LIVE  -> WARN. The documented client-first window. Keep it short.
#   AD_PAY == VG_LIVE  -> ok.
#
# Numeric -lt/-gt, never string !=, for exactly the reason above.
if [ -z "$AD_PAY" ]; then
    # ⚠ Its own branch. Both comparisons below are guarded on AD_PAY being set, so an
    # empty one used to make this entire section print NOTHING -- no fail, no warn, not
    # even a line -- and preflight went on to say "All checks passed" having compared
    # none of the four copies. Same defect section 2 calls out at :173-180.
    warn "no client version in the STAGED PAYLOAD -- section 3 could not compare anything."
    warn "      Run Build-Payload and re-run preflight. Do not publish on this result."
fi

if [ -z "$VG_LIVE" ]; then
    warn "could not read the LIVE server gate over ssh -- this check is UNVERIFIED."
    warn "      Do not publish on the assumption it matches. Settle it by hand."
elif [ -n "$AD_PAY" ] && [ "$AD_PAY" -lt "$VG_LIVE" ]; then
    fail "the payload you are about to publish is version $AD_PAY, but the LIVE server
      already demands $VG_LIVE. It is AHEAD of you -- publishing this payload
      disconnects EVERY player ~25s into login, and a restart will not help
      because the realm is already on the newer gate. Rebuild the payload from
      a repo at $VG_LIVE or higher."
elif [ -n "$AD_PAY" ] && [ "$AD_PAY" -gt "$VG_LIVE" ]; then
    warn "payload ($AD_PAY) is ahead of the LIVE server gate ($VG_LIVE)."
    warn "      That is the CORRECT order here -- publish, verify the CDN, THEN restart."
    warn "      Anyone who relaunches in between bounces off the gate. Keep it short."
elif [ -n "$AD_PAY" ]; then
    ok "payload ($AD_PAY) matches the LIVE server gate ($VG_LIVE)"
fi

if [ -n "$VG_REPO" ] && [ -n "$VG_LIVE" ] && [ "$VG_REPO" != "$VG_LIVE" ]; then
    warn "repo gate ($VG_REPO) != LIVE gate ($VG_LIVE) -- a realm restart is pending."
    warn "      That is fine mid-release; it is a trap if you stop here and forget."
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "3b. Addon lists -- every addon of ours that ships must be in BOTH"
# ─────────────────────────────────────────────────────────────────────────────
#
# LA-07. Five addons have now shipped missing from forceEnableAddOns or ownedPaths;
# four of them became player bug reports (#766, #925, and two silent ones). The lists
# are edited by hand and nothing compared them to the payload until this existed.

# ⚠ Three outcomes, not two. `if python …; then ok; else fail; fi` collapsed "could not
# run" into "passed": with no staged payload the script exits 0 and preflight printed a
# green line asserting agreement it had never tested. That is the same defect section 2
# already guards against at :173-180 -- a check that passes when it cannot run.
python "$LAUNCHER/tools/check-addon-lists.py"
addon_rc=$?
if [ "$addon_rc" -eq 0 ]; then
    ok "addon lists agree with the staged payload"
elif [ "$addon_rc" -eq 2 ]; then
    warn "the addon-list check did NOT RUN -- there is no staged payload. UNVERIFIED."
    warn "      Run Build-Payload and re-run preflight before publishing."
else
    fail "an addon of ours ships but is missing from a manifest list -- see above."
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "4. Client attestation -- the variant sets must match"
# ─────────────────────────────────────────────────────────────────────────────
#
# When variants are regenerated per release, the server .inc and the DLL must
# carry the SAME set. A mismatch fails EVERY player at once. The server is meant
# to fail OPEN on a hash mismatch rather than lock the realm out over our own
# release mistake -- but that is a backstop, not a licence to ship a mismatch.

# The real interlock lives in tools/attestation/check_release.py and is wired
# into New-Manifest.ps1, which throws before writing anything. That is the gate
# that matters -- the manifest is the only file the launcher reads. This just
# runs it early so the answer arrives before you have built a payload, rather
# than after.
CHECK=$REPO/tools/attestation/check_release.py
if [ ! -f "$CHECK" ]; then
    ok "no attestation interlock present yet -- nothing to check"
else
    CHECK_WIN=$(cygpath -w "$CHECK" 2>/dev/null || echo "$CHECK")
    if OUT=$(python "$CHECK_WIN" 2>&1); then
        ok "attestation variant set: DLL, .inc, pin and served bytes all agree"
    else
        fail "attestation interlock REFUSES this release:"
        echo "$OUT" | sed 's/^/          /' | head -20
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "5. The client archive -- is the pin current, and is there one at all"
# ─────────────────────────────────────────────────────────────────────────────
#
# LA-02. The 2.6 GB stock-client zip shipped for months with no hash of any kind
# -- the one external input the launcher could not verify, over plain http,
# expanded into a brand-new player's install root. New-Manifest now refuses to
# write a manifest without a verified pin, which is the real gate. This asks the
# cheap half of the question early: does the LIVE manifest carry a sha256, and
# does the host still serve the length it names? A full re-hash is 2.6 GB and
# belongs in New-Manifest, not here.
MANIFEST_WIN=$(cygpath -w "$MANIFEST" 2>/dev/null || echo "$MANIFEST")

ca_field() {
    python -c "
import json
m = json.load(open(r'$MANIFEST_WIN', encoding='utf-8-sig'))
d = (m.get('client') or {}).get('directDownloadUrls') or []
print(d[0].get('$1', '') if d else '')
" 2>/dev/null
}

CA_URL=$(ca_field url)
CA_SHA=$(ca_field sha256)
CA_BYTES=$(ca_field bytes)

if [ -z "$CA_URL" ]; then
    # ⚠ Three outcomes, not two -- same rule as 3b. An unreadable manifest is not a pass.
    warn "could not read client.directDownloadUrls from $MANIFEST -- UNVERIFIED."
elif [ -z "$CA_SHA" ] || [ "${#CA_SHA}" -lt 64 ]; then
    fail "the manifest's client archive has NO usable sha256 (got '${CA_SHA:-empty}')."
    fail "      Every first-time installer would take 2.6 GB over plain http that nothing"
    fail "      checks. Re-run New-Manifest.ps1; it refuses to write without a verified pin."
else
    ok "client archive is pinned (sha256 ${CA_SHA:0:12}…)"

    SERVED=$(curl -sI --max-time 20 "$CA_URL" 2>/dev/null \
             | tr -d '\r' | grep -i '^content-length:' | awk '{print $2}' | head -1)
    if [ -z "$SERVED" ]; then
        warn "could not HEAD $CA_URL -- the served length is UNVERIFIED."
    elif [ -n "$CA_BYTES" ] && [ "$SERVED" != "$CA_BYTES" ]; then
        fail "the host serves $SERVED bytes for the client archive but the manifest says $CA_BYTES."
        fail "      The zip was re-uploaded without regenerating the manifest. The pin is stale,"
        fail "      and every install would fail its length check. Re-run New-Manifest.ps1."
    else
        ok "the host still serves the length the manifest names ($CA_BYTES bytes)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "6. The base host -- does it serve what baseline.json describes"
# ─────────────────────────────────────────────────────────────────────────────
#
# LA-13. tools/verify-base-host.py was written after the 2026-08-12 incident in
# which the launcher installed a client its own integrity check then rejected --
# PLAY permanently off for anyone whose network blocked BitTorrent. Its docstring
# says it "is meant to be run before any release that touches baseline.json, the
# base files on the host, or the acquisition path", and that its exit code exists
# "so it can gate a release script".
#
# ⚠ NOTHING EVER CALLED IT. Grepping the whole repo and docs/ for the string
# "verify-base-host" found exactly one file: the script itself. A gate nobody
# invokes is not a gate. This is that call.
#
# --hash-below 0 by default: sizes and a range probe over HTTP, no download, so
# it costs a few seconds. Set PREFLIGHT_HASH_BASE=1 to pay ~30 MB for the content
# proof as well before a release that actually touches the base files.
VBH=$LAUNCHER/tools/verify-base-host.py
if [ ! -f "$VBH" ]; then
    warn "tools/verify-base-host.py is missing -- the base host is UNVERIFIED."
else
    VBH_WIN=$(cygpath -w "$VBH" 2>/dev/null || echo "$VBH")
    if [ "${PREFLIGHT_HASH_BASE:-0}" = "1" ]; then
        VBH_ARGS="--hash-below 33554432"
    else
        VBH_ARGS="--hash-below 0"
    fi

    # shellcheck disable=SC2086
    if VBH_OUT=$(python "$VBH_WIN" $VBH_ARGS 2>&1); then
        ok "the patch host agrees with baseline.json on every required file"
        if [ "${PREFLIGHT_HASH_BASE:-0}" != "1" ]; then
            printf "        (sizes and resume probe only -- PREFLIGHT_HASH_BASE=1 also hashes ~30 MB)\n"
        fi
    else
        fail "the patch host does NOT agree with baseline.json:"
        echo "$VBH_OUT" | sed 's/^/          /' | tail -20
        fail "      This is the exact check for the 2026-08-12 'installs a client its own"
        fail "      verifier rejects' incident. Settle it before publishing anything."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
head_ "VERDICT"
# ─────────────────────────────────────────────────────────────────────────────
if [ "$FAIL" -gt 0 ]; then
    red "$FAIL blocking problem(s), $WARN warning(s). DO NOT SHIP."
    exit 1
fi
if [ "$WARN" -gt 0 ]; then
    amber "$WARN warning(s), nothing blocking. Read them before shipping."
    exit 0
fi
green "All checks passed."
exit 0
