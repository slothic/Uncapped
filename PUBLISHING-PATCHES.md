# Publishing a client patch

How a change to the client MPQ patches reaches players. Companion to
`PUBLISHING-ADDONS.md` (the payload and addons) and `PUBLISHING-BASELINE.md`
(the stock-client hashes that decide whether PLAY is enabled at all).

> A patch published here is picked up by the integrity check automatically — it
> is a `manifest.json` entry, and the manifest is half of what the check reads.
> Nothing extra to do. `baseline.json` covers only the *stock* client and does
> not change when you cut a patch.

Patches are **not** in `payload/` and **not** in git — they are hundreds of
megabytes of binaries. They are hosted on the realm's own VPS and pinned by URL
and SHA-256 in `tools/external-files.json`.

## The shape of it

| Archive | What it is | Rebuilt? |
|---|---|---|
| `patch-enUS-U` | **Ours. The consolidated DBC bundle.** Spell, AreaTable, Map, Item, LightFloatBand. | Every release |
| `patch-enUS-Q` | Ours. 298 MB of mount models + 2 DBCs. | Effectively never |
| `patch-enUS-M` | Trimitor's WDM dungeon maps. **Mirrored, not forked.** | Only when he ships |
| `patch-enUS-N` | Trimitor's Caverns and Mines. **Mirrored, not forked.** | Only when he ships |

There is exactly **one archive we rebuild**. Everything the client needs from us
that changes lives in `-U`.

`-Q` is kept separate on purpose. Folding 298 MB of static mount models into the
bundle would mean re-uploading and re-downloading all of it for every one-line
DBC tweak. One extra manifest entry is much cheaper than that, forever.

`-M` and `-N` are Trimitor's work. We serve byte-identical copies from our host
so a deleted upstream release cannot break new installs, but they stay pinned to
his tags and we do not modify them. Folding them in would fork his work and
strand us on a stale snapshot. Note that `-N` ships its own `AreaTable.dbc`,
which `-U` already overrides by load order — merging would mean reconciling that
by hand on every one of his releases.

### Why `-U`

Load order is `patch-enUS.MPQ`, then `-2`..`-9`, then `-A`..`-Z`; later wins
**wholesale** per file (DBCs are replaced, never merged).

`-U` sorts after everything it replaced — `-4`, `-5`, `-R` and, crucially, `-S`,
which sorted *after* `-R`. Reusing `-R` would have meant a client that had not
yet pruned its old `-S` loading S's `LightFloatBand.dbc` over the consolidated
one. Identical bytes today, so it would look fine — and the day the fog changed
it would silently serve the old fog. `V`–`Z` stay free for a hotfix archive that
needs to override `-U`.

---

## Cutting a new version

### 1. Build — by adding to the current archive, never repacking

```powershell
python tools\mpq\build-patch.py `
    --base .external-cache\Data_enUS_patch-enUS-U.<urlkey> `
    --out  work\patch-enUS-U.MPQ `
    --from-file "DBFilesClient\Spell.dbc=work\Spell.dbc"
```

Start from the **currently published** archive (the `.external-cache` copy is the
exact bytes players have). `build-patch.py` has no "pack from a file list" mode
on purpose: `-U` accumulates DBCs over time, and a repack silently drops anything
not on the list, producing an archive that looks fine and breaks something nobody
thinks to test.

`build-patch.py` reads every entry back out of the finished archive and compares
it to what it wrote. The build is reproducible — the same inputs give the same
SHA-256.

Requires StormLib; set `UNCAPPED_STORMLIB` if it is not at the default path.

### 2. Verify — prove it, do not assert it

```powershell
python tools\mpq\verify-stack.py `
  --before M=<M.MPQ> N=<N.MPQ> Q=<Q.MPQ> U=<current-U.MPQ> `
  --after  M=<M.MPQ> N=<N.MPQ> Q=<Q.MPQ> U=work\patch-enUS-U.MPQ
