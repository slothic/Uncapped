# The client baseline and the integrity check

How the launcher knows whether a game folder is a legitimate Uncapped client, and
what to do to that machinery without breaking every player at once.

Companion to `PUBLISHING-ADDONS.md` (the payload) and `PUBLISHING-PATCHES.md`
(the MPQ patches).

> **Read this before touching `baseline.json`, `New-Baseline.ps1`, or the
> `baselineUrl` field.** Getting the baseline wrong does not fail quietly — it
> turns PLAY off for everyone simultaneously.

---

## Why it exists

`manifest.json` describes the ~480 files we publish and says nothing about the
other 16 GB. So a client carrying a `patch-enUS-X.MPQ` from some other server, or
a truncated `common.MPQ`, was indistinguishable from a healthy one. The launcher
happily said "Ready", and the problem surfaced at the login screen as
`version_gate.lua` kicking the player ~25 s in — which reads to them as *the
realm is broken*, not *my client is*.

That is exactly what happened to a new player on 2026-08-05: disconnected every
30 seconds, diagnosed in guild chat by another player, left before reading the
answer.

`baseline.json` is the other half. Between the two, every file under a checked
root is either accounted for or, by construction, not part of any release we
shipped.

## The two halves

| | `manifest.json` | `baseline.json` |
|---|---|---|
| Describes | what we publish | the stock client underneath |
| Files | ~481 | 162 |
| Regenerated | every release | essentially never |
| Hosted | GitHub raw | the VPS patch host |
| Repair source | the manifest's own URLs | `http://152.53.115.249/base/` |

On a collision the **manifest wins**. Our patches live in the same folder as the
stock ones, and a stale baseline entry must never override the file we are
shipping today.

## What is checked, and what is deliberately not

```
Data\**                  every file, hashed          <- foreign MPQs land here
<root>\*.exe, *.dll      non-recursive, hashed
Interface\AddOns\Uncapped*, StatFeed, ...            <- via manifest.json

Interface\               NOT scanned for foreign files
Cache\  WTF\  Logs\  Errors\  Screenshots\           NOT touched at all
```

