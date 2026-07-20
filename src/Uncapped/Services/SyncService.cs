using Uncapped.Model;

namespace Uncapped.Services;

public sealed record SyncProgress(string Status, int Current, int Total, double FileFraction);

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
    private readonly HttpClient _http;

    public SyncService(HttpClient http) => _http = http;

    public async Task<SyncOutcome> SyncAsync(
        string installPath,
        Manifest manifest,
        LauncherState state,
        IProgress<SyncProgress> progress,
        CancellationToken ct)
    {
        var errors = new List<string>();
        int downloaded = 0, upToDate = 0;

        var total = manifest.Files.Count;
        var index = 0;

        foreach (var file in manifest.Files)
        {
            ct.ThrowIfCancellationRequested();
            index++;

            var relative = NormalizeRelative(file.Path);
            if (relative is null)
            {
                // Guards against a manifest entry escaping the install root via .. or an
                // absolute path. The manifest is ours, but it is also the one input fetched
                // over the network, so it does not get to write anywhere it likes.
                errors.Add($"Rejected unsafe path in manifest: {file.Path}");
                continue;
            }

            var destination = Path.Combine(installPath, relative);
            var name = Path.GetFileName(relative);

            progress.Report(new SyncProgress($"Checking {name}", index, total, 0));

            if (await IsCurrentAsync(destination, file, ct))
            {
                upToDate++;
                Remember(state, relative);
                continue;
            }

            progress.Report(new SyncProgress($"Downloading {name}", index, total, 0));

            try
            {
                await DownloadAsync(file, destination, name, index, total, progress, ct);
                downloaded++;
                Remember(state, relative);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                errors.Add($"{relative}: {ex.Message}");
            }
        }

        var removed = PruneOrphans(installPath, manifest, state, errors);

        state.LastSyncedManifestVersion = manifest.LauncherVersion;
        state.Save();

        return new SyncOutcome(downloaded, upToDate, removed, errors);
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

    private async Task DownloadAsync(
        ManifestFile file, string destination, string name,
        int index, int total, IProgress<SyncProgress> progress, CancellationToken ct)
    {
        var dir = Path.GetDirectoryName(destination);
        if (dir is not null) Directory.CreateDirectory(dir);

        // Download to a temp file beside the destination and move into place only after the
        // hash checks out. A half-written MPQ in Data\ is a broken client; a leftover .tmp is
        // not.
        var temp = destination + ".uncapped-tmp";

        try
        {
            using var response = await _http.GetAsync(file.Url, HttpCompletionOption.ResponseHeadersRead, ct);
            response.EnsureSuccessStatusCode();

            var expected = response.Content.Headers.ContentLength ?? file.Size;

            await using (var source = await response.Content.ReadAsStreamAsync(ct))
            await using (var target = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None,
                                                     1024 * 128, useAsync: true))
            {
                var buffer = new byte[1024 * 128];
                long copied = 0;
                int read;

                while ((read = await source.ReadAsync(buffer, ct)) > 0)
                {
                    await target.WriteAsync(buffer.AsMemory(0, read), ct);
                    copied += read;

                    var fraction = expected > 0 ? Math.Min(1.0, (double)copied / expected) : 0;
                    progress.Report(new SyncProgress($"Downloading {name}", index, total, fraction));
                }
            }

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

    private static void Remember(LauncherState state, string relative)
    {
        if (!state.InstalledFiles.Contains(relative, StringComparer.OrdinalIgnoreCase))
            state.InstalledFiles.Add(relative);
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
