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
    /// Outbound-only torrenting by default: no inbound listener, no DHT. This avoids the
    /// Windows Firewall dialog on first run, at some cost to peer discovery. Flip to true if
    /// swarm connectivity turns out to be poor and the extra prompt is acceptable.
    /// </summary>
    [JsonPropertyName("torrentAllowInbound")] public bool TorrentAllowInbound { get; set; }

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
