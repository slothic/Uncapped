using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// What a factory reset is about to do, worked out before anything is touched so the player
/// can be shown it and say no.
/// </summary>
public sealed record FactoryResetPlan(
    IReadOnlyList<string> OurAddOns,
    IReadOnlyList<string> ForeignAddOns)
{
    /// <summary>Settings are always reset; addons may be nothing to do on a clean install.</summary>
    public bool AnythingToRemove => OurAddOns.Count > 0 || ForeignAddOns.Count > 0;
}

public sealed record FactoryResetOutcome(
    int OurAddOnsCleared,
    int ForeignAddOnsRemoved,
    bool SettingsReset,
    int AddOnListsReset,
    List<string> Errors);

/// <summary>
/// Puts an install back to what a new one would be: our settings, our addons, and nothing
/// else.
///
/// ★★ THIS IS THE ONE PLACE THE LAUNCHER DELETES ADDONS THE PLAYER CHOSE, AND IT IS NOT
/// REVERSIBLE.
///
/// Everywhere else the standing rule holds — foreign MPQs are MOVED to Data\_disabled, third
/// party addons are left alone, retired addons are unticked rather than removed. REPAIR is the
/// deliberate exception, on the owner's instruction (2026-09-06): a button called "repair"
/// that leaves a broken third-party addon in place has not repaired anything, and the whole
/// reason someone presses it is that they want to be back at a known-good client.
///
/// So the licence to be destructive comes from three things together, and none of them are
/// optional:
///
///   1. the player pressed REPAIR,
///   2. they were shown the list of folders by name and confirmed it,
///   3. the dialog said plainly that the addons are deleted, not moved.
///
/// <see cref="Plan"/> exists to make (2) possible: nothing is touched until the caller has the
/// list in hand and comes back with it.
///
/// WHAT IS DELIBERATELY LEFT ALONE
///
/// Characters, keybindings and macros. They live in WTF alongside the settings this resets,
/// they are not "settings" in the sense anyone means when they ask for a client put back to
/// stock, and we have no stock version of them to restore — a reset that silently wiped
/// someone's keybinds would be a far worse bug than the one it was pressed to fix.
/// </summary>
public static class FactoryReset
{
    /// <summary>
    /// Works out which addon folders would go, without touching anything.
    ///
    /// The two lists are kept apart because they mean different things to a player: ours are
    /// deleted and immediately re-downloaded by the sync that follows, theirs are deleted and
    /// gone. The dialog says so.
    /// </summary>
    public static FactoryResetPlan Plan(string installPath, Manifest manifest)
    {
        var dir = Path.Combine(installPath, "Interface", "AddOns");

        var ours = OurAddOnNames(manifest)
            .Where(name => Directory.Exists(Path.Combine(dir, name)))
            .OrderBy(n => n, StringComparer.OrdinalIgnoreCase)
            .ToList();

        // Everything the scanner does not recognise, plus anything queued for removal that a
        // sync failed to delete. Distinct because a stubborn removeAddOns entry appears in
        // both — the scanner treats those names as known precisely so they are not reported
        // twice on a normal launch.
        var foreign = ForeignAddOnScanner.Scan(installPath, manifest)
            .Concat(manifest.RemoveAddOns.Where(n => Directory.Exists(Path.Combine(dir, n))))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(n => n, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new FactoryResetPlan(ours, foreign);
    }

    /// <summary>
    /// Carries out the plan. The caller must already have confirmed it.
    ///
    /// Nothing here throws: a reset that fails halfway is reported item by item and the sync
    /// that follows repairs whatever it can. Throwing would abandon the re-download that is
    /// the entire point of deleting our own addons.
    /// </summary>
    public static FactoryResetOutcome Apply(
        string installPath, Manifest manifest, FactoryResetPlan plan, LauncherState state)
    {
        var errors = new List<string>();

        var ourCount = 0;
        foreach (var name in plan.OurAddOns)
            if (AddOnRemover.Remove(installPath, name, errors)) ourCount++;

        var foreignCount = 0;
        foreach (var name in plan.ForeignAddOns)
            if (AddOnRemover.Remove(installPath, name, errors)) foreignCount++;

        var listsReset = ResetAddOnLists(installPath, errors);
        var settingsReset = ResetSettings(installPath, errors);

        /*
         * Forget what we thought was on disk — but only the parts that stopped being true.
         *
         * ★ NOT a blanket VerifiedFiles.Clear(). That cache is what makes verifying a 16 GB
         * client affordable: emptying it costs a full re-hash of every MPQ on the next pass,
         * minutes of it on a spinning disk, to re-learn hashes for files this reset never went
         * near. Dropping the entries whose file is actually gone is the same correctness for
         * none of the cost — and a file that was deleted and downloaded again invalidates its
         * own entry anyway, since the cache is only trusted while size AND write time match.
         *
         * InstalledArchives is cleared outright, for a different reason: it is the ONLY record
         * that an archive has been unpacked, and SyncService consults it BEFORE it looks at the
         * disk. Not clearing it is how ArkInventory gets deleted here and never comes back.
         */
        foreach (var path in state.VerifiedFiles.Keys.ToList())
            if (!File.Exists(Path.Combine(installPath, path)))
                state.VerifiedFiles.Remove(path);

        state.InstalledArchives.Clear();
        state.InstalledFiles = state.InstalledFiles
            .Where(p => File.Exists(Path.Combine(installPath, p)))
            .ToList();

        // The manifest hash is what lets PLAY skip the sync. After this the install no longer
        // matches it, and the next pass must not be allowed to conclude otherwise.
        state.LastManifestHash = null;
        state.Save();

        Log.Write($"factory reset: cleared {ourCount} of our addon(s), removed {foreignCount} " +
                  $"foreign addon(s), reset {listsReset} addon list(s), " +
                  $"settings {(settingsReset ? "reset" : "unchanged")}, {errors.Count} error(s)");

        return new FactoryResetOutcome(ourCount, foreignCount, settingsReset, listsReset, errors);
    }

    /// <summary>
    /// Every addon folder that is ours: the ones the manifest owns outright, plus the ones we
    /// install on the player's behalf from someone else's zip.
    ///
    /// Derived from <see cref="Manifest.OwnedPaths"/> rather than a hardcoded list, for the
    /// same reason <see cref="ForeignAddOnScanner"/> is: a list in the code drifts the first
    /// time an addon is added and nobody remembers this file exists.
    /// </summary>
    private static IEnumerable<string> OurAddOnNames(Manifest manifest)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var owned in manifest.OwnedPaths)
        {
            var parts = owned.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);

