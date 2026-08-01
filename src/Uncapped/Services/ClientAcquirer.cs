using System.IO.Compression;
using MonoTorrent;
using MonoTorrent.Client;
using Uncapped.Model;

namespace Uncapped.Services;

public sealed record AcquireProgress(string Status, double Fraction, string Detail);

/// <summary>
/// Fetches the base client when the player has none, via BitTorrent, with an HTTP fallback.
///
/// Two deliberate choices here:
///
/// - Outbound-only by default (no inbound listener, DHT off). A torrent client that accepts
///   inbound connections triggers a Windows Firewall dialog on first run, which is exactly
///   the kind of scary prompt worth avoiding for an unsigned binary. The cost is slower peer
///   discovery; the magnet's trackers still supply peers. Flip torrentAllowInbound in the
///   config if the swarm proves hard to reach.
///
/// - Disk space is checked before a single byte is transferred. The archive and its
///   extraction coexist, so roughly twice the client size must be free.
/// </summary>
public sealed class ClientAcquirer
{
    private readonly HttpClient _http;
    private readonly bool _allowInbound;

    public ClientAcquirer(HttpClient http, bool allowInbound)
    {
        _http = http;
        _allowInbound = allowInbound;
    }

    private static string? DriveOf(string dir)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(dir));
            return string.IsNullOrEmpty(root) ? null : root;
        }
        catch { return null; }
    }

    private static long FreeOn(string drive)
    {
        try { return new DriveInfo(drive).AvailableFreeSpace; }
        catch { return long.MaxValue; } // unknown drive: do not block on a check we cannot make
    }

    /// <summary>
    /// The archive downloads to %LOCALAPPDATA% and extracts to the install folder, which are
    /// often on different drives. Checking only the install drive would let C: fill up
    /// silently. Both are checked, and combined when they are the same drive.
    /// </summary>
    public static void EnsureEnoughSpace(string targetDir, ClientSource source)
    {
        var downloadDrive = DriveOf(AppPaths.DownloadDir);
        var installDrive = DriveOf(targetDir);
        if (downloadDrive is null || installDrive is null) return;

        var sameDrive = string.Equals(downloadDrive, installDrive, StringComparison.OrdinalIgnoreCase);

        if (sameDrive)
        {
            var needed = source.PeakArchiveBytes() + source.InstalledBytes;
            var free = FreeOn(installDrive);
            if (free < needed)
                throw new IOException(
                    $"Not enough space on {installDrive.TrimEnd('\\')}. The download and the unpacked " +
                    $"game exist side by side for a while, so about {Gb(needed)} is needed but only " +
                    $"{Gb(free)} is free.");
            return;
        }

        var freeDownload = FreeOn(downloadDrive);
        if (freeDownload < source.PeakArchiveBytes())
            throw new IOException(
                $"Not enough space on {downloadDrive.TrimEnd('\\')} for the download. About " +
                $"{Gb(source.PeakArchiveBytes())} is needed there (the launcher downloads to " +
                $"{AppPaths.DownloadDir}), but only {Gb(freeDownload)} is free.");

        var freeInstall = FreeOn(installDrive);
        if (freeInstall < source.InstalledBytes)
            throw new IOException(
                $"Not enough space on {installDrive.TrimEnd('\\')} for the game. About " +
                $"{Gb(source.InstalledBytes)} is needed but only {Gb(freeInstall)} is free.");
    }

    public async Task<string> AcquireAsync(
        ClientSource source,
        string targetDir,
        IProgress<AcquireProgress> progress,
        CancellationToken ct)
    {
        EnsureEnoughSpace(targetDir, source);

        Directory.CreateDirectory(targetDir);
        Directory.CreateDirectory(AppPaths.DownloadDir);

        /*
         * The HTTP route can be several archives, not one.
         *
         * Mirrors do not all ship a single file -- the Internet Archive's copy is split into
         * a ~14 GB Common.zip plus a per-language zip. Downloading only the first would give
         * a client with no locale data: it installs, it launches, and it is broken in a way
         * that looks like our bug rather than a half-finished download. So the fallback
         * works in terms of a LIST, and a single directDownloadUrl is just a list of one.
         */
        var httpArchives = source.HttpArchives();

        if (!string.IsNullOrWhiteSpace(source.Magnet))
        {
            try
            {
                var archive = await DownloadViaTorrentAsync(source, progress, ct);
                await ExtractAndDeleteAsync(archive, targetDir, progress, ct);
                return targetDir;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) when (httpArchives.Count > 0)
            {
                // Some ISPs and most corporate/university networks throttle or block
                // BitTorrent outright. Say so plainly, then try the mirror.
                progress.Report(new AcquireProgress(
                    "BitTorrent did not work — trying the direct download instead.", 0, ex.Message));
            }
        }
        else if (httpArchives.Count == 0)
        {
            throw new InvalidOperationException("The manifest lists no way to download the client.");
        }

        if (httpArchives.Count == 0)
            throw new InvalidOperationException("The manifest lists no way to download the client.");

        /*
         * One at a time, extracting each before fetching the next.
         *
         * Not all-then-extract: holding every part on disk at once would need 16 GB of
         * downloads beside the unpacked game, on a drive we have already told the player only
         * needs room for the largest single part.
         */
        for (var i = 0; i < httpArchives.Count; i++)
        {
            var part = httpArchives[i];
            var label = httpArchives.Count > 1 ? $" (part {i + 1} of {httpArchives.Count})" : "";

            var archive = await DownloadOneAsync(part, label, progress, ct);
            await ExtractAndDeleteAsync(archive, targetDir, progress, ct);
        }

        return targetDir;
    }

    private async Task<string> DownloadViaTorrentAsync(
        ClientSource source, IProgress<AcquireProgress> progress, CancellationToken ct)
    {
        if (!MagnetLink.TryParse(source.Magnet ?? "", out var magnet) || magnet is null)
            throw new InvalidDataException("The magnet link in the manifest is not valid.");

        var settings = new EngineSettingsBuilder
        {
            CacheDirectory = AppPaths.TorrentCacheDir,
            AllowPortForwarding = _allowInbound,
            // Null endpoints mean "do not listen" — no inbound socket, so no firewall prompt.
            DhtEndPoint = _allowInbound ? new System.Net.IPEndPoint(System.Net.IPAddress.Any, 0) : null,
        };

        if (_allowInbound)
            settings.ListenEndPoints = new Dictionary<string, System.Net.IPEndPoint>
            {
                { "ipv4", new System.Net.IPEndPoint(System.Net.IPAddress.Any, 0) },
            };
        else
            settings.ListenEndPoints = new Dictionary<string, System.Net.IPEndPoint>();

        using var engine = new ClientEngine(settings.ToSettings());

        var manager = await engine.AddAsync(magnet, AppPaths.DownloadDir);
        await manager.StartAsync();

        try
        {
            var stalledFor = TimeSpan.Zero;
            var metadataFor = TimeSpan.Zero;
            var tick = TimeSpan.FromSeconds(1);

            while (manager.State != TorrentState.Seeding && manager.Complete == false)
            {
                ct.ThrowIfCancellationRequested();
                await Task.Delay(tick, ct);

                if (manager.State == TorrentState.Error)
                    throw new IOException(
                        manager.Error?.Exception.Message ?? "The torrent stopped with an error.");

                var peers = manager.Peers.Available + manager.Peers.Seeds + manager.Peers.Leechs;
                var rate = manager.Monitor.DownloadRate;

                /*
                 * Show the peer count even while fetching metadata.
                 *
                 * This used to read a bare "Fetching torrent details…" for the whole
                 * Metadata state, which hides the one number that says what is wrong.
                 * "0 peer(s)" means nothing was found at all -- blocked UDP, so dead
                 * trackers and a DHT that cannot bootstrap. A non-zero count with no
                 * progress means peers were found but will not hand over the metadata,
                 * which is a completely different problem. Guessing between those two
                 * from a screenshot cost a player an evening.
                 */
                var detail = manager.State == TorrentState.Metadata
                    ? $"Fetching torrent details… {peers} peer(s)"
                    : $"{peers} peer(s) · {Mb(rate)}/s";

                progress.Report(new AcquireProgress(
                    "Downloading the game client", manager.Progress / 100.0, detail));

                // Distinguish "slow" from "nobody is there". A dead swarm should produce a
                // clear message rather than an indefinite 0% bar.
                if (rate == 0 && peers == 0) stalledFor += tick; else stalledFor = TimeSpan.Zero;

                if (stalledFor > TimeSpan.FromMinutes(3))
                    throw new TimeoutException(
                        "No peers found after 3 minutes. Your network may be blocking BitTorrent. " +
                        "You can instead point the launcher at an existing 3.3.5a client with " +
                        "\"Change game folder\".");

                /*
                 * Metadata stall. The check above only fires when peers AND rate are both
                 * zero, so a torrent that finds peers but never receives the metadata sat
                 * on this screen indefinitely -- no progress, no error, nothing to report.
                 * Time the metadata phase separately and fail with something actionable.
                 */
                if (manager.State == TorrentState.Metadata)
                {
                    metadataFor += tick;
                    if (metadataFor > TimeSpan.FromMinutes(5))
                        throw new TimeoutException(
                            $"Could not fetch the torrent details after 5 minutes ({peers} peer(s) seen). " +
                            "Your network is likely blocking BitTorrent. Point the launcher at an " +
                            "existing 3.3.5a client with \"Change game folder\" instead.");
                }
                else
                    metadataFor = TimeSpan.Zero;
            }
        }
        finally
        {
            try { await engine.StopAllAsync(); } catch { /* shutting down anyway */ }
        }

        // The torrent's payload is a single .zip (ChromieCraft_3.3.5a.zip). Prefer the exact
        // name from the manifest; fall back to the largest .zip in case the torrent is ever
        // repacked under a different name.
        var expected = Path.Combine(AppPaths.DownloadDir, source.ArchiveName);
        if (File.Exists(expected)) return expected;

        var file = Directory.EnumerateFiles(AppPaths.DownloadDir, "*.zip", SearchOption.AllDirectories)
            .OrderByDescending(f => new FileInfo(f).Length)
            .FirstOrDefault();

        return file ?? throw new FileNotFoundException(
            $"The torrent finished but no .zip was found in {AppPaths.DownloadDir}.");
    }

    /// <summary>
    /// A safe local filename from a URL, for a manifest entry that omits one. Query strings
    /// and stray path characters are stripped -- this becomes a real path on disk.
    /// </summary>
    private static string SafeNameFromUrl(string url)
    {
        var name = "client.zip";
        try
        {
            var path = new Uri(url).AbsolutePath;
            var candidate = Path.GetFileName(path);
            if (!string.IsNullOrWhiteSpace(candidate)) name = candidate;
        }
        catch { /* not a well-formed absolute URI; the default will do */ }

        foreach (var bad in Path.GetInvalidFileNameChars()) name = name.Replace(bad, '_');
        return name;
    }

    /// <summary>Extracts an archive into the target, then removes it before the next one.</summary>
    private async Task ExtractAndDeleteAsync(
        string archive, string targetDir, IProgress<AcquireProgress> progress, CancellationToken ct)
    {
        progress.Report(new AcquireProgress("Extracting the client… this takes a while.", 0, archive));
        await Task.Run(() => ExtractTo(archive, targetDir, progress, ct), ct);

        // Deleted as we go, not at the end: with a split download the parts would otherwise
        // pile up beside the game they are being unpacked into.
        try { File.Delete(archive); } catch { /* leave it; the player can clear it manually */ }
    }

    private async Task<string> DownloadOneAsync(
        ClientArchive part, string label, IProgress<AcquireProgress> progress, CancellationToken ct)
    {
        var name = string.IsNullOrWhiteSpace(part.Name)
            ? SafeNameFromUrl(part.Url)
            : part.Name;

        var destination = Path.Combine(AppPaths.DownloadDir, name);

        using var response = await _http.GetAsync(
            part.Url, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();

        var expected = response.Content.Headers.ContentLength ?? part.Bytes;

        await using (var input = await response.Content.ReadAsStreamAsync(ct))
        await using (var output = new FileStream(destination, FileMode.Create, FileAccess.Write,
                                                 FileShare.None, 1024 * 256, useAsync: true))
        {
            var buffer = new byte[1024 * 256];
            long copied = 0;
            int read;

            while ((read = await input.ReadAsync(buffer, ct)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, read), ct);
                copied += read;

                progress.Report(new AcquireProgress(
                    "Downloading the game client" + label,
                    expected > 0 ? (double)copied / expected : 0,
                    $"{Gb(copied)} of {Gb(expected)}"));
            }
        }

        return destination;
    }

    private static void ExtractTo(
        string archivePath, string targetDir, IProgress<AcquireProgress> progress, CancellationToken ct)
    {
        using var zip = ZipFile.OpenRead(archivePath);

        var entries = zip.Entries;
        var root = Path.GetFullPath(targetDir);

        for (var i = 0; i < entries.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var entry = entries[i];

            if (string.IsNullOrEmpty(entry.Name)) continue; // directory entry

            var destination = Path.GetFullPath(Path.Combine(targetDir, entry.FullName));

            // Zip-slip guard: an entry named ..\..\something must not write outside the target.
            if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;

            var dir = Path.GetDirectoryName(destination);
            if (dir is not null) Directory.CreateDirectory(dir);

            entry.ExtractToFile(destination, overwrite: true);

            if (i % 25 == 0)
                progress.Report(new AcquireProgress(
                    "Extracting the client", (double)i / entries.Count, entry.Name));
        }
    }

    private static string Gb(long bytes) => $"{bytes / 1024.0 / 1024 / 1024:0.0} GB";
    private static string Mb(long bytesPerSecond) => $"{bytesPerSecond / 1024.0 / 1024:0.0} MB";
}
