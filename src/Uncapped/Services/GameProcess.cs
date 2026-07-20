using System.Diagnostics;

namespace Uncapped.Services;

public static class GameProcess
{
    /// <summary>
    /// True if the game is running from this install. Patching a live client corrupts the
    /// session and produces bug reports that look like server faults, so the sync refuses
    /// while one is up.
    ///
    /// Checks both the renamed executable and the original Wow.exe, since an install may not
    /// have been hardened yet.
    /// </summary>
    public static bool IsRunning(string installPath)
    {
        var target = ClientExecutable.Find(installPath);
        if (target is null) return false;
        target = Path.GetFullPath(target);

        foreach (var name in ClientExecutable.ProcessNames)
        {
            foreach (var p in Process.GetProcessesByName(name))
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
                    // Access denied reading another process's modules (different elevation, or
                    // a 32-bit target). Can't confirm the path, so assume it is ours —
                    // refusing a sync is far cheaper than corrupting a running client.
                    return true;
                }
                finally { p.Dispose(); }
            }
        }
        return false;
    }

    public static void Launch(string installPath)
    {
        var exe = ClientExecutable.Find(installPath)
            ?? throw new FileNotFoundException(
                $"No game executable found in {installPath} " +
                $"(looked for {ClientExecutable.HiddenName} and {ClientExecutable.OriginalName}).");

        Process.Start(new ProcessStartInfo
        {
            FileName = exe,
            WorkingDirectory = installPath, // the client resolves Data\ relative to CWD
            // Must be false: the renamed client has no shell association, so ShellExecute
            // would pop the "how do you want to open this file?" dialog instead of running it.
            UseShellExecute = false,
        });
    }

    /// <summary>Kills any client running from this install. Used after the first-run probe.</summary>
    public static void KillAll(string installPath)
    {
        var target = ClientExecutable.Find(installPath);
        var full = target is null ? null : Path.GetFullPath(target);

        foreach (var name in ClientExecutable.ProcessNames)
        {
            foreach (var p in Process.GetProcessesByName(name))
            {
                try
                {
                    string? main = null;
                    try { main = p.MainModule?.FileName; } catch { /* unreadable; kill anyway */ }

                    if (full is null || main is null ||
                        string.Equals(Path.GetFullPath(main), full, StringComparison.OrdinalIgnoreCase))
                        p.Kill();
                }
                catch { /* already gone, or not ours to kill */ }
                finally { p.Dispose(); }
            }
        }
    }
}
