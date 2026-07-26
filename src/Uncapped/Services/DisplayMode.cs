namespace Uncapped.Services;

/// <summary>
/// Forces the client into windowed mode.
///
/// Exclusive fullscreen on this 3.3.5a build crashes on a wide range of machines, so windowed
/// is not a preference here — it is the only mode we support. It has to be re-applied on every
/// launch rather than set once: the client rewrites Config.wtf when it exits, so a player who
/// flips to fullscreen in-game (or with Alt+Enter) would otherwise stay there and crash on
/// their next start, with no obvious way back.
/// </summary>
public static class DisplayMode
{
    /// <summary>Applies windowed mode. Returns true if Config.wtf actually changed.</summary>
    public static bool ForceWindowed(string installPath) =>
        ConfigWtf.Update(installPath, new Dictionary<string, string>
        {
            // Windowed rather than exclusive fullscreen.
            ["gxWindow"] = "1",
            // Deliberately do NOT touch gxMaximize — whether the window is maximized/borderless
            // or a plain window is the player's choice; we only force it out of exclusive
            // fullscreen (which crashes). Leave their maximize setting exactly as-is.
            // Stop the client re-running hardware detection and undoing the above.
            ["hwDetect"] = "0",
        },
        // A client that has never been started has no Config.wtf; a minimal one that says
        // "windowed" beats letting it boot into a fullscreen default and crash.
        createIfMissing: true);
}
