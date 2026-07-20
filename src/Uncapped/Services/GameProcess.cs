using System.Diagnostics;

namespace Uncapped.Services;

public static class GameProcess
{
    /// <summary>
    /// True if a Wow.exe is running from this install. Patching a live client corrupts the
    /// session and produces bug reports that look like server faults, so the sync refuses
    /// while one is up.
    /// </summary>
    public static bool IsRunning(string installPath)
    {
        var target = Path.GetFullPath(Path.Combine(installPath, "Wow.exe"));

        foreach (var p in Process.GetProcessesByName("Wow"))
        {
            try
            {
                var main = p.MainModule?.FileName;
                if (main is not null &&
                    string.Equals(Path.GetFullPath(main), target, StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            catch
            {
                // Access denied reading another process's modules (different elevation, or a
                // 32-bit target). Can't confirm the path, so assume it is ours — refusing a
                // sync is far cheaper than corrupting a running client.
                return true;
            }
            finally { p.Dispose(); }
        }
        return false;
    }

    public static void Launch(string installPath)
    {
        var exe = Path.Combine(installPath, "Wow.exe");
        if (!File.Exists(exe)) throw new FileNotFoundException("Wow.exe not found.", exe);

        Process.Start(new ProcessStartInfo
        {
            FileName = exe,
            WorkingDirectory = installPath, // WoW resolves Data\ relative to CWD
            UseShellExecute = true,
        });
    }
}
