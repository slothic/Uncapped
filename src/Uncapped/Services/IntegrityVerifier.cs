using System.Collections.Concurrent;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>Why a file failed. Ordered by how much it matters.</summary>
public enum IntegrityFault
{
    /// <summary>A file the client needs is not there.</summary>
    Missing,

    /// <summary>Present, but not the bytes we published.</summary>
    Corrupt,

    /// <summary>Under a checked root and part of no Uncapped release.</summary>
    Foreign,
}

/// <param name="Path">Install-root-relative, as it exists (or should exist) on this client.</param>
/// <param name="Blocking">
/// Whether this alone is reason to refuse to launch. Missing and corrupt REQUIRED files are;
/// foreign files and the informational tail are not.
/// </param>
public sealed record IntegrityProblem(
    string Path, IntegrityFault Fault, bool Blocking, long Size = 0, string? Url = null,
    string? Sha256 = null)
{
    /// <summary>A foreign MPQ under Data\ — the case that actively breaks the client.</summary>
    public bool IsForeignArchive =>
        Fault == IntegrityFault.Foreign &&
        Path.StartsWith("Data" + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) &&
        Path.EndsWith(".mpq", StringComparison.OrdinalIgnoreCase);
}

public sealed record IntegrityReport(
    List<IntegrityProblem> Problems, int Checked, int Skipped, long BytesHashed)
{
    public IEnumerable<IntegrityProblem> Blocking => Problems.Where(p => p.Blocking);
    public IEnumerable<IntegrityProblem> Foreign  => Problems.Where(p => p.Fault == IntegrityFault.Foreign);

    /// <summary>Repairable: everything blocking, plus foreign archives we can quarantine.</summary>
    public IEnumerable<IntegrityProblem> Repairable =>
        Problems.Where(p => p.Blocking || p.IsForeignArchive);

    public bool CanPlay => !Blocking.Any();
    public bool Clean => Problems.Count == 0;
}

/// <summary>
/// Decides whether this install is a legitimate, intact Uncapped client.
///
/// Two sources of truth, combined: <see cref="Manifest"/> for the files we publish and
/// <see cref="Baseline"/> for the stock client underneath. A file under a checked root that is
/// in neither is, by construction, not part of any release we shipped.
///
/// The expensive part is hashing, and it is paid once — see <see cref="LauncherState.VerifiedFiles"/>.
/// After the first pass a clean client re-verifies from cached hashes in well under a second.
/// </summary>
public sealed class IntegrityVerifier
{
    /// <summary>Disk-bound work; the same degree the sync uses for its own hashing.</summary>
    private const int HashConcurrency = 8;

    private readonly string _installPath;
    private readonly Manifest _manifest;
    private readonly Baseline _baseline;
    private readonly ClientLocale? _locale;
    private readonly LauncherState _state;

    public IntegrityVerifier(
        string installPath, Manifest manifest, Baseline baseline, ClientLocale? locale, LauncherState state)
    {
        _installPath = installPath;
        _manifest = manifest;
        _baseline = baseline;
        _locale = locale;
        _state = state;
    }

