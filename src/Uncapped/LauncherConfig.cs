using System.Text.Json;
using System.Text.Json.Serialization;

namespace Uncapped;

/// <summary>
/// Deployment settings that sit beside the exe rather than inside it, so the manifest can be
/// repointed without a rebuild.
/// </summary>
public sealed class LauncherConfig
{
    [JsonPropertyName("manifestUrl")] public string ManifestUrl { get; set; } =
        "https://raw.githubusercontent.com/slothic/Uncapped/main/manifest.json";

    /// <summary>
    /// Inbound listener + DHT, ON by default.
    /// 
    /// This was off to avoid the Windows Firewall dialog on first run, with the trackers
    /// expected to carry peer discovery on their own. That is not enough for a MAGNET link:
    /// with DhtEndPoint null there is no DHT at all, so the torrent's metadata can only come
    /// from the four trackers in the magnet -- and three of those are udp://. A player whose
    /// network drops outbound UDP has nothing left to resolve the magnet from, and the
    /// launcher sits on "Fetching torrent details..." forever rather than failing.
    /// 
    /// That happened to a real new install (2026-08-02) while the swarm itself was healthy --
    /// 625 seeders on scrape at the time. A firewall prompt is a far smaller cost than an
    /// install that cannot start, so the default is flipped. Set it back to false to opt out.
    /// </summary>
    [JsonPropertyName("torrentAllowInbound")] public bool TorrentAllowInbound { get; set; } = true;

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static LauncherConfig Load()
    {
        try
        {
            if (File.Exists(AppPaths.ConfigFile))
                return JsonSerializer.Deserialize<LauncherConfig>(File.ReadAllText(AppPaths.ConfigFile))
                       ?? new LauncherConfig();
        }
        catch { /* fall through to defaults + rewrite */ }

        var fresh = new LauncherConfig();
        try { File.WriteAllText(AppPaths.ConfigFile, JsonSerializer.Serialize(fresh, Options)); }
        catch { /* read-only install dir is survivable; defaults still apply */ }
        return fresh;
    }
}
