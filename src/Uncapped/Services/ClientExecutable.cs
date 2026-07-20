namespace Uncapped.Services;

/// <summary>
/// Where the game executable lives, and under what name.
///
/// The client is renamed to a non-executable-looking file so players cannot start the game
/// by double-clicking it and then report bugs against an unpatched, unsynced install. This
/// is a speed bump, not a lock — anyone who wants to rename it back can — but it removes the
/// accident, which is the actual problem.
///
/// Windows CreateProcess runs any valid PE regardless of extension, so a .dat launches fine
/// as long as UseShellExecute is false. Double-clicking it in Explorer just offers the
/// "how do you want to open this file?" dialog.
/// </summary>
public static class ClientExecutable
{
    /// <summary>
    /// Deliberately not "Uncapped" — that is the launcher's own process name, and sharing it
    /// would make the launcher detect itself as a running game client.
    /// </summary>
    public const string HiddenName = "UncappedClient.dat";

    public const string OriginalName = "Wow.exe";

    /// <summary>
    /// Process names to look for when detecting a running client.
    ///
    /// Careful: Process.ProcessName strips only a ".exe" suffix. A process started from
    /// "UncappedClient.dat" reports its name as "UncappedClient.dat", extension and all, so
    /// GetProcessesByName("UncappedClient") finds nothing. Getting this wrong means the
    /// launcher cannot see a running renamed client and would patch it mid-session.
    ///
    /// Derived from the filenames rather than written out, so renaming the client cannot
    /// leave this list silently stale.
    /// </summary>
    public static readonly string[] ProcessNames =
    {
        HiddenName,                                     // "UncappedClient.dat" - what Windows reports
        Path.GetFileNameWithoutExtension(HiddenName),   // in case a future name ends in .exe
        Path.GetFileNameWithoutExtension(OriginalName), // "Wow"
    };

    /// <summary>
    /// The game executable in this install, whichever name it currently has, or null if the
    /// folder holds neither.
    /// </summary>
    public static string? Find(string installPath)
    {
        var hidden = Path.Combine(installPath, HiddenName);
        if (File.Exists(hidden)) return hidden;

        var original = Path.Combine(installPath, OriginalName);
        return File.Exists(original) ? original : null;
    }

    public static bool Exists(string installPath) => Find(installPath) is not null;
}
