using Microsoft.Win32;

namespace Uncapped.Services;

public sealed record InstallCandidate(string Path, string Source);

/// <summary>
/// Finds the 3.3.5a install: remembered path, then registry, then common locations, then the
/// player. Validation is deliberately structural (Wow.exe + Data\) rather than a version
/// check — private-server clients are repacked in ways that make version strings unreliable.
/// </summary>
public static class InstallLocator
{
    private static readonly string[] RegistryKeys =
    {
        @"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
        @"SOFTWARE\Blizzard Entertainment\World of Warcraft",
    };

    private static readonly string[] RegistryValues = { "InstallPath", "GamePath" };

    public static bool IsValidInstall(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return false;
        return File.Exists(Path.Combine(path, "Wow.exe"))
            && Directory.Exists(Path.Combine(path, "Data"));
    }

    public static IEnumerable<InstallCandidate> Discover(string? remembered)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        InstallCandidate? Accept(string? p, string source)
        {
            if (!IsValidInstall(p)) return null;
            var full = Path.GetFullPath(p!).TrimEnd('\\');
            return seen.Add(full) ? new InstallCandidate(full, source) : null;
        }

        var r = Accept(remembered, "remembered");
        if (r is not null) yield return r;

        foreach (var key in RegistryKeys)
        {
            foreach (var valueName in RegistryValues)
            {
                string? value = null;
                try { value = Registry.LocalMachine.OpenSubKey(key)?.GetValue(valueName) as string; }
                catch { /* registry access can fail under lockdown policies; not fatal */ }

                var c = Accept(value, "registry");
                if (c is not null) yield return c;
            }
        }

        foreach (var guess in CommonLocations())
        {
            var c = Accept(guess, "common location");
            if (c is not null) yield return c;
        }
    }

    private static IEnumerable<string> CommonLocations()
    {
        var roots = DriveInfo.GetDrives()
            .Where(d => d.DriveType == DriveType.Fixed && d.IsReady)
            .Select(d => d.RootDirectory.FullName);

        var suffixes = new[]
        {
            @"Games\WoW335", @"Games\World of Warcraft", @"WoW335", @"World of Warcraft",
            @"Wotlk\Client\ChromieCraft_3.3.5a",
            @"Program Files (x86)\World of Warcraft", @"Program Files\World of Warcraft",
        };

        foreach (var root in roots)
            foreach (var s in suffixes)
                yield return Path.Combine(root, s);
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
