using System.Diagnostics;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// Rename-then-replace self update.
///
/// Windows will not let you delete or overwrite a running executable, but it will let you
/// *rename* one. So: move ourselves aside to .old, write the new exe under the real name,
/// relaunch it, and exit. The next start deletes the .old. No helper process, no elevation.
/// </summary>
public sealed class SelfUpdater
{
    private readonly HttpClient _http;

    public SelfUpdater(HttpClient http) => _http = http;

    private static string OldPath => AppPaths.ExePath + ".old";

    /// <summary>Called at startup to clear the previous update's leftovers.</summary>
    public static void CleanupPreviousUpdate()
    {
        try { if (File.Exists(OldPath)) File.Delete(OldPath); }
        catch { /* still locked by an exiting process; next launch gets it */ }
    }

    public static bool UpdateAvailable(Manifest manifest)
    {
        if (string.IsNullOrWhiteSpace(manifest.LauncherUrl)) return false;
        if (!Version.TryParse(manifest.LauncherVersion, out var latest)) return false;

        // Compare on 3 components; the build/revision field is noise from the SDK.
        var current = AppPaths.CurrentVersion;
        return new Version(latest.Major, latest.Minor, Math.Max(latest.Build, 0))
             > new Version(current.Major, current.Minor, Math.Max(current.Build, 0));
    }

    /// <summary>
    /// Downloads the replacement, swaps it in, relaunches, and returns true — the caller
    /// should then exit immediately. Returns false if the update could not be applied, in
    /// which case the launcher carries on with the current version.
    /// </summary>
    public async Task<bool> TryApplyAsync(Manifest manifest, IProgress<string> log, CancellationToken ct)
    {
        var staged = Path.Combine(AppPaths.DataDir, "Uncapped.new.exe");

        try
        {
            log.Report($"Downloading launcher {manifest.LauncherVersion}…");

            await using (var source = await _http.GetStreamAsync(manifest.LauncherUrl!, ct))
            await using (var target = new FileStream(staged, FileMode.Create, FileAccess.Write, FileShare.None))
                await source.CopyToAsync(target, ct);

            if (!string.IsNullOrEmpty(manifest.LauncherSha256))
            {
                var actual = await Hashing.Sha256FileAsync(staged, ct);
                if (!Hashing.Matches(actual, manifest.LauncherSha256))
                {
                    log.Report("Launcher update failed its checksum — continuing on the current version.");
                    return false;
                }
            }

            if (File.Exists(OldPath)) File.Delete(OldPath);
            File.Move(AppPaths.ExePath, OldPath);          // allowed even while running
            File.Move(staged, AppPaths.ExePath);

            Process.Start(new ProcessStartInfo
            {
                FileName = AppPaths.ExePath,
                UseShellExecute = true,
                WorkingDirectory = AppPaths.ExeDir,
            });

            return true;
        }
        catch (Exception ex)
        {
            log.Report($"Launcher update failed ({ex.Message}) — continuing on the current version.");

            // Undo a partial swap so we are not left with no executable at all.
            try
            {
                if (!File.Exists(AppPaths.ExePath) && File.Exists(OldPath))
                    File.Move(OldPath, AppPaths.ExePath);
            }
            catch { /* nothing further we can do from in-process */ }

            try { if (File.Exists(staged)) File.Delete(staged); } catch { }
            return false;
        }
    }
}
