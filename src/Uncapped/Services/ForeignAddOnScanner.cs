using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// Finds addons in the client that did not come from us.
///
/// "Ours" is not a hardcoded list — it is derived from the manifest, so it cannot drift as
/// addons are added and retired:
///
///   * every folder under Interface/AddOns that the manifest ships files into,
///   * every archive we install on the player's behalf (ArkInventory and friends),
///   * anything we explicitly force on or off, which we clearly know about,
///   * Blizzard_* , which ships with the game itself.
///
/// Everything else the player installed, and that is worth telling them about exactly once.
/// Nothing here removes or disables anything: a player who wants a third-party addon is
/// entitled to it, and silently deleting other people's software is not our business. The
/// point is that when something breaks, they know where to look first.
/// </summary>
public static class ForeignAddOnScanner
{
    public static IReadOnlyList<string> Scan(string installPath, Manifest manifest)
    {
        var dir = Path.Combine(installPath, "Interface", "AddOns");
        if (!Directory.Exists(dir)) return Array.Empty<string>();

        var known = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // Folders we ship files into.
        foreach (var file in manifest.Files)
        {
            var name = AddOnFolderFrom(file.Path);
            if (name is not null) known.Add(name);
        }

        // Archives we install for the player, which land under Interface/AddOns but are not
        // listed file-by-file in the manifest.
        foreach (var archive in manifest.Archives)
        {
            if (!string.IsNullOrWhiteSpace(archive.Name)) known.Add(archive.Name);

            var name = AddOnFolderFrom(archive.VerifyPath);
            if (name is not null) known.Add(name);
        }

        foreach (var name in manifest.ForceEnableAddOns) known.Add(name);
        foreach (var name in manifest.ForceDisableAddOns) known.Add(name);

        /*
         * Companion folders that ride along inside an archive.
         *
         * ArkInventory's zip also contains ArkInventoryRules, and we cannot enumerate an
         * archive's contents from the manifest -- only its name and one verify path. Matching
         * on prefix catches the siblings. Tested against a live install, which flagged
         * ArkInventoryRules as foreign before this existed.
         */
        var archivePrefixes = manifest.Archives
            .Select(a => a.Name)
            .Where(n => !string.IsNullOrWhiteSpace(n))
            .ToList();

        var foreign = new List<string>();

        foreach (var path in Directory.EnumerateDirectories(dir))
        {
            var name = Path.GetFileName(path);
            if (string.IsNullOrEmpty(name)) continue;

            // Stock UI. Blizzard's own, present in every client.
            if (name.StartsWith("Blizzard_", StringComparison.OrdinalIgnoreCase)) continue;

            if (known.Contains(name)) continue;

            /*
             * Our own addons, shipped or not.
             *
             * Retiring one from the payload does not delete it from a player's folder, so
             * UncappedMountFly and friends linger. Calling those "not ours" would be flatly
             * untrue and would send someone hunting a conflict in software we wrote.
             */
            if (name.StartsWith("Uncapped", StringComparison.OrdinalIgnoreCase)) continue;

            // Sibling folders from an archive we install.
            if (archivePrefixes.Any(p => name.StartsWith(p, StringComparison.OrdinalIgnoreCase)))
                continue;

            // A folder with no .toc is not an addon, just leftover clutter — usually the
            // remains of a half-deleted one. Warning about it would be noise.
            if (!HasToc(path)) continue;

            foreign.Add(name);
        }

        foreign.Sort(StringComparer.OrdinalIgnoreCase);
        return foreign;
    }

    /// <summary>The addon folder name in a path like "Interface/AddOns/Foo/Foo.lua".</summary>
    private static string? AddOnFolderFrom(string? relative)
    {
        if (string.IsNullOrWhiteSpace(relative)) return null;

        var parts = relative.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i + 1 < parts.Length; i++)
        {
            if (parts[i].Equals("AddOns", StringComparison.OrdinalIgnoreCase))
                return parts[i + 1];
        }

        return null;
    }

    private static bool HasToc(string folder)
    {
        try { return Directory.EnumerateFiles(folder, "*.toc").Any(); }
        catch { return false; }   // unreadable folder: not our problem to report
    }
}
