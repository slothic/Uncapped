namespace Uncapped.Services;

/// <summary>
/// Makes the install awkward to start without the launcher.
///
/// The motivation is support load rather than security: a player who double-clicks the game
/// directly gets an unsynced, unpatched client, then reports crashes that look like server
/// bugs. Renaming the executable removes the accidental path.
/// </summary>
public static class ClientHardening
{
    public sealed record Result(bool Renamed, bool RepairRemoved, List<string> Notes);

    /// <summary>
    /// Files worth deleting outright. Repair.exe re-downloads and overwrites client data
    /// from Blizzard's CDN, which would undo our patches.
    ///
    /// WowError.exe is deliberately NOT here: it is what writes the Crash.dmp files the
    /// launcher uploads. Removing it would silently disable crash reporting.
    /// </summary>
    private static readonly string[] RemovableTools = { "Repair.exe" };

    public static Result Apply(string installPath)
    {
        var notes = new List<string>();
        var renamed = false;
        var repairRemoved = false;

        var original = Path.Combine(installPath, ClientExecutable.OriginalName);
        var hidden = Path.Combine(installPath, ClientExecutable.HiddenName);

        try
        {
            if (File.Exists(original))
            {
                if (File.Exists(hidden))
                {
                    // Both present: a reinstall or a manual restore put Wow.exe back. The
                    // hidden copy is the one we launch, so drop the duplicate rather than
                    // leave a runnable Wow.exe sitting there.
                    File.Delete(original);
                    notes.Add("Removed a restored Wow.exe; the renamed client was already in place.");
                    renamed = true;
                }
                else
                {
                    File.Move(original, hidden);
                    renamed = true;
                }
            }
        }
        catch (Exception ex)
        {
            // Not fatal. The launcher runs whichever name it finds, so a failure here just
            // means the client stays double-clickable.
            notes.Add($"Could not rename the game executable: {ex.Message}");
        }

        foreach (var tool in RemovableTools)
        {
            var path = Path.Combine(installPath, tool);
            if (!File.Exists(path)) continue;

            try
            {
                File.Delete(path);
                repairRemoved = true;
            }
            catch (Exception ex) { notes.Add($"Could not remove {tool}: {ex.Message}"); }
        }

        return new Result(renamed, repairRemoved, notes);
    }
}
