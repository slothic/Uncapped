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

    /// <summary>
    /// The pristine client <see cref="ClientPatcher"/> derives <see cref="HiddenName"/> from.
    ///
    /// Hardcoded here for the same reason the two names above are, and kept in step with the
    /// manifest's clientPatch.basePath by hand. It is used ONLY as evidence that a folder
    /// holds our client — never as something to run, which is why <see cref="Find"/> does not
    /// know about it.
    /// </summary>
    public const string BaseName = "UncappedBase.dat";

    /// <summary>
    /// Whether this folder holds a game client, INCLUDING one that has been acquired but not
    /// yet built.
    ///
    /// The distinction matters exactly once, and getting it wrong breaks first installs: a
    /// fresh acquisition lands the base file, and <see cref="InstallLocator.Validate"/> runs
    /// the moment acquisition returns — before the client has been derived. Judging that
    /// folder by <see cref="Find"/> alone would reject a perfectly good download with "There
    /// is no game executable in that folder."
    /// </summary>
    public static bool Exists(string installPath) =>
        Find(installPath) is not null || File.Exists(Path.Combine(installPath, BaseName));
}
