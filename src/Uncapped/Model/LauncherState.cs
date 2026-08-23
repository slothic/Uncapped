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

    /// <summary>
    /// Archive name -> the sha256 of the zip last unpacked for it. Lets the launcher skip
    /// re-extracting an archive that has not changed, which is the whole point of pinning the
    /// hash: without this, every launch would re-download and re-expand ArkInventory.
    /// </summary>
    [JsonPropertyName("installedArchives")]
    public Dictionary<string, string> InstalledArchives { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    [JsonPropertyName("lastSyncedManifestVersion")] public string? LastSyncedManifestVersion { get; set; }

    /// <summary>
    /// Hash of the manifest bytes we last synced against. Pressing PLAY re-fetches the
    /// manifest and compares this: identical means nothing upstream moved, so the sync can be
    /// skipped entirely and the game starts immediately.
    /// </summary>
    [JsonPropertyName("lastManifestHash")] public string? LastManifestHash { get; set; }

    /// <summary>
    /// Crash dump filenames already uploaded, so the same crash is not re-sent on every
    /// launch. Trimmed periodically.
    /// </summary>
    [JsonPropertyName("reportedCrashes")] public List<string> ReportedCrashes { get; set; } = new();

    /// <summary>
    /// ★ TEMPORARY (FPS investigation). An anonymous handle for this install, so frame logs
    /// arriving in the channel can be told apart and one install followed across sessions.
    ///
    /// 8 bytes from the OS cryptographic RNG, rendered as hex, generated once and then only
    /// read. It is DERIVED FROM NOTHING — not the account name, not a character name, not the
    /// machine name, not the hardware. It means nothing outside our own channel, and it is
    /// gone the moment this file is deleted. See <see cref="Services.FpsReporter"/>.
    /// </summary>
    [JsonPropertyName("installToken")] public string? InstallTokenValue { get; set; }

    /// <summary>How many frame logs this install has uploaded. Bookkeeping only.</summary>
    [JsonPropertyName("fpsReportsSent")] public int FpsReportsSent { get; set; }

    /// <summary>
    /// The token, minted on first use. Saving is the caller's job — the one place that reads
    /// this already saves the state straight afterwards.
    /// </summary>
    [JsonIgnore]
    public string InstallToken
    {
        get
        {
            if (string.IsNullOrWhiteSpace(InstallTokenValue))
                InstallTokenValue = Convert.ToHexString(
                    System.Security.Cryptography.RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
            return InstallTokenValue!;
        }
    }

    /// <summary>
    /// Whether the one-time view-distance bump has been applied to this install. Existing
    /// players installed before farclip became a first-run default, so it is raised once at
    /// PLAY — and only once, because view distance is a real performance trade the player is
    /// entitled to pull back down. See <see cref="Services.ViewDistance"/>.
    /// </summary>
    [JsonPropertyName("viewDistanceRaised")] public bool ViewDistanceRaised { get; set; }

    /// <summary>
    /// Hashes already computed for this install, keyed by install-root-relative path.
    ///
    /// This is what makes verifying 16 GB on every launch affordable. SHA-256 over the whole
    /// client costs about a minute on an NVMe drive and several on a spinning disk, which is
    /// not something to spend on every PLAY. A cached entry is trusted only while the file's
    /// size AND last-write time are both unchanged, so any rewrite — corruption, a patcher, a
    /// hand-edit — invalidates it and the file is re-hashed.
    ///
    /// Worst case if a file were somehow modified with its size and timestamp preserved: the
    /// launcher trusts a stale hash. That is a deliberate trade for a launcher that starts in
    /// seconds, and the server-side version gate is still behind it.
    /// </summary>
    [JsonPropertyName("verifiedFiles")]
    public Dictionary<string, VerifiedFile> VerifiedFiles { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static LauncherState Load()
    {
        try
        {
            var path = AppPaths.StateFile;
            if (!File.Exists(path)) return new LauncherState();

            var state = JsonSerializer.Deserialize<LauncherState>(File.ReadAllText(path)) ?? new LauncherState();

            // Deserialisation hands back a plain Dictionary, discarding the case-insensitive
            // comparer the property was initialised with. Rebuild it, or an archive recorded as
            // "ArkInventory" would not be found when looked up as "arkinventory" and would be
            // re-downloaded and re-extracted on every single launch.
            state.InstalledArchives = new Dictionary<string, string>(
                state.InstalledArchives, StringComparer.OrdinalIgnoreCase);

            // Same trap as above: the hash cache is keyed by path and would miss on a casing
            // difference, re-hashing 16 GB on every launch while looking like it worked.
            state.VerifiedFiles = new Dictionary<string, VerifiedFile>(
                state.VerifiedFiles, StringComparer.OrdinalIgnoreCase);

            return state;
        }
        catch
        {
            // A corrupt state file must not brick the launcher; re-deriving it costs one
            // folder pick and one hash pass.
            return new LauncherState();
        }
    }

    /// <summary>
    /// ⚠ Atomic, not File.WriteAllText. Load() treats a parse failure as "no state" and returns
    /// a fresh object, so a truncated write costs the player their remembered install path AND
    /// the whole VerifiedFiles cache — a silent 16 GB re-hash on the next launch. See
    /// <see cref="AtomicFile"/>.
    /// </summary>
    public void Save()
    {
        Directory.CreateDirectory(AppPaths.DataDir);
        AtomicFile.WriteAllText(AppPaths.StateFile, JsonSerializer.Serialize(this, Options));
    }
}

/// <summary>
/// One remembered hash, valid only while the file it describes is untouched.
///
/// Both size and write time are recorded because either alone is too weak: a corrupted MPQ can
/// keep its length, and a file copied back from a backup can keep its timestamp.
/// </summary>
public sealed class VerifiedFile
{
    [JsonPropertyName("size")] public long Size { get; set; }

    /// <summary>UTC ticks, so a state file does not change meaning across a DST boundary.</summary>
    [JsonPropertyName("writtenTicks")] public long WrittenTicks { get; set; }

    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
}
