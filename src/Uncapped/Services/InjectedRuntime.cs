using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// The native runtime DLL the patched client loads at startup.
///
/// WHY THIS NEEDS A PRE-FLIGHT CHECK OF ITS OWN
///
/// The client is patched by import-table injection, which makes the DLL a HARD dependency:
/// the Windows loader resolves it before a single instruction of the game runs. If the file
/// is missing, the process does not start at all, and the player gets
///
///     "The code execution cannot proceed because UncappedCT.dll was not found."
///
/// or a bare 0xc0000135 — neither of which tells them anything useful, and both of which
/// look exactly like a broken install.
///
/// The overwhelmingly likely cause is antivirus. An unsigned DLL that is injected into
/// another process is close to the textbook description of malware behaviour, so real-time
/// scanners quarantine it, and they do so AFTER the launcher has downloaded and verified it.
/// From the launcher's point of view the sync succeeded; the file simply is not there any
/// more. That is why this is checked at launch rather than trusted from the sync result.
///
/// The check is deliberately conditional on the manifest actually listing the DLL. A client
/// on an older manifest that never shipped one is not broken, and must not be told it is.
/// </summary>
public static class InjectedRuntime
{
    public const string DllName = "UncappedCT.dll";

    /// <summary>True if this manifest expects the injected runtime to be installed.</summary>
    public static bool IsExpected(Manifest manifest) =>
        manifest.Files.Any(f =>
            !string.IsNullOrEmpty(f.Path) &&
            Path.GetFileName(f.Path).Equals(DllName, StringComparison.OrdinalIgnoreCase));

    public static bool IsPresent(string installPath) =>
        File.Exists(Path.Combine(installPath, DllName));

    /// <summary>
    /// Null when everything is fine. Otherwise the message to put in front of the player,
    /// written to be actionable rather than merely accurate — "add an exclusion" is
    /// something they can do; "the DLL is missing" is not.
    /// </summary>
    public static string? DescribeProblem(Manifest manifest, string installPath)
    {
        if (!IsExpected(manifest) || IsPresent(installPath)) return null;

        return
            $"{DllName} is missing from your game folder.\n\n" +
            "The launcher downloaded it, so the usual cause is antivirus software removing " +
            "it afterwards. It is a false positive: the file is part of the client and is " +
            "what makes damage numbers above two billion display correctly.\n\n" +
            "To fix it, add this folder as an exclusion in your antivirus, then press PLAY " +
            "again to re-download it:\n\n" +
            $"{installPath}\n\n" +
            "The game cannot start without this file, so it has not been launched.";
    }
}
