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
            var needed = source.ArchiveBytes + source.InstalledBytes;
            var free = FreeOn(installDrive);
            if (free < needed)
                throw new IOException(
                    $"Not enough space on {installDrive.TrimEnd('\\')}. The download and the unpacked " +
                    $"game exist side by side for a while, so about {Gb(needed)} is needed but only " +
                    $"{Gb(free)} is free.");
            return;
        }

        var freeDownload = FreeOn(downloadDrive);
        if (freeDownload < source.ArchiveBytes)
            throw new IOException(
                $"Not enough space on {downloadDrive.TrimEnd('\\')} for the download. About " +
                $"{Gb(source.ArchiveBytes)} is needed there (the launcher downloads to " +
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

        string archive;
        if (!string.IsNullOrWhiteSpace(source.Magnet))
        {
            try
            {
                archive = await DownloadViaTorrentAsync(source, progress, ct);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) when (!string.IsNullOrWhiteSpace(source.DirectDownloadUrl))
            {
                // Some ISPs and most corporate/university networks throttle or block
                // BitTorrent outright. Say so plainly, then try the mirror.
                progress.Report(new AcquireProgress(
                    "BitTorrent did not work — trying the direct download instead.", 0, ex.Message));
                archive = await DownloadViaHttpAsync(source, progress, ct);
            }
        }
        else if (!string.IsNullOrWhiteSpace(source.DirectDownloadUrl))
        {
            archive = await DownloadViaHttpAsync(source, progress, ct);
        }
        else
        {
            throw new InvalidOperationException("The manifest lists no way to download the client.");
        }

        progress.Report(new AcquireProgress("Extracting the client… this takes a while.", 0, archive));
        await Task.Run(() => ExtractTo(archive, targetDir, progress, ct), ct);

        try { File.Delete(archive); } catch { /* leave it; the player can clear it manually */ }

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

                var detail = manager.State == TorrentState.Metadata
                    ? "Fetching torrent details…"
                    : $"{peers} peer(s) · {Mb(rate)}/s";

                progress.Report(new AcquireProgress(
                    "Downloading the game client", manager.Progress / 100.0, detail));

                // Distinguish "slow" from "nobody is there". A dead swarm should produce a
                // clear message rather than an indefinite 0% bar.
                if (rate == 0 && peers == 0) stalledFor += tick; else stalledFor = TimeSpan.Zero;

                if (stalledFor > TimeSpan.FromMinutes(3))
                    throw new TimeoutException(
                        "No peers found after 3 minutes. Your network may be blocking BitTorrent.");
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

    private async Task<string> DownloadViaHttpAsync(
        ClientSource source, IProgress<AcquireProgress> progress, CancellationToken ct)
    {
        var destination = Path.Combine(AppPaths.DownloadDir, source.ArchiveName);

        using var response = await _http.GetAsync(
            source.DirectDownloadUrl!, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();

        var expected = response.Content.Headers.ContentLength ?? 0;

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
                    "Downloading the game client",
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
