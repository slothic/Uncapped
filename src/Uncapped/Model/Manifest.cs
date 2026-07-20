using System.Text.Json.Serialization;

namespace Uncapped.Model;

/// <summary>
/// The manifest is the launcher's only source of truth for what to install and where the
/// realm lives. Everything that might plausibly change without a code change lives here —
/// notably the torrent magnet, which the handoff explicitly required to be replaceable
/// config rather than a hardcoded constant.
/// </summary>
public sealed class Manifest
{
    [JsonPropertyName("manifestVersion")] public int ManifestVersion { get; set; } = 1;

    /// <summary>Version of the launcher this manifest expects. Drives self-update.</summary>
    [JsonPropertyName("launcherVersion")] public string LauncherVersion { get; set; } = "0.0.0";

    [JsonPropertyName("launcherUrl")] public string? LauncherUrl { get; set; }
    [JsonPropertyName("launcherSha256")] public string? LauncherSha256 { get; set; }

    [JsonPropertyName("realm")] public RealmInfo Realm { get; set; } = new();
    [JsonPropertyName("client")] public ClientSource Client { get; set; } = new();

    /// <summary>
    /// Discord webhook that client crash dumps are posted to. Lives here rather than in the
    /// binary so it can be rotated without a release — which matters, because a webhook
    /// shipped in a public client can be extracted by anyone who looks.
    /// Leave null to disable crash reporting entirely.
    /// </summary>
    [JsonPropertyName("crashReportWebhook")] public string? CrashReportWebhook { get; set; }

    /// <summary>
    /// Rename the client executable and remove Repair.exe, so players cannot start an
    /// unsynced client by double-clicking it.
    /// </summary>
    [JsonPropertyName("hardenClient")] public bool HardenClient { get; set; }

    [JsonPropertyName("news")] public List<NewsItem> News { get; set; } = new();
    [JsonPropertyName("files")] public List<ManifestFile> Files { get; set; } = new();

    /// <summary>
    /// Addon folder names the launcher force-enables in AddOns.txt on every launch.
    /// 3.3.5a has no .toc flag that makes an addon undisableable, so re-ticking the box
    /// each launch is the closest available equivalent.
    /// </summary>
    [JsonPropertyName("forceEnableAddOns")] public List<string> ForceEnableAddOns { get; set; } = new();

    /// <summary>
    /// Path prefixes (install-root-relative) the launcher owns outright. Only files under
    /// these prefixes are pruned when they drop out of the manifest. Anything else we
    /// install — the third-party addons — is install-only and never deleted, per the
    /// standing rule: never delete an addon we did not write ourselves.
    /// </summary>
    [JsonPropertyName("ownedPaths")] public List<string> OwnedPaths { get; set; } = new();
}

public sealed class RealmInfo
{
    [JsonPropertyName("name")] public string Name { get; set; } = "Uncapped";
    [JsonPropertyName("address")] public string Address { get; set; } = "";
    [JsonPropertyName("authPort")] public int AuthPort { get; set; } = 3724;
    [JsonPropertyName("registerUrl")] public string? RegisterUrl { get; set; }
}

public sealed class ClientSource
{
    [JsonPropertyName("magnet")] public string? Magnet { get; set; }

    /// <summary>HTTP fallback for players whose network blocks BitTorrent entirely.</summary>
    [JsonPropertyName("directDownloadUrl")] public string? DirectDownloadUrl { get; set; }

    [JsonPropertyName("archiveName")] public string ArchiveName { get; set; } = "client.zip";

    /// <summary>
    /// Size of the downloaded .zip. Needed on the drive holding %LOCALAPPDATA%, which is not
    /// necessarily the drive the game is installed to.
    /// </summary>
    [JsonPropertyName("archiveBytes")] public long ArchiveBytes { get; set; }

    /// <summary>Size of the client once extracted. Needed on the install drive.</summary>
    [JsonPropertyName("installedBytes")] public long InstalledBytes { get; set; }
}

public sealed class NewsItem
{
    [JsonPropertyName("date")] public string Date { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("body")] public string? Body { get; set; }
}

public sealed class ManifestFile
{
    /// <summary>Install-root-relative destination, forward slashes.</summary>
    [JsonPropertyName("path")] public string Path { get; set; } = "";

    [JsonPropertyName("url")] public string Url { get; set; } = "";
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
    [JsonPropertyName("size")] public long Size { get; set; }
}
