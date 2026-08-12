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

        /*
         * ★ SPACE IS CHECKED ONCE, UP FRONT, RATHER THAN DISCOVERED SIX TIMES.
         *
         * A full repair of the archive.org build restores about 10.5 GB. Without this, a drive
         * with no room produced one cryptic IO error per file and a summary saying the repair
         * partly failed, with nothing pointing at the actual cause — and it would have spent
         * hours of a slow connection first. One clear sentence before anything is downloaded is
         * worth much more than six after.
         *
         * The requirement is deliberately not the sum of everything being restored. Files are
         * fetched one at a time and each replaces a file that is usually already there, so the
         * lasting cost is only what is genuinely MISSING; the transient cost is the largest
         * single file, which coexists as a .uncapped-tmp beside the old copy until it is moved
         * into place.
         */
        var needed =
            fixable.Where(p => p.Fault == IntegrityFault.Missing).Sum(p => Math.Max(0, p.Size)) +
            (fixable.Count == 0 ? 0 : fixable.Max(p => Math.Max(0, p.Size)));

        var free = FreeSpaceFor(installPath);

        if (free >= 0 && needed > free)
        {
            // Not an exception: the caller already shows the error list, and throwing here
            // would lose the quarantine step that runs alongside this.
            errors.Add(
                $"Not enough free space to repair. About {Gb(needed)} is needed on " +
                $"{Path.GetPathRoot(Path.GetFullPath(installPath))?.TrimEnd('\\')} but only {Gb(free)} is free.");

            Log.Write($"repair: refusing to start — needs {needed:N0} bytes, {free:N0} free");
            return new RepairOutcome(0, 0, errors);
        }

        // Sequential. These are multi-gigabyte archives and six at once would compete for the
        // same disk and the same link for no gain — unlike the payload, which is hundreds of
        // small files where round-trips dominate.
        var done = 0;
        foreach (var problem in fixable)
        {
            ct.ThrowIfCancellationRequested();

            var name = Path.GetFileName(problem.Path);
            progress.Report(new SyncProgress($"Downloading {name}", done, fixable.Count));

            /*
             * Per-file byte progress, not just a file counter.
             *
             * These are multi-gigabyte files fetched one at a time, so the counter moves once
             * every several minutes -- on the satellite link this was reported from, common.MPQ
             * alone is about eighteen minutes during which nothing on screen changed at all. A
             * repair that looks frozen gets killed halfway through, which is how a player ends
             * up with less of a client than they started with.
             */
            var current = done;
            var fileProgress = new Progress<DownloadProgress>(p =>
            {
                var detail = p.Stage switch
                {
                    DownloadStage.Verifying => "checking the file is intact",
                    DownloadStage.Retrying => $"connection dropped, resuming ({p.Attempt} of {p.Attempts})",
                    _ => p.Total > 0 ? $"{Gb(p.Bytes)} of {Gb(p.Total)}" : Gb(p.Bytes),
                };

                progress.Report(new SyncProgress($"Downloading {name} — {detail}", current, fixable.Count));
            });

            try
            {
                await DownloadAsync(installPath, problem, fileProgress, ct);
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
    ///
    /// ★★ THIS USED TO BE ONE SHOT, AND THAT WAS THE WRONG PLACE TO SAVE CODE.
    ///
    /// It was a single GetAsync streamed to a temp: any drop mid-file threw, the temp was
    /// deleted, the file was recorded as an error and the loop moved on. Repair is precisely
    /// what a player is told to press when their client is already broken, and the file it most
    /// often restores is common.MPQ at 2.88 GB — around eighteen minutes of uninterrupted
    /// connection at 2.7 MB/s. One dropout on a satellite link threw all of it away, and the
    /// only advice available was to start again.
    ///
    /// It now shares <see cref="ResilientDownload"/> with client acquisition, so it resumes with
    /// a byte range and retries, and every guarantee this method already made is enforced in
    /// there instead of here: temp-then-move, length checked, and the reassembled file hashed
    /// END TO END before it is accepted — a resumed file is not trusted merely because each of
    /// its pieces arrived cleanly. Failing every attempt still throws, so the caller keeps
    /// reporting an error rather than counting a file it never restored.
    ///
    /// The temp name became deterministic in the process. That is what makes resumption
    /// possible at all: the old Guid-per-call name meant a retried repair could never find the
    /// partial its predecessor left. Repair is sequential, so there is nothing to collide with.
    /// </summary>
    private async Task DownloadAsync(
        string installPath, IntegrityProblem problem,
        IProgress<DownloadProgress> progress, CancellationToken ct)
    {
        var destination = Path.Combine(installPath, problem.Path);

        await new ResilientDownload(_http).FetchAsync(
            problem.Url!, destination, problem.Size, problem.Sha256, problem.Path, progress, ct);
    }

    /// <summary>
    /// Free bytes on the drive holding the install, or -1 when it cannot be determined — in
    /// which case the check is skipped rather than guessed at. Refusing a repair because we
    /// could not read a drive would be worse than attempting one that runs out of room.
    /// </summary>
    private static long FreeSpaceFor(string installPath)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(installPath));
            return string.IsNullOrEmpty(root) ? -1 : new DriveInfo(root).AvailableFreeSpace;
        }
        catch { return -1; }
    }

    private static string Gb(long bytes) =>
        bytes >= 1024L * 1024 * 1024
            ? $"{bytes / 1024.0 / 1024 / 1024:0.0} GB"
            : $"{bytes / 1024.0 / 1024:0.0} MB";
}
