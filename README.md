# Uncapped Launcher

Client launcher and auto-updater for the Uncapped realm (WotLK 3.3.5a, AzerothCore).

Built against the decisions in `HANDOFF_LAUNCHER.md`. See "Answers to the open questions" at
the bottom for what was settled and why.

---

## Layout

| Path | What it is |
|---|---|
| `src\Uncapped\` | The C# / .NET 9 WinForms launcher. |
| `tools\Build-Payload.ps1` | Stages addons + MPQs into `payload\`, normalising zips to folders. |
| `tools\New-Manifest.ps1` | Hashes `payload\` and writes `manifest.json`. |
| `payload\` | Generated. Mirrors the WoW install root. Commit this. |
| `manifest.json` | Generated. The launcher's only source of truth. Commit this. |

---

## Publishing an update

```powershell
cd C:\Wotlk\Launcher\tools
.\Build-Payload.ps1 -Clean
.\New-Manifest.ps1 -BaseUrl https://raw.githubusercontent.com/OWNER/REPO/main/payload
cd ..
git add -A; git commit -m "addons: update StatFeed"; git push
```

Players get it on their next launch. Raw URLs sit behind a ~5 minute CDN cache, so allow a
few minutes; the launcher appends a cache-buster to the manifest request specifically so a
just-pushed manifest is not served stale.

`New-Manifest.ps1` preserves the `news` array in an existing `manifest.json`, so edit news by
hand and regenerate freely.

### Adding news

```json
"news": [
  { "date": "2026-07-20", "title": "StatFeed 1.2", "body": "Stat gains now show in chat." }
]
```

### Releasing a new launcher build

```powershell
cd C:\Wotlk\Launcher\src\Uncapped
dotnet publish -c Release
# upload bin\Release\net9.0-windows\win-x64\publish\Uncapped.exe to a GitHub Release
(Get-FileHash .\bin\Release\net9.0-windows\win-x64\publish\Uncapped.exe -Algorithm SHA256).Hash.ToLower()
```

Then set `launcherVersion`, `launcherUrl`, and `launcherSha256` in the manifest, bump
`<Version>` in `Uncapped.csproj`, and push. Existing installs self-update on next launch.

Self-update is **disabled while `launcherUrl` is null**, which is the current state — set it
when you cut the first release.

---

## Configuration

`uncapped.config.json` sits beside the exe and is created on first run:

```json
{
  "manifestUrl": "https://raw.githubusercontent.com/slothic/Uncapped/main/manifest.json",
  "torrentAllowInbound": false
}
```

`torrentAllowInbound: false` means no inbound listener and no DHT, which avoids the Windows
Firewall dialog on first run. Peer discovery relies on the magnet's trackers. If the swarm
turns out to be hard to reach, set it to `true` and accept the extra prompt.

### Binary size and the runtime prerequisite

The launcher is **framework-dependent**: `Uncapped.exe` is **1.5 MB**, but players need the
**.NET 9 Desktop Runtime** installed. Self-contained would be 109 MB with no prerequisite.

If the runtime is missing the launcher cannot detect it — without the runtime our code never
runs at all. What players see is the .NET apphost's own dialog naming the missing runtime,
with a download link. Worth putting the link in the same place you hand out the launcher:

<https://dotnet.microsoft.com/download/dotnet/9.0/runtime> (choose **Desktop Runtime x64**)

To switch back to a no-prerequisite build, set `<SelfContained>true</SelfContained>` in
`Uncapped.csproj`.

---

## What it does on launch

1. Deletes the previous `.old` self-update leftover.
2. Fetches the manifest. If unreachable but a valid install is remembered, it lets the player
   play offline on whatever they last synced.
3. Self-updates if the manifest advertises a newer version.
4. Finds the install: remembered path → registry → common locations → folder picker. If none,
   offers to torrent the client.
5. Refuses to sync if `Wow.exe` is running, or if the folder needs elevation.
6. Hashes manifest files on disk, downloads only what differs, verifies each download's
   SHA-256 before moving it into place.
7. Writes `realmlist.wtf` (root **and** `Data\enUS\`) and fixes `realmList` in `WTF\Config.wtf`.
8. Force-enables StatFeed and ReagentBankCraft in every `AddOns.txt`.
9. Clears `Cache\WDB` if anything changed.
10. Stays open with news and realm status; `PLAY` launches the game.

---

## Notes for players

**"Windows protected your PC" on first run.** Expected. Click **More info → Run anyway**. The
launcher is not code-signed — signing costs real money and, at this scale, SmartScreen
reputation never accumulates anyway. You will see it once per machine.

**Put the game somewhere other than Program Files.** `C:\Games\WoW335` is ideal. Installing
under `Program Files` means every addon update needs administrator rights. The launcher
detects this and explains it rather than half-failing.

**Close WoW before launching the launcher.** It will not patch a running client.

**You need the .NET 9 Desktop Runtime.** If the launcher will not start and Windows mentions
a missing runtime, install it from
<https://dotnet.microsoft.com/download/dotnet/9.0/runtime> (Desktop Runtime, x64).

---

## Addon licences

21 addon folders ship. **AckisRecipeList, ArkInventory, and ArkInventoryRules are excluded** —
their own files say "all rights reserved", so redistributing them would be shipping someone
else's work against their stated terms. Players can still install those by hand.

Full evidence, including the addons that carry no licence statement at all, is in
[`ADDON-LICENCES.md`](ADDON-LICENCES.md). Read it before making the repo public.

No `Blizzard_*` addons are shipped, and `Build-Payload.ps1` rejects them by name.

---

## Answers to the open questions

| # | Question | Answer |
|---|---|---|
| 1 | Name | **Uncapped**, for both launcher and realm. |
| 2 | GitHub account + repo | `github.com/slothic/Uncapped`. Manifest and payload served from `main`. |
| 3 | Seeding plan | Not needed — this is the public ChromieCraft torrent, already well seeded. |
| 4 | Addon policy | All addons install. No optional split. Players disable what they dislike in-game. |
| 5 | Install location | `%LOCALAPPDATA%\Uncapped\` — no admin, clean self-update. |
| 6 | Shape | Stays open: news panel, realm status, PLAY. |
| 7 | Manage `Config.wtf`? | **Yes** — see below. |
| 8 | Integrity checking | Manifest files only. The 17 GB base client is never hashed. |
| 9 | Rollback | Fix forward. No backup-on-replace, no manifest pinning. |
| 10 | `ChromieCraft_3.3.5a - Copy` | A pre-modification backup, not a ship candidate. Excluded. |

### On making addons undisableable (question 4 follow-up)

There is **no `.toc` flag** in 3.3.5a that makes an addon undisableable — no "secure" or
"protected" marker. Only Blizzard's own namespaced addons get that, and it is hardcoded
client-side.

What works instead: the client stores checkbox state in `WTF\Account\<ACCOUNT>\AddOns.txt` as
`AddonName: enabled`. The launcher rewrites only the lines for **our** addons on every launch.
A player can still untick StatFeed mid-session, but it is back on next time they launch.

That file only exists after the player has logged in once, so the launcher does nothing if it
is absent rather than guessing an account name. No addon is ever removed from the list, and
third-party entries keep whatever state the player chose.

### On `Config.wtf` (question 7)

Yes, and this is almost certainly the realmlist trouble players have already hit. The client
persists `SET realmList` into `WTF\Config.wtf` and honours it over `realmlist.wtf` on many
3.3.5a builds. Editing `realmlist.wtf` alone leaves a stale `Config.wtf` silently overriding
it. The launcher writes all three locations and rewrites only the `realmList` and `realmName`
lines, preserving resolution, volumes, and account name.

### On deleting addons

The launcher prunes only paths listed in the manifest's `ownedPaths` — currently just
`StatFeed` and `ReagentBankCraft`. Third-party addons are install-only: once placed, they are
never deleted, even if they drop out of the manifest. This is verified behaviour, not just
intent.
