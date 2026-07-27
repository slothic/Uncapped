# Addon redistribution audit

Audited 2026-07-20 against the files actually present in `payload\Interface\AddOns\`.

> **Updated 2026-07-20 (later):** `!Astrolabe`, `WDM` and `QuestHelper` now come from
> [Trimitor/WDM-addons](https://github.com/Trimitor/WDM-addons) `1.0.9-stable` instead of the
> older loose copies in `Addons\`, because those are the versions that match the WDM
> dungeon-map patches. Their licence evidence was re-checked after the swap and is materially
> unchanged: Astrolabe is still LGPL, QuestHelper still has no addon-wide grant (see below),
> and WDM's own `.toc` still carries no licence while its bundled libraries declare MIT.
>
> The two `patch-enUS-M/N.MPQ` archives are **not redistributed by us at all** — the manifest
> points players at Trimitor's own release assets, so they are downloaded from the upstream
> author's distribution point.

**Method**: read every `LICENSE`/`COPYING`/`README`, every `.toc` (`## X-License`, `## Author`,
`## Notes`), and grepped all `.lua` for copyright and licence headers. Verdicts come only from
text found in the files — not from general knowledge of the addon. "No statement found" means
exactly that, and is a genuine result rather than a gap in the audit.

**Blizzard addons**: none present. `Build-Payload.ps1` only reads `Addons\` and
`client_addons\`, never a client's `Interface\AddOns\`, so the stock `Blizzard_*` addons were
never in scope. A guard in `Add-AddonFolder` now rejects any `Blizzard_*` name outright, so
this stays true even if the script is later pointed at a client folder.

---

## Excluded from the payload

These reserve all rights in their own files. Shipping them would distribute someone else's
work against their stated terms.

| Addon | Evidence |
|---|---|
| **AckisRecipeList** | `LICENSE.txt`: "Copyright (c) 2009 Ackis / All Rights Reserved unless otherwise explicitly stated." Repeated per-file in `core.lua:12`. |
| **ArkInventory** | `ArkInventory.lua:1`: "-- (c) 2009-2010, all rights reserved." No licence file. |
| **ArkInventoryRules** | `ArkInventoryRules.lua:1`: "-- (c) 2009-2010, all rights reserved." |

To ship one of these, get the author's permission, then remove it from `$licenceExcluded` in
`tools\Build-Payload.ps1`. Until then players can install them by hand — they still work, they
are simply not distributed by us.

### ArkInventory — fetched from upstream instead (2026-07-27)

ArkInventory stays excluded above: we still do not redistribute it, and it is still in
`$licenceExcluded`. What changed is that players no longer install it by hand. The launcher
now downloads **the author's own CurseForge upload** and unpacks it — the same position as the
`patch-enUS-M/N.MPQ` archives, which come from Trimitor's releases rather than from us.

- Declared in `tools\archives.json`, published as `archives[]` in the manifest, installed by
  `SyncService.SyncArchivesAsync`. Nothing of ArkInventory's enters `payload\` or this repo.
- Pinned to CurseForge file id **458795**
  (`ArkInventory-3.02.54_BETA_17-00-Cataclysm.zip`, uploaded 2010-10-12), and pinned by
  sha256, so a changed upstream file is refused rather than installed.
- That file is byte-identical to `Addons\felbite.com-arkinventory-wotlk-arkinventory.zip`
  (both `43d7f2b2…48f2aa7`) — the felbite copy was a mirror of this exact upload. So this
  changes *where the bytes come from*, not what players get.
- The zip contains both `ArkInventory` and `ArkInventoryRules`, which is why the companion
  needs no separate entry. 171 files.
- Not in `ownedPaths`: third-party, so the launcher installs and updates it but will never
  delete it. Not in `forceEnableAddOns` either — its `.toc` is `## DefaultState: Enabled`, so
  it switches itself on and players can still turn it off.

