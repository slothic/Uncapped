# Publishing a client change

The runnable client is **built on the player's machine**, from a pristine base file plus a
list of byte patches carried in the manifest. Shipping a client-side hex patch is therefore a
manifest edit and **zero bytes of client download** — not a 7.7 MB re-download for every
player, which is what it cost until 2026-09-06.

```
UncappedBase.dat  ──(clientPatch.patches)──▶  UncappedClient.dat
   pinned, synced,                               derived locally,
   never touched                                 verified by resultSha256
```

---

## Why it is split this way

Patching the installed client in place is not an option, and the reason is not obvious:

> `SyncService.IsCurrentAsync` re-hashes **every** manifest file against its pin on **every**
> launch. A launcher that edited the installed client would find it mismatched a moment
> later and re-download it. Every launch. Forever.

That is also why `LargeAddressAware` never actually did anything: every `.dat` we ever
published already had the flag set at source, so `Apply()` hit its early return. The one
existing example of the launcher editing the installed client was a path that had never run
in production — which is why nobody had noticed it could not work.

Splitting the two resolves it. The base is an ordinary pinned manifest file that the sync
verifies and nothing ever modifies. The derived client is **not a manifest entry at all**, so
the sync has no opinion about it, and `ClientPatcher` owns its correctness end to end.

⚠ **Never list the derived client in `external-files.json`.** `New-Manifest.ps1` refuses a
manifest where the same path is both published and derived, because that is exactly the
re-download loop above.

---

## The three checks

`ClientPatcher` throws the whole build away if any of them fails, and only ever replaces the
existing client with a file that passed all three:

1. the base must hash to `baseSha256` before a byte is read;
2. every patch states the bytes it **expects** to find. This is what makes a build-locked
   patch safe to apply on a machine we cannot see — the mouse-cam fix is a set of hardcoded
   displacements correct for exactly one build, and it cannot be written onto a different one;
3. the finished image must hash to `resultSha256`.

Nothing is edited in place, so a failed build leaves the player exactly as they were. That is
the difference between "press CHECK FOR UPDATES again" and "reinstall".

---

## Adding a patch

1. **Author it** in `tools\client-patches.json`. Offsets are FILE offsets into the base.
   Every entry needs `id`, `note`, `offset`, `expect`, `write`, and `expect`/`write` must be
   the same length — a patch that changed the file's size would move every later offset.

2. **Build and verify:**

   ```
   python C:\Wotlk\Launcher\tools\Build-ClientPatch.py
   ```

   It self-tests its PE checksum fold against the stock client's own stored value, applies
   the list, writes the derived client, and emits `tools\client-patch-block.json`. It refuses
   to write anything if a patch does not find the bytes it expects.

3. **Smoke-test the derived client** before publishing. It is at
   `C:\Wotlk\backups\clientpatch\UncappedClient-derived.dat`. Launch it directly — the
   extension does not matter to `CreateProcess`, and the launcher would revert it while the
   manifest is stale:

   ```powershell
   Start-Process -FilePath C:\Wotlk\backups\clientpatch\UncappedClient-derived.dat -WorkingDirectory C:\Wotlk\Client\ChromieCraft_3.3.5a
   ```

4. **Run the harness.** It builds from the real base and asserts the real published hash:

   ```
   dotnet build C:\Wotlk\Launcher\tests\IntegrityTests\IntegrityTests.csproj -c Release
   C:\Wotlk\Launcher\tests\IntegrityTests\bin\Release\net9.0-windows\IntegrityTests.exe
   ```

5. **Publish** with the normal manifest flow. `New-Manifest.ps1` reads the block, cross-checks
   `baseSha256` against the file actually pinned as the base, and refuses a stale block.

The PE checksum is **not** authored by hand — Build-ClientPatch.py computes it over the
finished file and appends it as a final patch entry. That keeps all PE knowledge in the
toolchain; the launcher only copies a file, writes byte ranges and checks a SHA-256.

---

## Changing the base

Rare — the base is stock 3.3.5a 12340 plus the `.unc` import-table section (which is what
loads `UncappedCT.dll`) plus the LAA header bit. It changes only when the **injection
mechanism** does, and a change costs every player a one-off 7.7 MB download.

The current base is byte-identical to the client we shipped as `2026.08.05a`, so its URL
still carries that name: published filenames are immutable and re-uploading the same bytes
under a new name would buy nothing.

To rebuild the split from a whole patched `.dat`:

```
python C:\Wotlk\Launcher\tools\Extract-ClientPatches.py
```

It diffs the shipped client against stock, puts structural differences (PE headers, appended
sections) in the base and code differences in the patch list, then **proves the split** by
replaying the list onto the base and requiring the shipped client back byte for byte.

⚠ After changing the base you MUST re-run `Build-ClientPatch.py`. A patch list cut from one
base and published against another refuses at the first expect check — on every player's
machine, at the same moment. `New-Manifest.ps1` has a check for exactly this, and it is the
one that should stop you.

---

## Rollback

Delete `tools\client-patch-block.json` and regenerate the manifest. With no `clientPatch`
block the launcher patches nothing and runs whatever `UncappedClient.dat` it finds, which is
what every release before 1.13.2 did. Re-pin the whole patched client in
`external-files.json` if you need the old arrangement back.
