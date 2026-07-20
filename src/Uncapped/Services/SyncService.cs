using System.Collections.Concurrent;
using Uncapped.Model;

namespace Uncapped.Services;

public sealed record SyncProgress(string Status, int Completed, int Total);

public sealed record SyncOutcome(
    int Downloaded, int UpToDate, int Removed, List<string> Errors)
{
    public bool ChangedAnything => Downloaded > 0 || Removed > 0;
}

/// <summary>
/// Hashes what is on disk, downloads only what differs, and places files. Integrity checking
/// is scoped to files the manifest lists — verifying the whole 17 GB client every launch was
/// explicitly out of scope, and the base client is never modified by us anyway.
/// </summary>
public sealed class SyncService
{
    /// <summary>
    /// Files in flight at once. The payload is ~720 small files, so wall-clock time is
    /// dominated by per-request round-trips to GitHub rather than bandwidth — downloading
    /// sequentially took over five minutes for 19 MB. Six is well within what raw
    /// .githubusercontent.com serves happily and keeps the first run under a minute.
    /// </summary>
    private const int DownloadConcurrency = 6;

    /// <summary>Hashing is disk-bound; a little more parallelism helps and costs nothing.</summary>
    private const int HashConcurrency = 8;

    private readonly HttpClient _http;

    public SyncService(HttpClient http) => _http = http;

    public async Task<SyncOutcome> SyncAsync(
        string installPath,
        Manifest manifest,
        LauncherState state,
        IProgress<SyncProgress> progress,
        CancellationToken ct)
    {
        var errors = new ConcurrentBag<string>();
        var installed = new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in state.InstalledFiles) installed.TryAdd(f, 0);

        // ---- Phase 1: work out what actually needs fetching. ----
        var total = manifest.Files.Count;
        var checkedCount = 0;
        var upToDate = 0;
        var needed = new ConcurrentBag<(ManifestFile File, string Relative)>();

        await Parallel.ForEachAsync(
            manifest.Files,
            new ParallelOptions { MaxDegreeOfParallelism = HashConcurrency, CancellationToken = ct },
            async (file, token) =>
            {
                var relative = NormalizeRelative(file.Path);
                if (relative is null)
                {
                    // Guards against a manifest entry escaping the install root via .. or an
                    // absolute path. The manifest is ours, but it is also the one input
                    // fetched over the network, so it does not get to write anywhere it likes.
                    errors.Add($"Rejected unsafe path in manifest: {file.Path}");
                    return;
                }

                var destination = Path.Combine(installPath, relative);

                if (await IsCurrentAsync(destination, file, token))
                {
                    Interlocked.Increment(ref upToDate);
                    installed.TryAdd(relative, 0);
                }
                else
                {
                    needed.Add((file, relative));
                }

                var done = Interlocked.Increment(ref checkedCount);
                progress.Report(new SyncProgress("Checking your files", done, total));
            });

        // ---- Phase 2: download what is missing or changed, several at a time. ----
        var work = needed.ToArray();
        var downloaded = 0;

        if (work.Length > 0)
        {
            var completed = 0;

            await Parallel.ForEachAsync(
                work,
                new ParallelOptions { MaxDegreeOfParallelism = DownloadConcurrency, CancellationToken = ct },
                async (item, token) =>
                {
                    var destination = Path.Combine(installPath, item.Relative);

                    try
                    {
                        await DownloadAsync(item.File, destination, token);
                        Interlocked.Increment(ref downloaded);
                        installed.TryAdd(item.Relative, 0);
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception ex)
                    {
                        errors.Add($"{item.Relative}: {ex.Message}");
                    }

                    var done = Interlocked.Increment(ref completed);
                    progress.Report(new SyncProgress(
                        $"Downloading {Path.GetFileName(item.Relative)}", done, work.Length));
                });
        }

        // ---- Phase 3: prune, single-threaded. ----
        state.InstalledFiles = installed.Keys.ToList();
        var errorList = errors.ToList();
        var removed = PruneOrphans(installPath, manifest, state, errorList);

        state.LastSyncedManifestVersion = manifest.LauncherVersion;
        state.Save();

