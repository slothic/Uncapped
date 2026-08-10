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

    /// <summary>
    /// Set IMAGE_FILE_LARGE_ADDRESS_AWARE on the client, lifting its address space from 2 GB
    /// to 4 GB on 64-bit Windows. Two bytes of the PE header; no code is modified.
    /// </summary>
    [JsonPropertyName("largeAddressAware")] public bool LargeAddressAware { get; set; }

    /// <summary>
    /// Optional URL for a standalone news file. When set it takes precedence over
    /// <see cref="News"/>, letting news be updated by editing one file on the realm box
    /// rather than pushing a manifest. Falls back to <see cref="News"/> if unreachable.
    /// </summary>
    [JsonPropertyName("newsUrl")] public string? NewsUrl { get; set; }

    /// <summary>
    /// Where the launcher's support button points. Null or empty hides the button entirely,
    /// so a manifest that does not carry one simply has no donate UI.
    ///
    /// Here rather than in the binary for the usual reason: it has already moved once
    /// (PayPal to Ko-fi), and a URL compiled into the exe would have made that a release.
    /// </summary>
    [JsonPropertyName("donateUrl")] public string? DonateUrl { get; set; }

    /// <summary>
    /// Where <see cref="Baseline"/> is published — the hashes of the stock client underneath
    /// our payload, which is what lets the launcher tell a legitimate install from one carrying
    /// files from somewhere else.
    ///
    /// Null disables integrity verification entirely and falls back to checking only the files
    /// listed here. That is the pre-1.10 behaviour, and it is the off switch if the baseline
    /// ever turns out to be flagging something legitimate.
    /// </summary>
    [JsonPropertyName("baselineUrl")] public string? BaselineUrl { get; set; }

    /// <summary>Fallback news, used when no newsUrl is set or the fetch fails.</summary>
    [JsonPropertyName("news")] public List<NewsItem> News { get; set; } = new();
    [JsonPropertyName("files")] public List<ManifestFile> Files { get; set; } = new();

    /// <summary>
    /// Zip archives fetched from someone else's distribution point and unpacked into the
    /// install, rather than copied into our payload and served file-by-file.
    ///
    /// This exists for addons we are not entitled to redistribute. ArkInventory reserves all
    /// rights in its own source (see ADDON-LICENCES.md), so we do not host its bytes — the
    /// launcher downloads the author's own CurseForge upload on the player's behalf. Same
    /// principle as the externally hosted WDM patches in <see cref="Files"/>, but a zip that
    /// has to be expanded rather than a single file that lands as-is.
    /// </summary>
    [JsonPropertyName("archives")] public List<ManifestArchive> Archives { get; set; } = new();

    /// <summary>
    /// Addon folder names the launcher force-enables in AddOns.txt on every launch.
    /// 3.3.5a has no .toc flag that makes an addon undisableable, so re-ticking the box
    /// each launch is the closest available equivalent.
    /// </summary>
    [JsonPropertyName("forceEnableAddOns")] public List<string> ForceEnableAddOns { get; set; } = new();

    /// <summary>
    /// Addons switched off in AddOns.txt on every launch — for ones we have shipped in the
    /// past that turned out to be broken.
    ///
    /// Needed because dropping an addon from the manifest does not uninstall it: the launcher
    /// never deletes third-party addons, so a broken one would keep loading. This turns it off
    /// without touching anyone's files, and is reversible by removing the entry.
    /// </summary>
    [JsonPropertyName("forceDisableAddOns")] public List<string> ForceDisableAddOns { get; set; } = new();

    /// <summary>
    /// Path prefixes (install-root-relative) the launcher owns outright. Only files under
    /// these prefixes are pruned when they drop out of the manifest. Anything else we
    /// install — the third-party addons — is install-only and never deleted, per the
    /// standing rule: never delete an addon we did not write ourselves.
    /// </summary>
    [JsonPropertyName("ownedPaths")] public List<string> OwnedPaths { get; set; } = new();

    /// <summary>
    /// The server-generated <c>itemcache.wdb</c> to drop into Cache\WDB, and the epoch token
    /// that decides when to drop it. See <see cref="Services.WdbCache"/> for the mechanism.
    ///
    /// Deliberately NOT a <see cref="ManifestFile"/>. Entries in <see cref="Files"/> are
    /// change-detected by hash and are required by the integrity check, and this file is
    /// neither: the client rewrites it during play, so its hash stops matching within seconds
    /// of logging in and never matches again. As a manifest file it would re-download ~1.7 MB
    /// on every launch forever AND report itself corrupt, which blocks PLAY.
    ///
    /// Null is the off switch, and the whole feature's rollback: no block means the launcher
    /// wipes Cache\WDB and installs nothing, which is what it did before this existed.
    /// </summary>
    [JsonPropertyName("itemCache")] public ItemCacheSpec? ItemCache { get; set; }
}

