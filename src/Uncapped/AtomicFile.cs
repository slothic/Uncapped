namespace Uncapped;

/// <summary>
/// Writing a small settings file without a window in which it is neither the old contents nor
/// the new ones.
///
/// ★★ WHY THIS IS NOT File.WriteAllText.
///
/// WriteAllText truncates the target and then writes into it. A launcher killed mid-write, a
/// full disk, or a machine losing power leaves a truncated or empty file — and both callers
/// catch a parse failure on load and quietly return a fresh object, which is the right
/// behaviour for a corrupt file and a terrible outcome for the player:
///
///   * state.json holds InstallPath, so they are asked to find their game folder again; and
///   * it holds the VerifiedFiles hash cache, so the next launch re-hashes the whole 16 GB
///     install with nothing on screen explaining why it suddenly takes ten minutes.
///
/// Writing to a sibling temp and moving it over the target closes that window: the move is
/// atomic on NTFS, so a reader sees either the whole previous file or the whole new one, and a
/// crash at any point leaves the previous one intact.
///
/// ⚠ The temp is a SIBLING, deliberately. File.Move across volumes is a copy-then-delete and
/// loses the atomicity this exists for; %TEMP% is regularly on another drive.
/// </summary>
public static class AtomicFile
{
    public static void WriteAllText(string path, string contents)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

        var temp = path + ".tmp";

        try
        {
            File.WriteAllText(temp, contents);
            File.Move(temp, path, overwrite: true);
        }
        catch
        {
            // Best effort: never leave our own debris behind for a write that failed anyway.
            try { if (File.Exists(temp)) File.Delete(temp); } catch { /* nothing sensible to do */ }
            throw;
        }
    }
}
