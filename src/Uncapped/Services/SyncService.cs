using System.Collections.Concurrent;
using System.IO.Compression;
using Uncapped.Model;

namespace Uncapped.Services;

public sealed record SyncProgress(string Status, int Completed, int Total);

public sealed record SyncOutcome(
    int Downloaded, int UpToDate, int Removed, List<string> Errors, List<ManifestFile> Mismatched,
    int ArchivesInstalled = 0)
{
    public bool ChangedAnything => Downloaded > 0 || Removed > 0 || ArchivesInstalled > 0;

    /// <summary>
    /// A file downloading cleanly but hashing to the wrong value means the host handed us
    /// something other than what the manifest describes — in practice, GitHub's CDN still
    /// serving the previous release. Worth distinguishing from a plain network failure,
    /// because it is fixed by waiting rather than by retrying immediately.
    /// </summary>
    public bool LooksLikeStaleHost => Mismatched.Count > 0;
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

    /// <param name="locale">
    /// The client's actual language, used to move the manifest's Data\enUS\ entries onto the
    /// folder this client really has. Null means install the paths as written — correct only
    /// when the locale could not be determined, in which case the caller has already refused
    /// to get this far.
    /// </param>
    public async Task<SyncOutcome> SyncAsync(
        string installPath,
        Manifest manifest,
        LauncherState state,
        ClientLocale? locale,
        IProgress<SyncProgress> progress,
        CancellationToken ct)
    {
        var errors = new ConcurrentBag<string>();
        var mismatched = new ConcurrentBag<ManifestFile>();

        // ---- Phase 0: undo an earlier launcher's guess at the locale. ----
        // Before anything is hashed: the stray folder holds files under names this sync is
        // about to stop using, and leaving them would keep the client broken for exactly as
        // long as the player left it alone.
        var strays = locale?.RemoveStrayFolders(installPath, state.InstalledFiles) ?? new List<string>();
        if (strays.Count > 0)
        {
            Log.Write($"locale: removed {strays.Count} file(s) from a stray locale folder — {string.Join(", ", strays)}");
            state.InstalledFiles = state.InstalledFiles
                .Where(f => !strays.Contains(f, StringComparer.OrdinalIgnoreCase))
                .ToList();
        }

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
                var relative = Place(file.Path, locale);
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
                    catch (InvalidDataException ex)
                    {
                        errors.Add($"{item.Relative}: {ex.Message}");
                        mismatched.Add(item.File);
                    }
                    catch (Exception ex)
                    {
                        errors.Add($"{item.Relative}: {ex.Message}");
                    }

                    var done = Interlocked.Increment(ref completed);
                    progress.Report(new SyncProgress(
                        $"Downloading {Path.GetFileName(item.Relative)}", done, work.Length));
                });
        }

        // ---- Phase 3: externally hosted archives. ----
        state.InstalledFiles = installed.Keys.ToList();
        var errorList = errors.ToList();
        var archivesInstalled = await SyncArchivesAsync(installPath, manifest, state, errorList, progress, ct);

        // ---- Phase 4: prune, single-threaded. ----
        var removed = PruneOrphans(installPath, manifest, state, locale, errorList);

        state.LastSyncedManifestVersion = manifest.LauncherVersion;
        state.Save();

        return new SyncOutcome(downloaded, upToDate, removed, errorList, mismatched.ToList(), archivesInstalled);
    }

    /// <summary>
    /// Downloads and expands the archives in <see cref="Manifest.Archives"/> — addons we are
    /// not entitled to redistribute, so they come from the author's own host instead of our
    /// payload. Sequential on purpose: there is currently one of these and it is under a
    /// megabyte, so concurrency would buy nothing and cost clarity.
    ///
    /// Failures are recorded and skipped rather than thrown. A CurseForge outage should leave
    /// the player with a client that is otherwise fully updated and playable, missing one
    /// optional bag addon, and it should retry by itself next launch.
    /// </summary>
    private async Task<int> SyncArchivesAsync(
        string installPath,
        Manifest manifest,
        LauncherState state,
        List<string> errors,
        IProgress<SyncProgress> progress,
        CancellationToken ct)
    {
        if (manifest.Archives.Count == 0) return 0;

        var done = 0;
        var installedCount = 0;

        foreach (var archive in manifest.Archives)
        {
            ct.ThrowIfCancellationRequested();

            var label = string.IsNullOrWhiteSpace(archive.Label) ? archive.Name : archive.Label!;
            var target = NormalizeRelative(archive.ExtractTo);

            if (string.IsNullOrWhiteSpace(archive.Name) || string.IsNullOrWhiteSpace(archive.Url) || target is null)
            {
                errors.Add($"Rejected malformed archive entry: {archive.Name}");
                continue;
            }

            // An archive with no hash cannot be verified, and cannot be known to be current
            // either. Refusing is safer than unpacking whatever the host happened to return.
            if (string.IsNullOrEmpty(archive.Sha256))
            {
                errors.Add($"{label}: archive has no sha256; refusing to install it.");
                continue;
            }

            if (IsArchiveCurrent(installPath, archive, state))
            {
                progress.Report(new SyncProgress($"{label} is up to date", ++done, manifest.Archives.Count));
                continue;
            }

            progress.Report(new SyncProgress($"Downloading {label}", done, manifest.Archives.Count));

            var temp = Path.Combine(Path.GetTempPath(), $"uncapped-{Guid.NewGuid():N}.zip");
            try
            {
                using (var response = await _http.GetAsync(archive.Url, HttpCompletionOption.ResponseHeadersRead, ct))
                {
                    response.EnsureSuccessStatusCode();

                    await using var source = await response.Content.ReadAsStreamAsync(ct);
                    await using var file = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None,
                                                          1024 * 64, useAsync: true);
                    await source.CopyToAsync(file, ct);
                }

                var actual = await Hashing.Sha256FileAsync(temp, ct);
                if (!Hashing.Matches(actual, archive.Sha256))
                {
                    // Pinned by hash precisely so that a third-party host swapping the bytes
                    // behind a URL cannot push unreviewed code into every player's client.
                    errors.Add($"{label}: checksum mismatch " +
                               $"(expected {archive.Sha256[..Math.Min(12, archive.Sha256.Length)]}…, got {actual[..12]}…)");
                    continue;
                }

                progress.Report(new SyncProgress($"Installing {label}", done, manifest.Archives.Count));

                ExtractInto(temp, Path.Combine(installPath, target), ct);

                state.InstalledArchives[archive.Name] = actual.ToLowerInvariant();
                installedCount++;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                errors.Add($"{label}: {ex.Message}");
            }
            finally
            {
                if (File.Exists(temp)) { try { File.Delete(temp); } catch { /* best effort */ } }
            }

            progress.Report(new SyncProgress($"Installed {label}", ++done, manifest.Archives.Count));
        }

        return installedCount;
    }

    /// <summary>
    /// True when the recorded sha matches and the archive's contents are still on disk. The
    /// second half matters: a player who deletes the addon folder must get it back, and the
    /// state file alone would claim it is already installed.
    /// </summary>
    private static bool IsArchiveCurrent(string installPath, ManifestArchive archive, LauncherState state)
    {
        if (!state.InstalledArchives.TryGetValue(archive.Name, out var recorded)) return false;
        if (!Hashing.Matches(recorded, archive.Sha256)) return false;

        if (string.IsNullOrWhiteSpace(archive.VerifyPath)) return true;

        var verify = NormalizeRelative(archive.VerifyPath!);
        if (verify is null) return true;

        var full = Path.Combine(installPath, verify);
        return File.Exists(full) || Directory.Exists(full);
    }

    /// <summary>
    /// Expands a zip into <paramref name="targetDir"/>, overwriting what is there. Existing
    /// files not in the archive are left alone, so a player's own additions survive.
    /// </summary>
    private static void ExtractInto(string archivePath, string targetDir, CancellationToken ct)
    {
        Directory.CreateDirectory(targetDir);

        using var zip = ZipFile.OpenRead(archivePath);
        var root = Path.GetFullPath(targetDir);

        foreach (var entry in zip.Entries)
        {
            ct.ThrowIfCancellationRequested();
            if (string.IsNullOrEmpty(entry.Name)) continue; // directory entry

            var destination = Path.GetFullPath(Path.Combine(targetDir, entry.FullName));

            // Zip-slip guard: an entry named ..\..\something must not write outside the target.
            // This archive comes from a third-party host, so the check is load-bearing here in
            // a way it is not for our own payload.
            if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;

            var dir = Path.GetDirectoryName(destination);
            if (dir is not null) Directory.CreateDirectory(dir);

            entry.ExtractToFile(destination, overwrite: true);
        }
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
    private static int PruneOrphans(
        string installPath, Manifest manifest, LauncherState state, ClientLocale? locale, List<string> errors)
    {
        if (manifest.OwnedPaths.Count == 0) return 0;

        var current = manifest.Files
            .Select(f => Place(f.Path, locale))
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
    /// Where a manifest entry actually lands: normalised, then moved onto the client's real
    /// locale. Every path the sync touches goes through here, so the placement rule cannot
    /// drift between downloading a file and pruning it later.
    /// </summary>
    private static string? Place(string manifestPath, ClientLocale? locale)
    {
        var relative = NormalizeRelative(manifestPath);
        return relative is null ? null : locale?.Remap(relative) ?? relative;
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
