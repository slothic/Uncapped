namespace Uncapped.Services;

public sealed record InstallCandidate(string Path, string Source);

/// <summary>Why a folder was rejected, in words a player can act on.</summary>
public sealed record InstallCheck(bool Ok, string Reason)
{
    public static readonly InstallCheck Good = new(true, "");
}

/// <summary>
/// Finds the 3.3.5a install: the launcher's own folder, then whatever the player last chose,
/// then the player. Validation is structural — an executable, a Data folder, a locale folder
/// the client can boot from — plus a version check that only ever rules a client OUT, since
/// repacks make version strings too unreliable to rule one in (see <see cref="ClientBuild"/>).
///
/// WHAT THIS NO LONGER DOES
///
/// It used to sweep the registry and a list of likely paths across every fixed drive. That
/// found *an* install, not necessarily ours: a player with a Warmane or ChromieCraft folder
/// got the launcher silently syncing our payload into someone else's client, and the first
/// they knew about it was the game not starting. The launcher ships beside the client it
/// manages, so the folder it is sitting in is the answer almost every time, and the rest of
/// the time asking is better than guessing.
/// </summary>
public static class InstallLocator
{
    /// <summary>
    /// Accepts either the stock Wow.exe or the renamed client, so an install stays
    /// recognisable after hardening.
    /// </summary>
    public static bool IsValidInstall(string? path) => Validate(path).Ok;

    /// <summary>
    /// Structural validation, with the locale folder included.
    ///
    /// The locale check is the whole point of this being more than a File.Exists. A client
    /// with Data\ but no playable locale folder installs, launches, and fails with "Cannot
    /// stream required archive data" — the client's way of saying an archive it needs is not
    /// there. Catching it at the folder picker turns a mystifying error at the loading screen
    /// into a sentence at the moment the player chose the folder.
    /// </summary>
    public static InstallCheck Validate(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return new InstallCheck(false, "No folder was given.");
        if (!Directory.Exists(path)) return new InstallCheck(false, "That folder does not exist.");

        if (!ClientExecutable.Exists(path))
            return new InstallCheck(false,
                "There is no game executable in that folder. It should contain Wow.exe.");

        if (!Directory.Exists(Path.Combine(path, "Data")))
            return new InstallCheck(false, "That folder has no Data folder in it.");

        var expansion = ClientBuild.Describe(path);
        if (expansion is not null)
            return new InstallCheck(false,
                $"That is a {expansion} client. Uncapped runs on Wrath of the Lich King " +
                "3.3.5a (build 12340).");

        var locales = ClientLocale.Scan(path);

        if (locales.Count == 0)
            return new InstallCheck(false,
                "That client has no language folder in Data (enUS, enGB and so on), so it " +
                "cannot start. The download is probably incomplete.");

        if (!locales.Any(l => l.IsPlayable))
        {
            var names = string.Join(", ", locales.Select(l => l.Code));
            return new InstallCheck(false,
                $"The language folder in Data ({names}) is missing its game data — there is no " +
                $"locale or base MPQ in it. The download is probably incomplete.");
        }

        return InstallCheck.Good;
    }

    /// <summary>
    /// Candidates in the order they should be trusted. Empty means ask the player, which the
    /// caller must be prepared for — there is no longer a guessing tier behind this.
    /// </summary>
    public static IEnumerable<InstallCandidate> Discover(string? remembered)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        InstallCandidate? Accept(string? p, string source)
        {
            if (!IsValidInstall(p)) return null;
            var full = Path.GetFullPath(p!).TrimEnd('\\');
            return seen.Add(full) ? new InstallCandidate(full, source) : null;
        }

        // First: where the launcher itself is. Shipping inside the client folder is the
        // supported layout, so this is the case that should never involve a dialog.
        var beside = Accept(AppPaths.ExeDir, "launcher folder");
        if (beside is not null) yield return beside;

        // Then the folder the player pointed us at themselves. Not a guess — an explicit
        // earlier choice — so it survives, and a launcher run from the desktop still finds
        // the client without asking again.
        var r = Accept(remembered, "remembered");
        if (r is not null) yield return r;
    }

    /// <summary>
    /// True if the install sits under Program Files, where writing addons and MPQs needs
    /// elevation. The launcher reports this rather than silently failing halfway through a
    /// sync — a partial write into Data\ is worse than a clean refusal.
    /// </summary>
    public static bool NeedsElevation(string installPath)
    {
        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var full = Path.GetFullPath(installPath);

        bool Under(string root) =>
            !string.IsNullOrEmpty(root) &&
            full.StartsWith(Path.GetFullPath(root), StringComparison.OrdinalIgnoreCase);

        if (!Under(pf) && !Under(pf86)) return false;
        return !CanWrite(installPath);
    }

    /// <summary>Probes writability directly — the only answer that actually matters.</summary>
    public static bool CanWrite(string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            var probe = Path.Combine(dir, $".uncapped-write-test-{Guid.NewGuid():N}");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }
}