```

This applies load order to both stacks and diffs the **effective** view by
SHA-256 of decompressed bytes. Exit 0 means nothing became unreachable and
nothing changed bytes except what you meant to change. Anything you *did* change
shows up under `CHANGED bytes` — confirm that list is exactly your intent.

**Do not publish on a non-zero exit.**

### 3. Upload and publish

```powershell
scp work\patch-enUS-U.MPQ root@152.53.115.249:/srv/uncapped-patches/incoming/patch-enUS-U-2026.08.05a.MPQ
ssh root@152.53.115.249 /opt/uncapped-files/publish.sh patch-enUS-U-2026.08.05a.MPQ <sha256>
```

Versions are `YYYY.MM.DD` plus a letter for same-day re-cuts. **Published
filenames are immutable** — `publish.sh` refuses to overwrite one. It also
refuses on a name nginx will not serve, a hash mismatch, or a file that does not
start with the MPQ magic bytes, and it confirms through nginx that a range
request returns 206 with the right length before reporting success.

On success it prints the JSON block for the next step.

### 4. Point the launcher at it

Paste that block into `tools/external-files.json` — `url` **and** `sha256`. The
`path` never carries a version: load order depends only on the archive letter, so
what lands in the client is always `patch-enUS-U.MPQ`.

```powershell
.\tools\Build-Payload.ps1 -Clean
.\tools\New-Manifest.ps1 -BaseUrl https://raw.githubusercontent.com/slothic/Uncapped/main/payload
git add -A; git commit -m "patches: ..."; git push
```

`New-Manifest.ps1` re-downloads the file from the URL you just published, checks
the MPQ magic bytes, and hard-fails if the bytes do not match the `sha256` you
pinned. Its cache is keyed on the **URL**, so a new version is always re-fetched.

**Nothing reaches a player until the manifest is pushed.** The manifest is the
only thing the launcher reads.

---

## ★ Publishing `UncappedCT.dll` — the one that is NOT an MPQ

**This is the step with no tooling behind it, and the one that has already gone
wrong.** Read it before shipping a release that rebuilt the DLL.

`publish.sh` **cannot publish the DLL.** It regex-rejects any name that is not
`patch-enUS-<X>-<version>.MPQ`, so every guard it provides — the sha256 check,
the immutability refusal, the magic-byte check, the nginx range-request proof —
is unavailable here. The DLL is copied into the serving directory **by hand**,
and none of those protections apply.

That is how `UncappedCT-2026.08.09a.dll` came to sit published and served from
01:03 on 2026-08-09 while `external-files.json` and `manifest.json` both still
pinned `2026.08.07b`. Every player kept running a two-day-old DLL and nothing
complained, because **every check in the pipeline verifies that the pinned file
is honest, and none of them verifies that the pin is current.**

⚠ **With client attestation enforcing, this stops being a missed fix.** The
server and the DLL must carry the same generated variant set. A stale pin means
every player on the realm fails attestation at once.

### The procedure

```powershell
# 1. Copy it up. NOTE the destination is public/ directly -- there is no
#    incoming/ + publish.sh path for a DLL. Use a NEW dated filename; never
#    overwrite a published one, for the same resume-safety reason MPQs have.
scp C:\Wotlk\NativeCT\build\UncappedCT.dll `
    root@152.53.115.249:/srv/uncapped-patches/public/UncappedCT-2026.08.09b.dll

# 2. Prove the bytes survived the trip. publish.sh would have done this for you.
ssh root@152.53.115.249 "sha256sum /srv/uncapped-patches/public/UncappedCT-2026.08.09b.dll"
#    Compare against the local file yourself:
(Get-FileHash C:\Wotlk\NativeCT\build\UncappedCT.dll -Algorithm SHA256).Hash.ToLower()

# 3. Prove it is actually served, not merely on disk.
curl -sI http://152.53.115.249/patches/UncappedCT-2026.08.09b.dll
```

Then update **both** `url` and `sha256` for the `UncappedCT.dll` entry in
`tools/external-files.json`, and only then run `New-Manifest.ps1`.

---

## ★ Publishing `itemcache.wdb` — the one that is NOT pinned by hash

The client caches every item query response it ever receives in
`Cache\WDB\<locale>\itemcache.wdb` and **never expires an entry**. Change an item
and everyone who already saw it keeps the stale copy forever — report #224
(blank icons on items whose displayid and texture are both correct on our side)
is exactly that. We generate the file server-side and install it.

