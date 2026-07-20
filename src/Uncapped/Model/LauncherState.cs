using System.Text.Json;
using System.Text.Json.Serialization;

namespace Uncapped.Model;

/// <summary>
/// Everything the launcher remembers between runs. Lives in %LOCALAPPDATA%\Uncapped so it
/// survives a self-update that replaces the exe.
/// </summary>
public sealed class LauncherState
{
    [JsonPropertyName("installPath")] public string? InstallPath { get; set; }

    /// <summary>
    /// Install-root-relative paths this launcher has placed. Used to prune files that drop
    /// out of the manifest — but only those under Manifest.OwnedPaths.
    /// </summary>
    [JsonPropertyName("installedFiles")] public List<string> InstalledFiles { get; set; } = new();

    [JsonPropertyName("lastSyncedManifestVersion")] public string? LastSyncedManifestVersion { get; set; }

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static LauncherState Load()
    {
        try
        {
            var path = AppPaths.StateFile;
            if (!File.Exists(path)) return new LauncherState();
            return JsonSerializer.Deserialize<LauncherState>(File.ReadAllText(path)) ?? new LauncherState();
        }
        catch
        {
            // A corrupt state file must not brick the launcher; re-deriving it costs one
            // folder pick and one hash pass.
            return new LauncherState();
        }
    }

    public void Save()
    {
        Directory.CreateDirectory(AppPaths.DataDir);
        File.WriteAllText(AppPaths.StateFile, JsonSerializer.Serialize(this, Options));
    }
}