    public async Task<IntegrityReport> VerifyAsync(IProgress<SyncProgress> progress, CancellationToken ct)
    {
        var problems = new ConcurrentBag<IntegrityProblem>();
        var expected = BuildExpectedSet();

        var checkedCount = 0;
        var skipped = 0;
        var bytesHashed = 0L;

        // ---- Pass 1: every file we expect, in the state we expect it. ----
        var total = expected.Count;
        var done = 0;

        await Parallel.ForEachAsync(
            expected.Values,
            new ParallelOptions { MaxDegreeOfParallelism = HashConcurrency, CancellationToken = ct },
            async (want, token) =>
            {
                var full = Path.Combine(_installPath, want.Relative);

                if (!File.Exists(full))
                {
                    // A file we do not require and that is simply absent is not worth a word:
                    // Repair.exe, a retired patch, half the Documentation folder on an install
                    // that came from the Archive zips rather than the torrent.
                    if (want.Blocking)
                        problems.Add(new IntegrityProblem(
                            want.Relative, IntegrityFault.Missing, true, want.Size, want.Url, want.Sha256));
                    else
                        Interlocked.Increment(ref skipped);
                }
                else
                {
                    var info = new FileInfo(full);

                    // Size is free and settles most mismatches without reading a byte.
                    var sizeOk = want.Size <= 0 || info.Length == want.Size;

                    if (!sizeOk)
                    {
                        problems.Add(new IntegrityProblem(
                            want.Relative, IntegrityFault.Corrupt, want.Blocking, want.Size, want.Url, want.Sha256));
                    }
                    else if (!string.IsNullOrEmpty(want.Sha256))
                    {
                        var (actual, hashed) = await HashWithCacheAsync(want.Relative, full, info, token);
                        Interlocked.Add(ref bytesHashed, hashed);

                        if (!Hashing.Matches(actual, want.Sha256))
                            problems.Add(new IntegrityProblem(
                                want.Relative, IntegrityFault.Corrupt, want.Blocking, want.Size, want.Url, want.Sha256));
                    }

                    Interlocked.Increment(ref checkedCount);
                }

                var n = Interlocked.Increment(ref done);
                progress.Report(new SyncProgress("Verifying your game files", n, total));
            });

        // ---- Pass 2: anything under a checked root that we cannot account for. ----
        foreach (var stray in FindUnaccountedFor(expected, ct))
            problems.Add(stray);

        // Persist the hashes learned this run so the next launch is fast. Trimmed to what is
        // still expected, or a client that has been reinstalled a few times accumulates
        // entries for files that no longer exist.
        PruneCache(expected);
        _state.Save();

        var ordered = problems
            .OrderByDescending(p => p.Blocking)
            .ThenBy(p => p.Fault)
            .ThenBy(p => p.Path, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new IntegrityReport(ordered, checkedCount, skipped, bytesHashed);
    }

    // ---------- what we expect ----------

    /// <param name="Blocking">A required file. Absent or wrong, the client does not launch.</param>
    private sealed record Expected(string Relative, string Sha256, long Size, bool Blocking, string? Url);

    /// <summary>
    /// Every file that legitimately belongs to this install, keyed by relative path.
    ///
    /// The manifest wins on collisions. Our published patches live in the same folder as the
    /// stock ones and a stale baseline entry must never override the file we are shipping
    /// today — the manifest is regenerated every release, the baseline essentially never.
    /// </summary>
    private Dictionary<string, Expected> BuildExpectedSet()
    {
        var expected = new Dictionary<string, Expected>(StringComparer.OrdinalIgnoreCase);

        foreach (var file in _baseline.Files)
        {
            // A client in another language has different bytes under Data\<locale>\. Those
            // entries cannot be checked and must not be guessed at.
            if (file.Locale && !LocaleMatches()) continue;

            var relative = Place(file.Path);
            if (relative is null) continue;

            expected[relative] = new Expected(relative, file.Sha256, file.Size, file.Required, file.Url);
        }

        foreach (var file in _manifest.Files)
        {
            var relative = Place(file.Path);
            if (relative is null) continue;

            // Everything we publish is required: the payload is exactly the set of files the
            // server's version gate is about to check for.
            expected[relative] = new Expected(relative, file.Sha256, file.Size, true, file.Url);
        }

        return expected;
    }

    private bool LocaleMatches() =>
        _locale is null || _locale.Code.Equals(_baseline.Locale, StringComparison.OrdinalIgnoreCase);

    private string? Place(string manifestPath)
    {
        var relative = SyncService.NormalizeRelative(manifestPath);
        return relative is null ? null : _locale?.Remap(relative) ?? relative;
    }

    // ---------- the foreign scan ----------

    /// <summary>
    /// Walks the checked roots and reports anything not in <paramref name="expected"/>.
    ///
    /// This is the half that catches a patch-enUS-X.MPQ carried over from another server —
    /// the file that makes a client behave in ways nothing on our side explains.
    /// </summary>
    private List<IntegrityProblem> FindUnaccountedFor(
        Dictionary<string, Expected> expected, CancellationToken ct)
    {
        var found = new List<IntegrityProblem>();

        foreach (var root in _baseline.CheckedRoots)
        {
            var dir = Path.Combine(_installPath, root);
            if (!Directory.Exists(dir)) continue;

            foreach (var full in SafeEnumerate(dir))
            {
                ct.ThrowIfCancellationRequested();

                var relative = full.Substring(_installPath.Length).TrimStart(Path.DirectorySeparatorChar);
                if (expected.ContainsKey(relative)) continue;
                if (IsTolerated(relative)) continue;

                found.Add(new IntegrityProblem(
                    relative, IntegrityFault.Foreign, Blocking: false, SafeLength(full)));
            }
        }

        // Loose files in the install root, by extension. Not recursive — a folder someone
        // dropped in the game directory is not our business, but a stray .dll beside the
        // client is loaded by it.
        foreach (var full in SafeEnumerateTop(_installPath))
        {
            ct.ThrowIfCancellationRequested();

            var ext = Path.GetExtension(full);
            if (!_baseline.CheckRootFiles.Any(e => e.Equals(ext, StringComparison.OrdinalIgnoreCase)))
                continue;

            var relative = Path.GetFileName(full);
            if (expected.ContainsKey(relative)) continue;
            if (IsTolerated(relative)) continue;

            found.Add(new IntegrityProblem(
                relative, IntegrityFault.Foreign, Blocking: false, SafeLength(full)));
        }

        return found;
    }

    /// <summary>
    /// Files that may be present without being evidence of anything: ones the launcher itself
    /// creates or renames, working files, our own quarantine folder, and locale folders for a
    /// language this baseline cannot speak to.
    /// </summary>
    private bool IsTolerated(string relative)
    {
        var name = Path.GetFileName(relative);

        if (_baseline.ToleratedNames.Any(n => n.Equals(name, StringComparison.OrdinalIgnoreCase)))
            return true;

        foreach (var pattern in _baseline.ToleratedPatterns)
            if (Matches(name, pattern)) return true;

        var parts = relative.Split(Path.DirectorySeparatorChar);

        // Where Repair puts foreign archives. Flagging our own quarantine would make the
        // warning permanent and un-clearable.
        if (parts.Length > 1 &&
            parts[0].Equals("Data", StringComparison.OrdinalIgnoreCase) &&
            parts[1].Equals(RepairService.QuarantineFolder, StringComparison.OrdinalIgnoreCase))
            return true;

        // Locale folders we have no hashes for.
        //
        // The baseline is generated from one language, so Data\<locale>\ can only be judged
        // when that language is the one on disk. Two cases end up here:
        //
        //   * a SECOND language installed beside the first — legitimate, and unverifiable;
        //   * every locale folder on a client whose language is not the baseline's at all,
        //     INCLUDING the one it is actually running.
        //
        // The second case is the one that matters and it was wrong at first: a deDE client had
        // its own Data\deDE folder reported as foreign, i.e. the launcher told a player with a
        // perfectly good German install that we could not recognise it. Skipping the hash
        // checks for a locale while still calling its files unaccounted-for is incoherent —
        // either we can speak to that folder or we cannot.
        //
        // The cost is real and worth stating: on a non-enUS client a foreign patch-deDE-X.MPQ
        // goes unnoticed. That is a limit of publishing one baseline, not something to paper
        // over by guessing. Fix it by publishing a baseline per locale, not by accusing people.
        if (parts.Length > 2 &&
            parts[0].Equals("Data", StringComparison.OrdinalIgnoreCase) &&
            ClientLocale.IsLocaleCode(parts[1]))
        {
            var verifiable =
                LocaleMatches() &&
                parts[1].Equals(_baseline.Locale, StringComparison.OrdinalIgnoreCase);

            if (!verifiable) return true;
        }

        return false;
    }

    /// <summary>Case-insensitive glob supporting * and ?, which is all the patterns use.</summary>
    private static bool Matches(string name, string pattern)
    {
        var regex = "^" + System.Text.RegularExpressions.Regex.Escape(pattern)
            .Replace("\\*", ".*")
            .Replace("\\?", ".") + "$";

        return System.Text.RegularExpressions.Regex.IsMatch(
            name, regex, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    }

    // ---------- hashing, with the cache that makes this affordable ----------

    /// <returns>The hash, and how many bytes were actually read to get it (0 on a cache hit).</returns>
    private async Task<(string Hash, long BytesRead)> HashWithCacheAsync(
        string relative, string full, FileInfo info, CancellationToken ct)
    {
        var ticks = info.LastWriteTimeUtc.Ticks;

        if (_state.VerifiedFiles.TryGetValue(relative, out var cached) &&
            cached.Size == info.Length &&
            cached.WrittenTicks == ticks &&
            !string.IsNullOrEmpty(cached.Sha256))
        {
            return (cached.Sha256, 0);
        }

        string hash;
        try { hash = await Hashing.Sha256FileAsync(full, ct); }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            // An unreadable file is reported as a mismatch rather than crashing the pass;
            // the empty hash cannot match anything.
            Log.Write($"integrity: could not read {relative} — {ex.Message}");
            return ("", 0);
        }

        // ConcurrentDictionary would be tidier, but the state object is serialised as a plain
        // Dictionary and this is the only writer contending for it.
        lock (_state.VerifiedFiles)
        {
            _state.VerifiedFiles[relative] = new VerifiedFile
            {
                Size = info.Length,
                WrittenTicks = ticks,
                Sha256 = hash,
            };
        }

        return (hash, info.Length);
    }

    private void PruneCache(Dictionary<string, Expected> expected)
    {
        var stale = _state.VerifiedFiles.Keys.Where(k => !expected.ContainsKey(k)).ToList();
        foreach (var key in stale) _state.VerifiedFiles.Remove(key);
    }

    // ---------- filesystem helpers ----------

    /// <summary>
    /// Recursive enumeration that survives a folder it cannot open. The default
    /// EnumerateFiles throws partway through and loses every result it had already found.
    /// </summary>
    private static IEnumerable<string> SafeEnumerate(string dir)
    {
        var stack = new Stack<string>();
        stack.Push(dir);

        while (stack.Count > 0)
        {
            var current = stack.Pop();

            string[] subdirs;
            try { subdirs = Directory.GetDirectories(current); }
            catch { continue; }

            foreach (var sub in subdirs) stack.Push(sub);

            string[] files;
            try { files = Directory.GetFiles(current); }
            catch { continue; }

            foreach (var file in files) yield return file;
        }
    }

    private static IEnumerable<string> SafeEnumerateTop(string dir)
    {
        try { return Directory.GetFiles(dir); }
        catch { return Array.Empty<string>(); }
    }

    private static long SafeLength(string path)
    {
        try { return new FileInfo(path).Length; }
        catch { return 0; }
    }
}