Everything about this entry is driven by `tools/itemcache.json`.

### Cut a new one

```powershell
# 1. Pull the inputs off the realm (read-only queries) and build the file.
#    ⚠ Item.dbc/Spell.dbc/SpellCategory.dbc are copied out of the container by
#    hand -- `fetch` prints the command. item_dbc.tsv comes down with the fetch
#    and is NOT optional: the ItemEntry store is Item.dbc PLUS the item_dbc
#    world table, and generating without it emits wrong bytes for custom items.
cd C:\Wotlk\Server\azerothcore-wotlk\tools\wdb
python gen_itemcache.py fetch --out data
python gen_itemcache.py gen   --data data --out C:\Wotlk\Launcher\work\itemcache.wdb

# 2. Prove it against every real client cache you can find, and prove the
#    proof works. verify exits non-zero on any difference; what matters is
#    that every differing field re-queries on prod to the value we generated.
python gen_itemcache.py verify --data data --real "<a real client>\Cache\WDB\enUS\itemcache.wdb"
python gen_itemcache.py verify --data data --real "<same>" --perturb Delay   # must fail

# 3. gzip it deterministically (mtime 0, no stored filename) and hash both halves.
```

Then, exactly like `UncappedCT.dll`: **`publish.sh` cannot publish this.** It
regex-rejects any name that is not `patch-enUS-<X>-<version>.MPQ`, so the file is
copied into the serving directory by hand and none of its guards apply.

```powershell
scp C:\Wotlk\Launcher\work\itemcache-2026.08.10a.wdb.gz `
    root@152.53.115.249:/srv/uncapped-patches/public/itemcache-2026.08.10a.wdb.gz
