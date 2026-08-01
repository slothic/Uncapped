namespace Uncapped.Services;

/// <summary>
/// Creates a desktop shortcut to the LAUNCHER.
///
/// Deliberately not to Wow.exe. Starting the game directly skips the update check, the
/// windowed-mode enforcement and the version gate, so a player who did that would be refused
/// at login the first time the client version moved — with no clue why, because the thing
/// that would have told them is the thing they bypassed. A shortcut is a convenience; it must
/// not become a way to break your own install.
///
/// Built through WScript.Shell over COM rather than by hand: the .lnk format is a documented
/// but fiddly binary structure, and every Windows that can run this launcher already has the
/// scripting host. Failure is never fatal — a missing shortcut is a papercut, not a reason to
/// stop an install.
/// </summary>
public static class DesktopShortcut
{
    public const string ShortcutName = "Uncapped";

    public static string Path =>
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            ShortcutName + ".lnk");

    public static bool Exists() => File.Exists(Path);

    /// <summary>Creates (or replaces) the shortcut. Returns true on success.</summary>
    public static bool Create()
    {
        try
        {
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType is null)
            {
                Log.Write("desktop shortcut: WScript.Shell is not registered");
                return false;
            }

            dynamic? shell = Activator.CreateInstance(shellType);
            if (shell is null) return false;

            try
            {
                dynamic link = shell.CreateShortcut(Path);
                link.TargetPath = AppPaths.ExePath;
                link.WorkingDirectory = AppPaths.ExeDir;
                link.Description = "Uncapped — WotLK";
                // The exe carries its own icon; pointing at it keeps the shortcut correct
                // through self-updates, which replace the binary in place.
                link.IconLocation = AppPaths.ExePath + ",0";
                link.Save();
            }
            finally
            {
                // Release the COM object rather than waiting for the finalizer, so the
                // scripting host does not linger behind the launcher.
                try { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell); }
                catch { /* not a COM object, or already released */ }
            }

            Log.Write($"desktop shortcut created at {Path}");
            return true;
        }
        catch (Exception ex)
        {
            Log.Write($"desktop shortcut: {ex.Message}");
            return false;
        }
    }
}