This is the option the standing position below recommends ("link players to the original
download pages instead of mirroring the files"), automated so nobody has to be walked through
it. It does depend on CurseForge continuing to serve that URL; if that ever stops, the choice
goes back to asking the author's permission versus dropping the addon — not to mirroring it.

The author is still active (releases as recently as July 2026), so asking remains a realistic
option and would be the cleaner long-term answer.

---

## Shipped — explicit permission

| Addon | Licence | Where it says so |
|---|---|---|
| !Astrolabe | LGPL 2.1 | `Astrolabe.lua:19` + `lgpl.txt` |
| AllStats | GPLv3 | `AllStats.toc:8` `## License: GPLv3` + `COPYING.rtf` |
| Dominos | BSD 3-clause | `license.txt` + header in every `.lua` |
| Dominos_Cast | BSD 3-clause | `license.txt` + `castBar.lua:7` |
| Dominos_Config | BSD 3-clause | `license.txt` + `general.lua:7` |
| Dominos_Roll | BSD 3-clause | `license.txt` + `rollBar.lua:7` |
| Dominos_XP | BSD 3-clause | `license.txt` + `xp.lua:7` |
| Scrap | GPLv3 | `Scrap.toc` `## X-License` + `Scrap.lua:6` |
| Scrap_Merchant | GPLv3 | `Scrap_Merchant.toc` + `.lua:2-8` |
| Scrap_Options | GPLv3 | `Scrap_Options.toc` + `.lua:2-8` |

---

## Shipped — no licence statement found

Nothing in these folders grants *or* refuses redistribution. That is not the same as
permission; it is an unresolved question that has been recorded rather than answered.

| Addon | Note |
|---|---|
| AutoRepair | Single `.lua`, no header, no licence field. |
| Dominos_Totems | Every other Dominos module ships an identical BSD `license.txt`; this one has neither file nor header. Almost certainly an oversight by the same author, but recorded as found. |
| GTFO | 12 `.lua` files, no licence text anywhere. |
| Postal | Only `Libs\LibStub` is licensed ("Public Domain"). Postal itself carries no terms. |
| QuestCompletist | No author, no licence. `.toc` titled "Felbite Edit". |
| Questomatic | `readme.txt` is usage docs only. |
| Recount | Only the bundled libs are licensed (LibBossIDs public domain, LibSharedMedia LGPL 2.1). Recount itself carries none. |
| WDM | Only the bundled Astrolabe copy is licensed (LGPL 2.1). WDM itself carries none. |
| **QuestHelper** | **Weakest case — treat as unresolved.** The only addon-wide signal is a changelog bullet, `changes.lua:9`: "• GPL'ed the source". There is no GPL text in the folder and no LICENSE file. The MIT header in `config.lua:5` and the BSD header in `arrow.lua:7` cover those two third-party files, not the addon. A changelog line is thin evidence to distribute on. |

**Easy to misread**: Postal, Recount, and WDM all bundle permissively-licensed libraries
(LibStub, Ace3, Astrolabe). That licenses the library, not the addon.

---

## Ours

`StatFeed` and `ReagentBankCraft` are **first-party** — written for this project, alongside
their server-side counterparts (`ReagentBankCrafting.cpp`, `lua_scripts\dungeonstats.lua`).
The "Server" and "Grandmaster Server" author fields in their `.toc` files are placeholders,
not third-party attribution.

Redistribution is therefore not in question: they belong to the realm owner. They carry no
licence header, which is worth adding at some point purely so anyone reading the repo knows
where they stand — but it blocks nothing.

These two are also the only addons the launcher will ever delete (`ownedPaths` in the
manifest), which is correct precisely because they are ours.

---

## Standing position

The three explicit refusals are excluded. The rest ship. For a private realm among friends
this is a defensible line, but "no statement found" is not the same as permission — if this
ever grows beyond a handful of players, the honest fix is to ask the authors or link players
to the original download pages instead of mirroring the files.