/// <summary>
/// One published item cache. Two hashes on purpose: <see cref="Sha256"/> pins the gzip as the
/// host serves it (the same guarantee the MPQs get), <see cref="ContentSha256"/> pins what
/// comes out of it, which is the file the client actually parses.
/// </summary>
public sealed class ItemCacheSpec
{
    /// <summary>
    /// Opaque version token. Any change means "install this"; equality means "leave it alone".
    /// It is never compared to the file's contents, because the client rewrites those.
    /// </summary>
    [JsonPropertyName("epoch")] public string Epoch { get; set; } = "";

    /// <summary>Gzipped itemcache.wdb on the patch host. Published filenames are immutable.</summary>
    [JsonPropertyName("url")] public string Url { get; set; } = "";

    /// <summary>SHA-256 of the gzip as downloaded.</summary>
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";

    /// <summary>Size of the gzip, for the log line and a sanity check.</summary>
    [JsonPropertyName("size")] public long Size { get; set; }

    /// <summary>SHA-256 of the decompressed itemcache.wdb.</summary>
    [JsonPropertyName("contentSha256")] public string ContentSha256 { get; set; } = "";

    /// <summary>Size of the decompressed itemcache.wdb. 0 skips the size check.</summary>
    [JsonPropertyName("contentSize")] public long ContentSize { get; set; }

    /// <summary>
    /// Client languages this file is correct for.
    ///
    /// The generator writes an enUS locale into the WDB header and builds names and
    /// descriptions from the base item_template columns (item_template_locale has no enUS
    /// rows). None of that is right for a deDE client, and no client has ever been observed
    /// loading a cache whose header locale disagrees with its own — so anything not listed
    /// here gets the old wipe-only behaviour rather than a guess.
    ///
    /// The default is deliberately restrictive: a manifest that forgets the field installs to
    /// enUS clients only.
    /// </summary>
    [JsonPropertyName("locales")] public List<string> Locales { get; set; } = new() { "enUS" };

    /// <summary>Enough of an entry to act on. A block missing any of these is treated as absent.</summary>
    public bool IsUsable =>
        !string.IsNullOrWhiteSpace(Epoch) &&
        !string.IsNullOrWhiteSpace(Url) &&
        !string.IsNullOrWhiteSpace(Sha256);

    public bool AppliesToLocale(string code) =>
        Locales.Any(l => l.Equals(code, StringComparison.OrdinalIgnoreCase));
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

    /// <summary>
    /// HTTP fallback split across several archives, all extracted into the same folder.
    ///
    /// The mirrors worth using do not necessarily ship one file. The Internet Archive's copy
    /// is split by language -- a 14 GB Common.zip plus a ~2.5 GB locale zip -- and taking
    /// only the first would produce a client with no locale data: an install that looks
    /// finished, launches, and is broken in a way that reads as our fault.
    ///
    /// Takes precedence over DirectDownloadUrl when both are set. Order matters only in that
    /// they are fetched in sequence; each is extracted over the last.
    /// </summary>
    [JsonPropertyName("directDownloadUrls")] public List<ClientArchive> DirectDownloadUrls { get; set; } = new();