**`Interface\` is excluded on purpose.** Our own addons are hash-verified through
the manifest, so a tampered `UncappedVault.lua` still blocks PLAY. But everyone
else's addons are their business — the ChromieCraft repack alone ships Dominos,
Postal, Recount, GTFO, Scrap and ArkInventory, and most players add more.
Treating someone's Dominos install as evidence of an illegitimate client would
fire the warning for nearly everyone and would be untrue. Third-party addons stay
the job of `ForeignAddOnScanner`, which names them once and never touches them.

`Cache` and `WTF` are excluded by the owner's instruction. `Logs`, `Errors` and
`Screenshots` are the same class of player-generated data and are excluded for
the same reason: a screenshot is not tampering.

## required vs informational

Only `required` entries block PLAY or get hosted for repair — MPQs, EXEs, DLLs.
The long tail (`Credits.html`, `Documentation\`, the `.url` shortcuts) is
verified when it matches and ignored when it does not.

That is not laziness. There are **two legitimate ways to get the client** — the
ChromieCraft torrent and the Internet Archive's split zips, both in
`manifest.client` — and they need not agree on that tail. A cosmetic difference
between two genuine installs must not read as tampering.

## What happens to the player

| Finding | PLAY | What they see |
|---|---|---|
| Required file missing or wrong hash | **OFF** | "N of your game files are not right" + REPAIR |
| Only unrecognised extras | **ON** | "We cannot recognise this as a legitimate Uncapped client" + REPAIR |
| Informational file missing/differs | ON | nothing |
| Clean | ON | nothing |

Repair re-downloads broken files without asking (our file, our replacement), and
for foreign `Data\**\*.MPQ` it lists them by name, asks, then **moves** them to
`Data\_disabled\`. Never deletes. The file may be the only copy someone has, and
the standing rule about not deleting software we did not write applies hardest
here.

## Performance — why this is affordable

Hashing 17 GB costs ~10 s on NVMe and several minutes on a spinning disk, which
is not something to spend on every launch. `LauncherState.VerifiedFiles` caches
each hash against the file's `(size, last-write-time)`; any rewrite invalidates
it.

Measured on a real client: **cold 9.8 s / 17 GB hashed, warm 0.01 s / 0 MB.**

If you change what is hashed, re-measure both numbers. The warm pass is what
every player experiences on every launch after the first.

---

## Regenerating the baseline

You should almost never need to. The stock 3.3.5a client does not change. Do it
only if the client we distribute changes, or to add a locale.

```powershell
.\tools\New-Baseline.ps1 -ClientDir 'C:\Wotlk\Client\ChromieCraft_3.3.5a - Copy'
bash tools/Publish-Baseline.sh          # uploads + verifies hashes on the host
python tools/verify-base-host.py        # ★ REQUIRED — see below
scp baseline.json root@152.53.115.249:/srv/uncapped-patches/public/baseline.json
```

★★ **`verify-base-host.py` is not optional, and running it here is the whole point.**
`preflight-release.sh` §6 runs it and fails the release if it does not pass — but **a baseline
publish done on its own never touches preflight**, and that standalone path is exactly the one the
2026-08-12 incident took. Running it as part of this sequence is what closes that gap.

By default it checks presence and length only. `PREFLIGHT_HASH_BASE=1` makes it hash the bytes the
host actually serves (~30 MB) — worth it whenever the uploaded set changed.

### Source the bytes from a client you trust

Whatever is in `-ClientDir` becomes what every player is told is correct. Prefer
an install that has never been used for testing. `New-Baseline.ps1` already skips
manifest-managed files, launcher artefacts (`Wow.exe`, `UncappedClient.dat`,
`realmlist.wtf`, …) and working files (`*.retired-*`, `*.bak`, `*.log`), but it
cannot tell a deliberate edit from a legitimate file.

**Cross-check before publishing.** The current baseline was validated by hashing
the base MPQs in three independent installs (ChromieCraft, Peloria, our own dev
client) and confirming all 26 required files agree. Two clients is the minimum.

### Then prove it against real clients

```powershell
cd tests\IntegrityTests
dotnet run -c Release                              # 34 synthetic cases
dotnet run -c Release -- "C:\Wotlk\Client\Uncapped_NativeCT"
```

The second form runs the **published** baseline and manifest against a real
install and prints the cold and warm timings. The synthetic cases prove the
logic; this proves the data. Do not publish on failures you cannot explain.

Note `dotnet run -- --nologo` puts `--nologo` in `args[0]` and it gets treated as
the client path. Leave it off.

---

## The off switch

`baselineUrl` in the manifest. Empty or absent disables integrity verification
entirely and falls back to checking only the manifest's files — the pre-1.10
behaviour.

Set it with `New-Manifest.ps1 -BaselineUrl ''`. It is a **parameter with a
default**, not a value inherited from the previous manifest, precisely so an
omission cannot silently disable the feature the way the `launcherUrl` omission
silently broke self-update for three days.

`baseline.json` is served `Cache-Control: no-store`, so correcting a false
accusation does not mean waiting out a cache.

## Adding a locale

Today's baseline is enUS. On a client of any other language, every
`Data\<locale>\` file is skipped rather than failed — a legitimate deDE install
must not be called tampered with.

The honest cost: **on a non-enUS client a foreign `patch-deDE-X.MPQ` goes
unnoticed.** That is a limit of publishing one baseline. Fix it by generating one
per locale (`New-Baseline.ps1 -Locale deDE` against a deDE client) and having the
launcher pick by detected locale — not by tightening the check and accusing
people.

An early version of this code got that wrong and reported a deDE client's own
`Data\deDE` folder as foreign. The test `locale mismatch: no complaints about the
client's own locale folder` exists to keep it fixed.

---

## Hosting

`/srv/uncapped-patches/public/base/` on the VPS, 17 GB, served by the same nginx
container as the patches under the same strict-allowlist rules: an explicit
`location` regex, a mandatory `-<build>` suffix in every filename, no autoindex,
no root fallback, `GET`/`HEAD` only.

Filenames flatten the path — `Data/enUS/base-enUS.MPQ` is served as
`Data-enUS-base-enUS-12340.MPQ` — so a hypothetical `Data/base-enUS.MPQ` cannot
collide with it in the flat directory.

The config's source of truth is `tools/patch-host-nginx.conf` in this repo. It
used to exist **only** on the VPS; keep the two in step.

### This path does not go through `publish.sh`

The MPQ patches are published with `/opt/uncapped-files/publish.sh`, which
enforces immutability, name validity and hashes. The baseline files bypass it —
they are uploaded once by `Publish-Baseline.sh`, which does its own post-upload
verification by hashing **on the host** and refusing to report success on a
mismatch.

`list.sh` on the VPS does **not** list `base/`. If you extend the baseline, that
is worth fixing.

---

## Things that will bite you

- **`New-Manifest.ps1` regenerates from `payload/`.** For a launcher-only or
  baseline-only change, hand-edit `manifest.json` instead — see the stray-patch
  warning in `PUBLISHING-ADDONS.md`.
- **Windows Python writes CRLF.** Piping a generated file list into bash glues a
  `\r` onto the last field and arithmetic on it fails with a useless error.
  `tr -d '\r'`. This has now caused a bug here and in a URL list before it.
- **`state.json` cannot be redirected.** `AppPaths` uses `GetFolderPath`, which
  ignores `%LOCALAPPDATA%`. Anything that constructs a `LauncherState` and calls
  `Save()` writes the player's real state file. The test harness backs it up and
  restores it; do the same in anything else you write.
- **The verifier throwing must never mean "play anyway."** It blocks and says the
  check did not finish. If you add a code path here, keep that property.
