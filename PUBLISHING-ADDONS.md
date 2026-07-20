# Publishing addon changes to the launcher

**For an assistant session that has just changed a client addon.** Follow this and players get
the change on their next launch. You do not need to understand the launcher to do this.

Nothing here builds or releases the launcher. Addon changes never need either.

---

## Where addons come from

| Addon | Source of truth | Who owns it |
|---|---|---|
| `StatFeed`, `ReagentBankCraft` | `C:\Wotlk\Server\azerothcore-wotlk\client_addons\<Name>\` | **Ours.** Edit here. |
| Astrolabe, WDM, QuestHelper | `C:\Wotlk\Addons\upstream\*.zip` | Trimitor's releases. Refresh with `Update-Upstream.ps1`. |
| Everything else | `C:\Wotlk\Addons\*.zip` | Third party. Leave alone. |

Edit **only** `client_addons\`. Do not edit `C:\Wotlk\Launcher\payload\` — it is generated and
wiped on every build.

---

## The two commands

```powershell
cd C:\Wotlk\Launcher\tools
.\Build-Payload.ps1 -Clean
.\New-Manifest.ps1 -BaseUrl "https://raw.githubusercontent.com/slothic/Uncapped/main/payload" `
                   -LauncherVersion "<CURRENT>" `
                   -LauncherUrl "https://github.com/slothic/Uncapped/releases/download/v<CURRENT>/Uncapped.exe"
```

**`<CURRENT>` must be the version already live.** Read it first and reuse it verbatim:

```powershell
(Invoke-RestMethod "https://raw.githubusercontent.com/slothic/Uncapped/main/manifest.json").launcherVersion
```

Getting this wrong is the one way to break things: naming a version with no matching GitHub
release points every player's self-update at a 404. `New-Manifest.ps1` recomputes the hash
from the local build, so passing the current version keeps it consistent.

Then commit and push:

```powershell
cd C:\Wotlk\Launcher
git add -A
git commit -m "Update <Addon>: <what changed>"
git push origin main
```

Players pick it up on their next launch — and now also whenever they press PLAY.

---

## Before you push, check these

**Did the payload actually change?** If `git status` shows only `manifest.json`, the addon
files were byte-identical and there is nothing to publish. This has happened more than once.

**Is every new file listed in the `.toc`?** A `.lua` that is not named in the `.toc` is
downloaded and then ignored by the client. Adding a file means adding a line:

```
## Interface: 30300
## Title: Reagent Bank Craft
## Author: Uncapped

ReagentBankCraft.lua
Wishlist.lua        <- new files go here too
```

**Never commit a webhook or token.** `src\Uncapped\webhook.local.txt` is gitignored and must
stay that way. This repo is public. Quick check:

```powershell
git diff --cached | Select-String "discord.com/api/webhooks"
```

---

## Verify it landed

```powershell
$u = "https://raw.githubusercontent.com/slothic/Uncapped/main/manifest.json?_=" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$m = (New-Object Net.WebClient).DownloadString($u).TrimStart([char]0xFEFF) | ConvertFrom-Json
$m.files | Where-Object { $_.path -like "*<YourAddon>*" } | Select-Object path, size
```

**`raw.githubusercontent.com` caches for about 5 minutes and its CDN keys on path, so the
cache-buster above does not reliably defeat it.** If you still see the old size, wait and
re-check rather than assuming the push failed. Confirm the repo itself is right with:

```powershell
git show origin/main:manifest.json | Select-String '"launcherVersion"'
```

---

## What you must not do

- **Do not bump `launcherVersion` or cut a GitHub release.** Addon changes ship through the
  payload alone. Releases are only for launcher code changes.
- **Do not edit `payload\`** — generated, wiped by `-Clean`.
- **Do not delete third-party addons from the payload.** The launcher never removes addons it
  did not write, deliberately, in case a player installed their own copy. Only `StatFeed` and
  `ReagentBankCraft` are under `ownedPaths` and therefore prunable.
- **Do not add an addon that reserves all rights.** `Build-Payload.ps1` already excludes
  AckisRecipeList, ArkInventory and ArkInventoryRules for this reason — see
  `ADDON-LICENCES.md`. Do not remove them from `$licenceExcluded` without the author's
  permission.
- **Do not run the launcher while the owner has it open.** It is single-instance, and it
  shares `%LOCALAPPDATA%\Uncapped\state.json`. Two sessions racing that file has caused real
  confusion. Check first: `Get-Process Uncapped`.

---

## Retiring a broken addon

Removing it from the payload is **not** enough — the launcher never deletes third-party
addons, so anyone who already has it keeps loading the broken copy. Do both:

1. Add it to `$temporarilyDisabled` in `tools\Build-Payload.ps1` (stops shipping it).
2. Add it to `-ForceDisableAddOns` in `tools\New-Manifest.ps1` (unticks it in `AddOns.txt` on
   clients that already have it, without deleting anything).

`QuestHelper` is the worked example of this, in both files.

---

## Posting news about the change

News is a separate file, not part of the manifest:

```
C:\Wotlk\Server\azerothcore-wotlk\webregistration\news.json
```

That folder is bind-mounted as Apache's document root, so **saving the file publishes it** —
no rebuild, no restart, no push. Newest entry first:

```json
[
  { "date": "2026-07-21", "title": "Short headline", "body": "A sentence or two players will actually read." }
]
```

Limits: 40 entries, 90-char titles, 1200-char bodies. Check it with:

```powershell
(Invoke-RestMethod "http://91.100.105.22:8080/news.json").Count
```

Note the file is currently **untracked** in the server repo — it serves fine, but `git clean`
there would delete it.

---

## If something goes wrong

- **`New-Manifest.ps1` throws "Serialisation produced no output"** — good, it caught itself.
  It refuses to write an empty manifest and re-reads what it wrote to confirm the entry count.
  Usually a PowerShell parse problem: keep the `.ps1` files ASCII-only and BOM-encoded.
  Windows PowerShell 5.1 reads BOM-less scripts as ANSI, and a stray em-dash decodes into a
  smart quote that silently terminates a string.
- **Players report the addon is not updating** — check the manifest actually lists it and the
  size matches, then have them check `%LOCALAPPDATA%\Uncapped\launcher.log`.
- **You already pushed a bad `launcherVersion`** — re-run `New-Manifest.ps1` with the correct
  current version and push again. Self-update fails safe: it logs, keeps the old exe, and
  carries on.