        return new SyncOutcome(downloaded, upToDate, removed, errorList);
    }

    private static async Task<bool> IsCurrentAsync(string destination, ManifestFile file, CancellationToken ct)
    {
        if (!File.Exists(destination)) return false;

        // Size is a free pre-filter; only pay for the hash when it could plausibly match.
        if (file.Size > 0 && new FileInfo(destination).Length != file.Size) return false;
        if (string.IsNullOrEmpty(file.Sha256)) return true;

        try { return Hashing.Matches(await Hashing.Sha256FileAsync(destination, ct), file.Sha256); }
        catch { return false; }
    }

    private async Task DownloadAsync(ManifestFile file, string destination, CancellationToken ct)
    {
        var dir = Path.GetDirectoryName(destination);
        if (dir is not null) Directory.CreateDirectory(dir);

        // Download to a unique temp file beside the destination and move into place only
        // after the hash checks out. A half-written MPQ in Data\ is a broken client; a
        // leftover .tmp is not. The GUID keeps concurrent workers from colliding.
        var temp = $"{destination}.{Guid.NewGuid():N}.uncapped-tmp";

        try
        {
            using var response = await _http.GetAsync(file.Url, HttpCompletionOption.ResponseHeadersRead, ct);
            response.EnsureSuccessStatusCode();

            await using (var source = await response.Content.ReadAsStreamAsync(ct))
            await using (var target = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None,
                                                     1024 * 64, useAsync: true))
                await source.CopyToAsync(target, ct);

            if (!string.IsNullOrEmpty(file.Sha256))
            {
                var actual = await Hashing.Sha256FileAsync(temp, ct);
                if (!Hashing.Matches(actual, file.Sha256))
                    throw new InvalidDataException(
                        $"checksum mismatch (expected {file.Sha256[..Math.Min(12, file.Sha256.Length)]}…, " +
                        $"got {actual[..12]}…)");
            }

            File.Move(temp, destination, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp)) { try { File.Delete(temp); } catch { /* best effort */ } }
        }
    }

    /// <summary>
    /// Removes files we previously installed that have dropped out of the manifest — but only
    /// under manifest.OwnedPaths, i.e. addons we wrote ourselves. Third-party addons are
    /// install-only: once placed, the launcher never deletes them, even if they leave the
    /// manifest. That is a deliberate standing rule, not an oversight.
    /// </summary>
    private static int PruneOrphans(string installPath, Manifest manifest, LauncherState state, List<string> errors)
    {
        if (manifest.OwnedPaths.Count == 0) return 0;

        var current = manifest.Files
            .Select(f => NormalizeRelative(f.Path))
            .Where(p => p is not null)
            .ToHashSet(StringComparer.OrdinalIgnoreCase)!;

        var removed = 0;
        var survivors = new List<string>();

        foreach (var tracked in state.InstalledFiles)
        {
            if (current.Contains(tracked)) { survivors.Add(tracked); continue; }

            if (!IsOwned(tracked, manifest.OwnedPaths)) { survivors.Add(tracked); continue; }

            var path = Path.Combine(installPath, tracked);
            try
            {
                if (File.Exists(path)) { File.Delete(path); removed++; }
                CleanEmptyDirs(Path.GetDirectoryName(path), installPath);
            }
            catch (Exception ex) { errors.Add($"Could not remove {tracked}: {ex.Message}"); survivors.Add(tracked); }
        }

        state.InstalledFiles = survivors;
        return removed;
    }

    private static bool IsOwned(string relative, IEnumerable<string> ownedPaths) =>
        ownedPaths
            .Select(NormalizeRelative)
            .Where(p => p is not null)
            .Any(p => relative.StartsWith(p! + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                   || relative.Equals(p, StringComparison.OrdinalIgnoreCase));

    private static void CleanEmptyDirs(string? dir, string stopAt)
    {
        var root = Path.GetFullPath(stopAt);
        while (!string.IsNullOrEmpty(dir))
        {
            var full = Path.GetFullPath(dir);
            if (full.Equals(root, StringComparison.OrdinalIgnoreCase)) return;
            if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return;
            if (!Directory.Exists(full)) return;
            if (Directory.EnumerateFileSystemEntries(full).Any()) return;

            try { Directory.Delete(full); } catch { return; }
            dir = Path.GetDirectoryName(full);
        }
    }

    /// <summary>
    /// Converts a manifest path to a safe install-root-relative Windows path, or null if it
    /// tries to escape the root.
    /// </summary>
    public static string? NormalizeRelative(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;

        var cleaned = path.Replace('/', Path.DirectorySeparatorChar).Trim();
        if (Path.IsPathRooted(cleaned)) return null;

        var parts = cleaned.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Any(p => p == ".." || p == ".")) return null;
        if (parts.Length == 0) return null;

        return string.Join(Path.DirectorySeparatorChar, parts);
    }
}