ssh root@152.53.115.249 "sha256sum /srv/uncapped-patches/public/itemcache-2026.08.10a.wdb.gz"
curl -sI http://152.53.115.249/patches/itemcache-2026.08.10a.wdb.gz
```

Published filenames are **immutable** — always a new dated name, never an
overwrite. Then update `epoch`, `url`, `sha256`, `size`, `contentSha256` and
`contentSize` in `tools/itemcache.json`, set `enabled` to `true`, and regenerate
the manifest. `New-Manifest.ps1` re-downloads the URL, checks the gzip magic,
both hashes, both sizes, the `BDIW` header, the client build and the eight-zero
terminator, and **throws before writing the manifest** on any mismatch.

### ⚠ Why this is not a `files[]` entry, and must never become one

**The client rewrites `itemcache.wdb` continuously during play.** Its hash stops
matching whatever we installed within seconds of the player logging in and never
matches again. As a manifest file entry it would re-download 1.7 MB on *every*
launch forever — and, much worse, be reported `Corrupt` by the integrity check,
which **blocks PLAY**. It gets its own `itemCache` manifest block, triggered by an
opaque **epoch token**, which the launcher records in a sentinel file
(`uncapped-itemcache.epoch`) beside the cache. The client never touches it.

Bump the epoch whenever you publish new bytes. Equal epoch means "leave it
alone"; anything different means "install this".

### ★ Rolling back — one edit, no launcher release

```jsonc
// tools/itemcache.json
"enabled": false
```

Regenerate the manifest and push. `New-Manifest.ps1` then writes **no**
`itemCache` block, and the launcher falls straight through to wiping `Cache\WDB`
and installing nothing — which is precisely what it did before this feature
existed. Every client returns to the known-good state on its next launch.

That is the safety net for this whole feature, because **nothing on the server
checks that the file a client loaded is one we generated**. It is fail-open by
design, so the ability to revert without a release is the compensating control.
Rolling forward again is setting it back to `true`.

Everything else is fail-safe already: an unreachable host, either hash
disagreeing, a decompressed file that is not a WDB, or a client in a language we
did not generate for all end in the same full wipe rather than in a guess.

### `Cache` stays in `baseline.json`'s `skipRoots` — deliberately

It is tempting to think the launcher must "own" `Cache` to manage a file there.
It must not, and moving it would be the one change here that can lock the realm
out.

* Installing is driven by the **manifest**, not the baseline. The baseline only
  decides what the integrity check walks, and `WdbCache` writes into `Cache\WDB`
  today without any baseline involvement — the old unconditional wipe already did.
* `IntegrityVerifier` walks `baseline.checkedRoots`, which is `["Data"]`.
  `skipRoots` is generation-time metadata for `New-Baseline.ps1` and is not read
  at runtime at all. Moving `Cache` out of `skipRoots` therefore does nothing
  *unless* it also lands in `checkedRoots` — and then every `.wdb` the client
  writes for itself (creature, quest, gameobject, npc, pagetext, wowcache)
  becomes a `Foreign` finding, on every client, forever.
* And the file the launcher installs is a file the **client legitimately
  mutates**. Anything that hash-checks it reports `Corrupt` the moment someone
  plays. Corrupt on a manifest file is `Blocking`. That is the lockout.

The test harness asserts this: `integrity: item cache raises no problem` runs a
full verification against a client whose item cache has been rewritten.

### Before you publish anything, run the preflight

```bash
bash tools/preflight-release.sh
```

Read-only, touches nothing. It answers the question no other check asks — *is
the thing we are about to ship the thing we actually built?* — by comparing the
built DLL, the pin, the bytes the URL really serves, and the newest file
published on the host, plus the four copies of the client version number. It
exits non-zero and says `DO NOT SHIP` on any mismatch.

An **orphan** — a DLL on the host that nothing points at — is reported as a
failure rather than a curiosity, because it is almost always an unfinished
release. Either pin it or delete it.

`New-Manifest.ps1` additionally runs `tools/attestation/check_release.py` and
**throws before writing the manifest** if the DLL, the generated `.inc`, the pin
and the served bytes do not all agree. That is the hard gate; the preflight just
gives you the answer earlier, before you have built a payload.

### Order matters, and the wrong order kicks the realm

Payload published and CDN-verified **first**, server restarted **second**. An
updated client meeting an un-restarted server is handled gracefully — it earns
the version gate's "update your client" message rather than an attestation kick.
The reverse — a restarted server meeting clients still on the old DLL — is the
one that locks people out.

---

## How the launcher notices, and what happens mid-download

The launcher compares the manifest's `sha256` against the file already on disk
(size first as a cheap pre-filter). **The URL is not part of change detection** —
changing bytes is what matters, and the hash is what it checks.

Downloads go to a temp file, are hashed, and are only then renamed into place. A
failed hash leaves the existing file untouched and the error is reported.

Because published URLs are immutable, publishing cannot corrupt an in-flight
download: a player pulling `...04a` keeps getting `...04a` even as `...04b` goes
live. They pick up the new version on their next launch. (The launcher does not
currently send `Range` headers, so an interrupted download restarts from zero —
the host supports resume and returns 206, so this is a launcher-side improvement
available whenever it is wanted.)

## Rolling back

Nothing to undo on the host — the previous version is still published at its own
URL. Put the previous `url` **and** `sha256` back in `external-files.json`,
regenerate the manifest, push. Clients notice by hash and re-download.

`ssh root@152.53.115.249 /opt/uncapped-files/list.sh` prints every live file with
its size and hash.

## Retiring an archive

Dropping an archive from `external-files.json` (or from `payload/`) also deletes
it from players' clients: `Data/enUS` is in the manifest's `ownedPaths`, and the
launcher prunes owned files that have left the manifest.

Archives already consolidated away are additionally listed in `$retiredPatches`
in `Build-Payload.ps1`, so a stray copy left in the working client's `Data\enUS`
cannot silently re-ship and undo the consolidation.

## Mirrors and upstream

A daily timer on the VPS (`uncapped-mirror-check`) reports when an upstream
release carrying the same asset appears, when the bytes behind a pinned tag are
replaced in place, or when upstream goes away. See `RUNBOOK.md` on the VPS at
`/opt/uncapped-files/` for re-mirroring. A drift report is a prompt to decide,
not an instruction to update — taking a new third-party version changes what
players get and needs testing first.