            // ownedPaths also carries Data/enUS, which is not an addon and must not be deleted
            // here — the MPQs it holds are gigabytes and repair restores them by name.
            if (parts.Length == 3 &&
                parts[0].Equals("Interface", StringComparison.OrdinalIgnoreCase) &&
                parts[1].Equals("AddOns", StringComparison.OrdinalIgnoreCase))
            {
                names.Add(parts[2]);
            }
        }

        // Archives, and the sibling folders that ride along inside them (ArkInventory's zip
        // also contains ArkInventoryRules). Same prefix rule the scanner uses, for the same
        // reason: the manifest carries an archive's name, never its contents.
        foreach (var archive in manifest.Archives)
            if (!string.IsNullOrWhiteSpace(archive.Name)) names.Add(archive.Name);

        return names;
    }

    /// <summary>
    /// Deletes every AddOns.txt so the client rebuilds them.
    ///
    /// Rewriting them line by line would be the fussier option and a worse one: the file is a
    /// list of every addon the player has ever had, including the ones just deleted, and the
    /// client treats an ABSENT addon as enabled. Starting from nothing is the only way to be
    /// sure a retired addon is not left ticked. <see cref="AddOnsTxtEnforcer"/> writes our own
    /// on and off rules back on the same pass.
    /// </summary>
    private static int ResetAddOnLists(string installPath, List<string> errors)
    {
        var wtf = Path.Combine(installPath, "WTF");
        if (!Directory.Exists(wtf)) return 0;

        var reset = 0;
        try
        {
            foreach (var file in Directory.EnumerateFiles(wtf, "AddOns.txt", SearchOption.AllDirectories))
            {
                try { File.Delete(file); reset++; }
                catch (Exception ex) { errors.Add($"{Path.GetFileName(file)}: {ex.Message}"); }
            }
        }
        catch (Exception ex) { errors.Add($"AddOns.txt: {ex.Message}"); }

        return reset;
    }

    /// <summary>
    /// Puts Config.wtf back to the settings a fresh install gets.
    ///
    /// The account name survives, and only the account name. It is not a setting — it is the
    /// thing the player typed once so they would not have to type it again, and losing it to a
    /// repair would be a small daily annoyance with nothing to gain from it.
    ///
    /// The file is deleted rather than edited key by key, because "reset to stock" has to mean
    /// the keys we do NOT write as well. A gxRefresh or a graphics setting left over from
    /// whatever went wrong is exactly the kind of thing that survives a repair and keeps the
    /// client broken.
    /// </summary>
    private static bool ResetSettings(string installPath, List<string> errors)
    {
        try
        {
            /*
             * ⚠ EVERYTHING IS READ BEFORE ANYTHING IS DELETED.
             *
             * The window between removing the file and writing the new one is the only moment
             * this client can be left with no Config.wtf at all, and a client with no config
             * boots into EXCLUSIVE FULLSCREEN — the mode that crashes this build on a wide
             * range of machines. So nothing that can throw is allowed to happen inside that
             * window: the account name and the stock values are both in hand first, and the
             * only step left is the write.
             *
             * The backstop if it fails anyway: DisplayMode.ForceWindowed runs on every PLAY
             * with createIfMissing set, so a missing config is repaired before the game ever
             * starts. That is a safety net, not the plan.
             */
            var accountName = ConfigWtf.Read(installPath, "accountName");
            var values = new Dictionary<string, string>(FirstRunConfigurator.StockSettings(installPath));
            if (!string.IsNullOrWhiteSpace(accountName)) values["accountName"] = accountName!;

            var path = ConfigWtf.PathFor(installPath);
            if (File.Exists(path)) File.Delete(path);

            /*
             * realmList is deliberately NOT in the stock set, and is therefore gone until
             * ClientConfigWriter.WriteRealmlist puts it back. That is safe only because the
             * caller runs a full sync straight after this, and the sync writes it. Anything
             * that ever calls FactoryReset WITHOUT a sync behind it must write the realmlist
             * itself, or the player is left pointed at Blizzard's servers.
             */
            ConfigWtf.Update(installPath, values, createIfMissing: true);
            return true;
        }
        catch (Exception ex)
        {
            errors.Add($"Config.wtf: {ex.Message}");
            return false;
        }
    }
}
