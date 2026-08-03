namespace Uncapped.Services;

/// <summary>
/// Raises the client's terrain view distance to the maximum 3.3.5a offers.
///
/// WHY THE REALM CARES
///
/// Flying is enabled in Eastern Kingdoms and Kalimdor here, which the stock client was never
/// tuned for — from the air you are looking across far more ground than a mounted player ever
/// did, and the shipped default cuts the world off well short of that. It also caps the fog
/// work: the client never draws fog further than farclip, so a client left on a low view
/// distance sees its own horizon no matter what the Light DBCs say.
///
/// THE NUMBER IS NOT A GUESS
///
/// Interface\FrameXML\VideoOptionsPanels.lua in this client declares its own slider limits:
///     local OPTIONS_FARCLIP_MIN = 177;
///     local OPTIONS_FARCLIP_MAX = 1277;
/// 1277 is the top of that range. Verified in practice too — a client run with farclip 1277
/// rewrote Config.wtf on exit and left the value intact, so it is honoured rather than clamped.
///
/// ONCE, NOT EVERY LAUNCH
///
/// Unlike windowed mode (which is re-forced every launch because exclusive fullscreen crashes
/// this build), view distance is a genuine performance trade. A player on a weak machine has
/// every right to pull it back down, and fighting them over it on every PLAY would be
/// user-hostile. So this applies one time per install and then leaves the setting alone.
/// </summary>
public static class ViewDistance
{
    /// <summary>The client's own OPTIONS_FARCLIP_MAX.</summary>
    public const int Max = 1277;

    /// <summary>
    /// Raises farclip to <see cref="Max"/> unless it is already at least that. Returns true if
    /// Config.wtf changed.
    /// </summary>
    public static bool RaiseToMax(string installPath)
    {
        // Never lower it. If a player (or a future default) is somehow above the slider max,
        // that is their business and it still renders.
        var current = ConfigWtf.Read(installPath, "farclip");
        if (double.TryParse(current, System.Globalization.NumberStyles.Float,
                            System.Globalization.CultureInfo.InvariantCulture, out var value)
            && value >= Max)
        {
            return false;
        }

        return ConfigWtf.Update(installPath, new Dictionary<string, string>
        {
            ["farclip"] = Max.ToString(System.Globalization.CultureInfo.InvariantCulture),
        });
    }
}
