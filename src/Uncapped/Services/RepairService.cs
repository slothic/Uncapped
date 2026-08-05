using Uncapped.Model;

namespace Uncapped.Services;

public sealed record RepairOutcome(int Restored, int Quarantined, List<string> Errors)
{
    public bool DidAnything => Restored > 0 || Quarantined > 0;
}

/// <summary>
/// Puts a client back to what an Uncapped release actually is.
///
/// Two jobs, deliberately different in how much licence they take:
///
///   * Restoring — a file we published that is missing or wrong gets downloaded again. No
///     confirmation: replacing our own file with our own file is not a decision the player
///     needs to be consulted about.
///
///   * Quarantining — a foreign MPQ under Data\ is MOVED, never deleted, and only after the
///     caller has shown the player the list and got a yes. It goes to Data\_disabled\, where
///     it stops being loaded by the client and stays recoverable by dragging it back. The
///     standing rule that we never delete software we did not write applies with more force
///     here than anywhere, because the thing being removed may be the only copy someone has.
///
/// Third-party addons are never touched by any of this. See ForeignAddOnScanner.
/// </summary>
public sealed class RepairService
{
    /// <summary>
    /// Where foreign archives are moved to. Under Data\ rather than outside the install so a
    /// player can find it, and named with a leading underscore so it sorts to the top and is
    /// not mistaken for a locale folder.
    /// </summary>
    public const string QuarantineFolder = "_disabled";

    private readonly HttpClient _http;

    public RepairService(HttpClient http) => _http = http;

    /// <summary>
    /// Re-downloads what is broken. Only files carrying a URL can be handled here — a missing
    /// file the baseline does not host is reported and left, rather than silently counted as
    /// repaired.
    /// </summary>
    public async Task<RepairOutcome> RestoreAsync(
        string installPath,
        IReadOnlyList<IntegrityProblem> problems,
        LauncherState state,
        IProgress<SyncProgress> progress,
        CancellationToken ct)
    {
        var errors = new List<string>();
        var restored = 0;

        var fixable = problems
            .Where(p => p.Fault is IntegrityFault.Missing or IntegrityFault.Corrupt)
            .Where(p => !string.IsNullOrWhiteSpace(p.Url))
            .ToList();

        var unfixable = problems
            .Where(p => p.Fault is IntegrityFault.Missing or IntegrityFault.Corrupt)
            .Where(p => string.IsNullOrWhiteSpace(p.Url))
            .ToList();

        foreach (var p in unfixable)
            errors.Add($"{p.Path}: no download is published for this file.");

        // Sequential. These are multi-gigabyte archives and six at once would compete for the
        // same disk and the same link for no gain — unlike the payload, which is hundreds of
        // small files where round-trips dominate.
        var done = 0;
        foreach (var problem in fixable)
        {
            ct.ThrowIfCancellationRequested();

            var name = Path.GetFileName(problem.Path);
            progress.Report(new SyncProgress($"Downloading {name}", done, fixable.Count));

            try
            {
                await DownloadAsync(installPath, problem, ct);
                restored++;

                // The file just changed on disk, so whatever hash was remembered for it is
                // now wrong. Dropping the entry makes the next pass re-read it, which is the
                // honest thing to do after we have written to it ourselves.
                state.VerifiedFiles.Remove(problem.Path);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Log.Write($"repair: {problem.Path} — {ex}");
                errors.Add($"{problem.Path}: {ex.Message}");
            }

            progress.Report(new SyncProgress($"Restored {name}", ++done, fixable.Count));
        }

        state.Save();
        return new RepairOutcome(restored, 0, errors);
    }

    /// <summary>
    /// Moves foreign archives out of the client's way. The caller is responsible for having
    /// asked first — this method does not prompt, so that the confirmation lives next to the
    /// list the player was actually shown.
    /// </summary>
    public RepairOutcome Quarantine(
        string installPath, IReadOnlyList<IntegrityProblem> foreign, LauncherState state)
    {
        var errors = new List<string>();
        var moved = 0;

        var target = Path.Combine(installPath, "Data", QuarantineFolder);

        foreach (var problem in foreign)
        {
            var source = Path.Combine(installPath, problem.Path);
            if (!File.Exists(source)) continue;

            try
            {
                Directory.CreateDirectory(target);

                var destination = Path.Combine(target, Path.GetFileName(problem.Path));

                // Never overwrite something already in quarantine: two servers' patches can
                // share a filename, and the first one moved is not worth less than the second.
                if (File.Exists(destination))
                {
                    var stem = Path.GetFileNameWithoutExtension(destination);
                    var ext = Path.GetExtension(destination);
                    var n = 2;
                    while (File.Exists(destination))
                        destination = Path.Combine(target, $"{stem} ({n++}){ext}");
                }

                File.Move(source, destination);
                state.VerifiedFiles.Remove(problem.Path);
                moved++;

                Log.Write($"repair: quarantined {problem.Path} -> Data\\{QuarantineFolder}\\{Path.GetFileName(destination)}");
            }
            catch (Exception ex)
            {
                Log.Write($"repair: could not quarantine {problem.Path} — {ex}");
                errors.Add($"{problem.Path}: {ex.Message}");
            }
        }

        state.Save();
        return new RepairOutcome(0, moved, errors);
    }

    /// <summary>
    /// Downloads to a temp file beside the destination and moves it into place only once the
    /// hash is right — the same discipline SyncService uses, and for the same reason: a
    /// half-written 4 GB MPQ is a broken client, a leftover .tmp is not.
    /// </summary>
    private async Task DownloadAsync(string installPath, IntegrityProblem problem, CancellationToken ct)
    {
        var destination = Path.Combine(installPath, problem.Path);
        var dir = Path.GetDirectoryName(destination);
        if (dir is not null) Directory.CreateDirectory(dir);

        var temp = $"{destination}.{Guid.NewGuid():N}.uncapped-tmp";

        try
        {
            using var response = await _http.GetAsync(problem.Url, HttpCompletionOption.ResponseHeadersRead, ct);
            response.EnsureSuccessStatusCode();

            await using (var source = await response.Content.ReadAsStreamAsync(ct))
            await using (var target = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None,
                                                     1024 * 256, useAsync: true))
                await source.CopyToAsync(target, ct);

            var length = new FileInfo(temp).Length;
            if (problem.Size > 0 && length != problem.Size)
                throw new InvalidDataException($"expected {problem.Size:N0} bytes, got {length:N0}");

            // Hash, not just length. Repair exists because a file was wrong, so accepting a
            // replacement on size alone would let the same class of fault straight back in —
            // and this is the one download path where the file being restored is the one the
            // client is about to load.
            if (!string.IsNullOrEmpty(problem.Sha256))
            {
                var actual = await Hashing.Sha256FileAsync(temp, ct);
                if (!Hashing.Matches(actual, problem.Sha256))
                    throw new InvalidDataException(
                        $"checksum mismatch (expected {problem.Sha256[..Math.Min(12, problem.Sha256.Length)]}…, " +
                        $"got {actual[..12]}…)");
            }

            File.Move(temp, destination, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp)) { try { File.Delete(temp); } catch { /* best effort */ } }
        }
    }
}
