namespace Uncapped.Services;

/// <summary>
/// Gives a freshly installed client a working WTF\Config.wtf, without ever starting the game
/// to get one.
///
/// WHAT THIS USED TO DO, AND WHY IT NO LONGER DOES
///
/// A newly extracted client has no Config.wtf — the client writes it on first start. So this
/// used to launch Wow.exe, poll up to 60 seconds for the file to appear, kill the process
/// tree, wait for it to actually die, and only then edit what it had written. A new player
/// watched the game flash open and shut before they had touched anything, and the install
/// could not proceed until we had won a race against a process we started for no other
/// reason.
///
/// There was never anything in that file we could not write ourselves. The client fills in
/// every other key it wants on its next real run and leaves ours alone, so we write the
/// handful that matter and skip the whole performance.
///
/// THE TERMS SCREENS
///
/// readTOS and readEULA are how 3.3.5a records that the terms were dismissed — taken from a
/// real client that had been through them, not guessed. Pre-setting them means a new player
/// is not made to click through Blizzard's retail terms of service to reach a private server.
///
/// WINDOWED MODE
///
/// Shipped here too, rather than only being forced at PLAY. Fullscreen at whatever resolution
/// the client guesses is how a new player ends up alt-tabbed into a black screen before they
/// have seen the game once.
///
/// Existing settings are never clobbered: ConfigWtf edits line by line, so installing over an
/// old folder keeps the player's resolution, volumes and account name.
/// </summary>
public static class FirstRunConfigurator
{
    public sealed record Result(bool ConfigWritten, string Detail);

    public static Task<Result> ConfigureAsync(
        string installPath,
        IProgress<string> log,
        CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();

        var (width, height) = DesktopResolution();

        var values = new Dictionary<string, string>
        {
            // Terms screens, pre-dismissed.
            ["readTOS"] = "1",
            ["readEULA"] = "1",

            // Windowed, maximised, at the desktop resolution.
            ["gxWindow"] = "1",
            ["gxMaximize"] = "1",
            ["gxResolution"] = $"{width}x{height}",

            // Without this the client re-runs hardware detection on next start and can
            // overwrite the resolution just set.
            ["hwDetect"] = "0",

            ["locale"] = "enUS",
        };

        try
        {
            var written = ConfigWtf.Update(installPath, values, createIfMissing: true);
            var detail = $"windowed at {width}x{height}, terms pre-accepted";
            log.Report($"Game settings written — {detail}.");
            return Task.FromResult(new Result(written, detail));
        }
        catch (Exception ex)
        {
            // Never fatal. Worst case the client writes its own config on first run and the
            // player gets its defaults instead of ours.
            Log.Write($"first-run config: {ex}");
            return Task.FromResult(new Result(false, ex.Message));
        }
    }

    private static (int Width, int Height) DesktopResolution()
    {
        try
        {
            var w = (int)System.Windows.SystemParameters.PrimaryScreenWidth;
            var h = (int)System.Windows.SystemParameters.PrimaryScreenHeight;
            if (w > 0 && h > 0) return (w, h);
        }
        catch { /* fall through to a safe default */ }

        return (1280, 720);
    }
}