    /// <summary>
    /// Most disk the download folder needs at once.
    ///
    /// With a split download each part is extracted and deleted before the next is fetched,
    /// so the peak is the LARGEST single part, not their total. Using the total would tell a
    /// player they need 16 GB free to download when they need 14 -- and refuse an install
    /// that would have worked.
    /// </summary>
    public long PeakArchiveBytes()
    {
        var parts = HttpArchives();
        if (parts.Count == 0) return ArchiveBytes;

        long largest = 0;
        foreach (var p in parts) largest = Math.Max(largest, p.Bytes);

        // The torrent path still lands one whole archive, so respect whichever is bigger.
        return Math.Max(largest, ArchiveBytes);
    }

    /// <summary>Resolves the two forms above into one list, so callers need not care which was used.</summary>
    public IReadOnlyList<ClientArchive> HttpArchives()
    {
        if (DirectDownloadUrls.Count > 0) return DirectDownloadUrls;

        if (!string.IsNullOrWhiteSpace(DirectDownloadUrl))
            return new List<ClientArchive>
            {
                new() { Url = DirectDownloadUrl!, Name = ArchiveName, Bytes = ArchiveBytes },
            };

        return Array.Empty<ClientArchive>();
    }

    [JsonPropertyName("archiveName")] public string ArchiveName { get; set; } = "client.zip";

    /// <summary>
    /// Size of the downloaded .zip. Needed on the drive holding %LOCALAPPDATA%, which is not
    /// necessarily the drive the game is installed to.
    /// </summary>
    [JsonPropertyName("archiveBytes")] public long ArchiveBytes { get; set; }

    /// <summary>Size of the client once extracted. Needed on the install drive.</summary>
    [JsonPropertyName("installedBytes")] public long InstalledBytes { get; set; }
}

/// <summary>One archive of a multi-part HTTP client download.</summary>
public sealed class ClientArchive
{
    [JsonPropertyName("url")] public string Url { get; set; } = "";

    /// <summary>Filename to save as. Only needs to be unique within one download.</summary>
    [JsonPropertyName("name")] public string Name { get; set; } = "";

    /// <summary>Expected size, for the disk-space check and the progress bar. 0 = unknown.</summary>
    [JsonPropertyName("bytes")] public long Bytes { get; set; }
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

/// <summary>
/// A zip downloaded from an external host and expanded into the install.
///
/// Unlike <see cref="ManifestFile"/> these are not tracked per-file: we record only which
/// <see cref="Sha256"/> was last unpacked, so a re-extract happens when the pinned archive
/// changes and not on every launch. That also means an archive's contents are never pruned,
/// which is correct — everything shipped this way is third-party, and the standing rule is
/// that the launcher never deletes an addon it did not write.
/// </summary>
public sealed class ManifestArchive
{
    /// <summary>Stable key used to remember what has been unpacked. Not a filename.</summary>
    [JsonPropertyName("name")] public string Name { get; set; } = "";

    [JsonPropertyName("url")] public string Url { get; set; } = "";
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";
    [JsonPropertyName("size")] public long Size { get; set; }

    /// <summary>
    /// Install-root-relative directory the zip is expanded into, forward slashes. The archive
    /// carries its own top-level folders, so this is the parent — "Interface/AddOns", not
    /// "Interface/AddOns/ArkInventory".
    /// </summary>
    [JsonPropertyName("extractTo")] public string ExtractTo { get; set; } = "";

    /// <summary>
    /// A path that must exist for the archive to count as installed, install-root-relative.
    /// Without this, a player who deletes the addon folder would never get it back: the state
    /// file still says the sha is unpacked. Optional; empty means "trust the recorded sha".
    /// </summary>
    [JsonPropertyName("verifyPath")] public string? VerifyPath { get; set; }

    /// <summary>Shown in the launcher while it downloads. Falls back to <see cref="Name"/>.</summary>
    [JsonPropertyName("label")] public string? Label { get; set; }
}
