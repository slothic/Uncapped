using System.Diagnostics;

namespace Uncapped.Services;

/// <summary>
/// Tells a 3.3.5a client apart from some other expansion's.
///
/// WHY
///
/// The launcher used to find the install by sweeping the registry, and Blizzard's
/// InstallPath key names whichever World of Warcraft was installed last. On a machine that
/// also had Cataclysm, that is the folder it picked — and a Cata client passes every
/// structural test there is. It has Wow.exe, it has Data\, it has a complete Data\enUS\ with
/// locale and base MPQs in it. The launcher synced our payload into it, wrote a realmlist,
/// and the player got an error that had nothing to do with what actually went wrong.
///
/// Discovery no longer guesses, so this should rarely fire. It stays because the folder
/// picker still exists, and "that is a Cataclysm client" is a far better answer at the picker
/// than anything the game will say later.
///
/// HOW, AND HOW CAREFULLY
///
/// The expansion is read from the executable's own version resource, and a client is only
/// REJECTED on a version we positively read and positively recognise as another expansion.
/// Anything unreadable, stripped, or unrecognised passes. Private-server clients get repacked,
/// recompiled and hex-edited in ways that make version strings unreliable, so this is built to
/// answer "is this definitely something else" — never "is this definitely ours".
/// </summary>
public static class ClientBuild
{
    /// <summary>
    /// Major.minor of the expansions a player might plausibly have sitting on the same disk,
    /// by the name to put in front of them.
    /// </summary>
    private static readonly (int Major, int Minor, string Name)[] Expansions =
    {
        (1, 12, "Vanilla (1.12)"),
        (2, 4, "Burning Crusade (2.4.3)"),
        (4, 3, "Cataclysm (4.3.4)"),
        (5, 4, "Mists of Pandaria (5.4.8)"),
    };

    /// <summary>
    /// The name of the expansion this client belongs to, or null when it is 3.3.5a, or when
    /// the version cannot be read or recognised. Null means "no objection", not "verified".
    /// </summary>
    public static string? Describe(string installPath)
    {
        var exe = ClientExecutable.Find(installPath);
        if (exe is null) return null;

        int major, minor;
        try
        {
            var info = FileVersionInfo.GetVersionInfo(exe);
            major = info.FileMajorPart;
            minor = info.FileMinorPart;
        }
        catch { return null; }

        // A stripped or rewritten header reads as 0.0. Nothing to conclude from that.
        if (major == 0) return null;

        // What we are here for.
        if (major == 3) return null;

        foreach (var (m, n, name) in Expansions)
            if (major == m && minor == n)
                return name;

        // A version we can read but do not have a name for. Retail is far past this, and
        // anything else is a repack doing its own thing — say what it says rather than
        // inventing an expansion name for it.
        return major >= 4 ? $"version {major}.{minor}" : null;
    }
}
