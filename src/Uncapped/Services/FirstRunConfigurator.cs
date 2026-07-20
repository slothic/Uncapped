using System.Diagnostics;

namespace Uncapped.Services;

/// <summary>
/// Gives a freshly downloaded client sane display settings: windowed, at the desktop
/// resolution.
///
/// A newly extracted client has no WTF\Config.wtf at all — the client writes it itself on
/// first start. So to have a file to edit, we start Wow.exe, wait for Config.wtf to appear,
/// kill it, and then apply our settings to what it wrote. The player sees the game window
/// flash open and close once, on first install only.
///
/// If Wow.exe never produces a Config.wtf (it failed to start, or this build writes the file
/// only on a clean exit), we write a minimal one ourselves rather than give up — the client
/// fills in everything else on its next real run.
/// </summary>
public static class FirstRunConfigurator
{
    private static readonly TimeSpan ConfigWaitTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);

    /// <summary>Settle time after the file appears, so we do not read a half-written file.</summary>
    private static readonly TimeSpan SettleDelay = TimeSpan.FromSeconds(2);

    public sealed record Result(bool ConfigGenerated, bool SettingsApplied, string Detail);

    public static async Task<Result> ConfigureAsync(
        string installPath,
        IProgress<string> log,
        CancellationToken ct)
    {
        var generated = false;

        if (!ConfigWtf.Exists(installPath))
        {
            log.Report("Starting the game once to create its settings file…");
            generated = await GenerateConfigAsync(installPath, log, ct);
        }

        var (width, height) = DesktopResolution();

        var values = new Dictionary<string, string>
        {
            ["gxWindow"] = "1",                    // windowed rather than fullscreen
            ["gxResolution"] = $"{width}x{height}",
            // Without this the client re-runs hardware detection on next start and can
            // overwrite the resolution we just set.
            ["hwDetect"] = "0",
        };

        try
        {
            // createIfMissing: if the client never wrote a config, a minimal one beats none.
            var applied = ConfigWtf.Update(installPath, values, createIfMissing: true);
            var detail = $"windowed at {width}x{height}";
            log.Report($"Display set to {detail}.");
            return new Result(generated, applied, detail);
        }
        catch (Exception ex)
        {
            return new Result(generated, false, $"could not write display settings: {ex.Message}");
        }
    }

    private static async Task<bool> GenerateConfigAsync(
        string installPath, IProgress<string> log, CancellationToken ct)
    {
        var exe = ClientExecutable.Find(installPath);
        if (exe is null) return false;

        Process? process = null;
        try
        {
            process = Process.Start(new ProcessStartInfo
            {
                FileName = exe,
                WorkingDirectory = installPath,
                // False so this works whether or not the client has been renamed yet.
                UseShellExecute = false,
            });

            if (process is null) return false;

            var deadline = DateTime.UtcNow + ConfigWaitTimeout;
            while (DateTime.UtcNow < deadline)
            {
                ct.ThrowIfCancellationRequested();

                if (ConfigWtf.Exists(installPath))
                {
                    await Task.Delay(SettleDelay, ct);
                    return true;
                }

                // If it exited on its own, there is nothing left to wait for.
                if (process.HasExited) return ConfigWtf.Exists(installPath);

                await Task.Delay(PollInterval, ct);
            }

            log.Report("The game did not write its settings file in time; using defaults.");
            return false;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            log.Report($"Could not start the game to generate settings ({ex.Message}).");
            return false;
        }
        finally
        {
            // Kill whatever we started, including any child it spawned. The player never
            // asked for this window and we must not leave it holding the install open —
            // the sync refuses to run while Wow.exe is alive.
            try
            {
                if (process is not null && !process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(10_000);
                }
            }
            catch { /* already gone, or not ours to kill */ }
            finally { process?.Dispose(); }

            // Belt and braces: Wow.exe can relaunch itself, so make sure nothing from this
            // install survives before the caller moves on to patching it.
            await WaitForGameToCloseAsync(installPath);
        }
    }

    private static async Task WaitForGameToCloseAsync(string installPath)
    {
        for (var i = 0; i < 20 && GameProcess.IsRunning(installPath); i++)
        {
            GameProcess.KillAll(installPath);
            await Task.Delay(500);
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    private const int SM_CXSCREEN = 0;
    private const int SM_CYSCREEN = 1;

    /// <summary>
    /// Primary monitor size in physical pixels.
    ///
    /// Deliberately Win32 rather than WPF's SystemParameters, which reports device-independent
    /// units — on a scaled display those are smaller than the real resolution and would set
    /// gxResolution wrong. With the manifest declaring per-monitor DPI awareness these are
    /// true pixels.
    /// </summary>
    private static (int Width, int Height) DesktopResolution()
    {
        var w = GetSystemMetrics(SM_CXSCREEN);
        var h = GetSystemMetrics(SM_CYSCREEN);
        return w > 0 && h > 0 ? (w, h) : (1280, 720);
    }
}
