namespace Uncapped.Services;

/// <summary>What a download is doing right now, for a status line.</summary>
public enum DownloadStage
{
    Downloading,

    /// <summary>Hashing the reassembled file. On a multi-GB MPQ this is not instant.</summary>
    Verifying,

    /// <summary>The transfer broke and is about to be resumed.</summary>
    Retrying,
}

/// <param name="Bytes">Bytes of THIS file on disk so far.</param>
/// <param name="Total">Expected size, or 0 when the caller does not know it.</param>
public sealed record DownloadProgress(
    long Bytes, long Total, DownloadStage Stage, int Attempt, int Attempts);

/// <summary>
/// One download that survives a bad connection, shared by every path that fetches a large file
/// we can name a hash for.
///
/// WHY THIS IS ITS OWN CLASS
///
/// It began inside <see cref="ClientAcquirer"/>, because acquisition moves 16 GB and obviously
/// needed it. <see cref="RepairService"/> was written earlier and had none of it: a single
/// GetAsync streamed to a temp, and any drop mid-file threw, deleted the temp, recorded an
/// error and moved on. That is the worse place for it to be missing. Repair is what we tell a
/// player to press when their client is already broken, and the file it most often restores is
/// common.MPQ at 2.88 GB -- about eighteen minutes of uninterrupted connection on a 2.7 MB/s
/// satellite link. One dropout lost all of it, and the player was told to try again.
///
/// Copying the loop would have left two subtly different download paths in one launcher, and
/// the one nobody looks at is the one that rots -- which is exactly how repair ended up
/// lacking this in the first place. So it lives here once and both call it.
///
/// ★★ THE PROPERTY THAT MUST NOT BE TRADED AWAY FOR RESUMABILITY
///
/// Resume must never become a way for a corrupt partial to survive. Both callers exist to put
/// RIGHT bytes on disk in place of wrong ones, and a truncated or mismatched file is
/// indistinguishable, to the player, from the fault being repaired -- both read as "your files
/// are corrupt, PLAY is disabled". So, without exception:
///
///   * bytes land on a .uncapped-tmp file, never on the destination;
///   * the reassembled file is hashed END TO END after the last byte arrives, however many
///     attempts and ranges it was stitched together from -- a resumed file is not trusted
///     because its pieces each arrived cleanly;
///   * only a hash match moves it into place;
///   * a hash mismatch DELETES the temp, because nothing about those bytes is worth resuming;
///   * exhausting the attempts throws, so the caller reports an error rather than counting a
///     file it never restored.
///
/// .uncapped-tmp is in the baseline's toleratedPatterns, so debris from an interrupted run
/// cannot be reported as a foreign file either.
/// </summary>
public sealed class ResilientDownload
{
    /// <summary>
    /// Attempts before giving up. Each one RESUMES rather than restarting, so a link that
    /// drops every few minutes still finishes a 4 GB file.
    /// </summary>
    public const int DefaultAttempts = 5;

    private const int BufferBytes = 1024 * 256;

    /// <summary>Report every few MB: the copy loop runs ~4,000 times per GB at this buffer size.</summary>
    private const long ReportEvery = 4L * 1024 * 1024;

    private readonly HttpClient _http;

    public ResilientDownload(HttpClient http) => _http = http;

    /// <summary>The temp a transfer accumulates into. Deterministic, which is what makes resume possible.</summary>
    public static string TempFor(string destination) => destination + ".uncapped-tmp";

    /// <param name="expectedSize">
    /// Size the finished file must have. Pass 0 when it is genuinely unknown: the length check
    /// is then skipped and so is resumption, since there is no way to tell a partial file from
    /// a complete one.
    /// </param>
    /// <param name="expectedSha256">Null or empty skips hash verification. Callers with a hash should pass it.</param>
    /// <param name="label">Identifies the file in the log. Not shown to the player.</param>
    public async Task FetchAsync(
        string url,
        string destination,
        long expectedSize,
        string? expectedSha256,
        string label,
        IProgress<DownloadProgress>? progress,
        CancellationToken ct,
        int attempts = DefaultAttempts)
    {
        var directory = Path.GetDirectoryName(destination);
        if (directory is not null) Directory.CreateDirectory(directory);

        var temp = TempFor(destination);
        var resumable = expectedSize > 0;

        Exception? last = null;

        for (var attempt = 1; attempt <= attempts; attempt++)
        {
            ct.ThrowIfCancellationRequested();

            /*
             * ★ WRONG BYTES ARE NOT A CONNECTION PROBLEM, AND MUST NOT BE RETRIED LIKE ONE.
             *
             * If the whole file arrived from scratch and still comes out the wrong LENGTH or
             * the wrong HASH, the host is serving bytes that are not what we asked for, and
             * asking again gets the same bytes. Retrying would be pure delay -- and in
             * SyncService it would be actively
             * harmful: during a publish window GitHub's CDN serves the PREVIOUS release, so
             * every payload file mismatches at once. Backing off five times per file would turn
             * the CDN gate's careful wait-and-resync into a crawl and hide the real diagnosis.
             *
             * A mismatch after a RESUME is different: the partial on disk may have been
             * poisoned (a truncated earlier run, a host that mishandled the range). That is
             * worth exactly one clean attempt from zero, which is what falling through gives.
             */
            var fatal = false;

            long have = 0;

            if (resumable)
            {
                try { if (File.Exists(temp)) have = new FileInfo(temp).Length; }
                catch { have = 0; }

                // More on disk than the file is meant to be means the temp belongs to something
                // else, or to a version of this file we are no longer fetching. Start over.
                if (have > expectedSize)
                {
                    try { File.Delete(temp); } catch { /* the truncate below still handles it */ }
                    have = 0;
                }
            }

            var startedEmpty = have == 0;

            try
            {
                // have == expectedSize is the "resumed straight to complete" case: nothing left
                // to transfer, but everything below still has to pass before it is accepted.
                if (!resumable || have < expectedSize)
                    have = await TransferAsync(url, temp, have, expectedSize, label, progress, attempt, attempts, ct);

                var length = new FileInfo(temp).Length;

                /*
                 * ★★ A WRONG LENGTH IS THE SAME CLASS OF FAULT AS A WRONG HASH, AND MUST BE
                 * TREATED IDENTICALLY. It used to throw a bare IOException and leave the temp
                 * where it was, and both halves of that were wrong:
                 *
                 *   * IOException is not what SyncService classifies as Mismatched, so a stale
                 *     CDN whose file CHANGED SIZE -- the common case, since an addon rarely
                 *     edits to the same byte count -- never set LooksLikeStaleHost and never
                 *     engaged the wait-and-resync gate. The player got a hard "Update failed"
                 *     during a publish window instead of the pause that exists for it.
                 *   * Keeping the temp meant the next attempt resumed from the end of a body we
                 *     had already proven was not the file we wanted. That is what produced the
                 *     unrecoverable 416 loop handled in TransferAsync below.
                 */
                if (expectedSize > 0 && length != expectedSize)
                {
                    try { File.Delete(temp); } catch { /* best effort */ }

                    // Downloaded whole and still the wrong length: the host, not the connection.
                    fatal = startedEmpty;

                    throw new InvalidDataException($"expected {expectedSize:N0} bytes, got {length:N0}");
                }

                if (!string.IsNullOrEmpty(expectedSha256))
                {
                    progress?.Report(new DownloadProgress(length, expectedSize, DownloadStage.Verifying, attempt, attempts));

                    // End to end, over the whole reassembled file. A file stitched from several
                    // ranges is exactly the case this has to catch.
                    var actual = await Hashing.Sha256FileAsync(temp, ct);

                    if (!Hashing.Matches(actual, expectedSha256))
                    {
                        // Nothing about these bytes is worth resuming from.
                        try { File.Delete(temp); } catch { /* best effort */ }

                        // Downloaded whole and still wrong: the host, not the connection.
                        fatal = startedEmpty;

                        throw new InvalidDataException(
                            $"checksum mismatch (expected {expectedSha256[..Math.Min(12, expectedSha256.Length)]}…, " +
                            $"got {actual[..Math.Min(12, actual.Length)]}…)");
                    }
                }

                File.Move(temp, destination, overwrite: true);
                return;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                last = ex;
                Log.Write($"download: {label} attempt {attempt}/{attempts} failed — {ex.GetType().Name}: {ex.Message}");

                if (fatal)
                {
                    Log.Write($"download: {label} — not retrying, the host served the wrong bytes");
                    break;
                }

                if (attempt < attempts)
                {
                    progress?.Report(new DownloadProgress(have, expectedSize, DownloadStage.Retrying, attempt, attempts));

                    // Backs off a little each time. A satellite link that just dropped is not
                    // usually back in the same second.
                    await Task.Delay(TimeSpan.FromSeconds(3 * attempt), ct);
                }
            }
        }

        /*
         * ★★ A CONTENT MISMATCH -- LENGTH OR CHECKSUM -- MUST KEEP ITS TYPE ALL THE WAY OUT.
         *
         * SyncService classifies a stale host by CATCHING InvalidDataException -- that is what
         * populates SyncOutcome.Mismatched, which is what makes LooksLikeStaleHost true, which
         * is what makes the CDN publish gate wait and re-sync instead of declaring the release
         * broken. Wrapping this in an IOException for a tidier message would silently demote
         * every mismatch to a generic error and disable that gate, with nothing on screen to
         * say so. Rethrow it unchanged.
         */
        if (last is InvalidDataException) throw last;

        throw new IOException(
            $"could not be downloaded after {attempts} attempts. {last?.Message}", last);
    }

    /// <summary>
    /// Streams the remainder onto the temp, asking for a byte range when there is already
    /// something there.
    /// </summary>
    /// <returns>Total bytes on the temp when the stream ended.</returns>
    private async Task<long> TransferAsync(
        string url, string temp, long have, long expectedSize, string label,
        IProgress<DownloadProgress>? progress, int attempt, int attempts, CancellationToken ct)
    {
        var response = await SendAsync(url, have, ct);

        try
        {
            /*
             * ★★ 416 IS THE ONE FAILURE THAT NEVER CLEARS ITSELF, SO IT HAS TO BE CAUGHT HERE.
             *
             * "Requested Range Not Satisfiable" means our first-byte offset is at or past the
             * end of the body the host currently has: the partial on disk is at least as long
             * as the file being served. That is a real, reachable state, not a broken host.
             * manifest.json and every payload file are separate URLs on the same CDN and expire
             * independently, so a player can hold a manifest that says 144,411 bytes while the
             * edge still answers with the 137,715-byte previous release. The length check fails,
             * and (before the fix above) left the temp behind at exactly the stale body's size.
             *
             * From there nothing moves. `have` never changes, so the request never changes, so
             * the answer never changes -- through all five attempts, and through every relaunch
             * after that, because the temp is on disk. Two players hit exactly this on
             * 2026-08-16 and sat in it for over an hour across a dozen restarts; the log is a
             * single line repeating, which is the signature to look for.
             *
             * The partial is the only thing on our side of it, so discard it and ask again from
             * zero. Worst case we re-fetch a file that still mismatches -- an error that RESOLVES
             * when the CDN catches up, instead of one that cannot.
             */
            if (have > 0 && response.StatusCode == System.Net.HttpStatusCode.RequestedRangeNotSatisfiable)
            {
                Log.Write($"download: {label} — host has nothing past our partial ({have:N0} bytes), discarding it and restarting");

                response.Dispose();
                try { File.Delete(temp); } catch { /* FileMode.Create below truncates anyway */ }
                have = 0;

                response = await SendAsync(url, have, ct);
            }

            return await ReceiveAsync(
                response, temp, have, expectedSize, label, progress, attempt, attempts, ct);
        }
        finally
        {
            response.Dispose();
        }
    }

    /// <summary>One GET, asking for the tail of the file when there is already something on disk.</summary>
    private async Task<HttpResponseMessage> SendAsync(string url, long have, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (have > 0) request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(have, null);

        return await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
    }

    /// <summary>Streams an accepted response onto the temp.</summary>
    /// <returns>Total bytes on the temp when the stream ended.</returns>
    private static async Task<long> ReceiveAsync(
        HttpResponseMessage response, string temp, long have, long expectedSize, string label,
        IProgress<DownloadProgress>? progress, int attempt, int attempts, CancellationToken ct)
    {
        response.EnsureSuccessStatusCode();

        /*
         * A host that ignores the Range header answers 200 and starts from byte zero. Appending
         * that onto what we already have would produce a file of the right length made of the
         * wrong bytes -- which the hash would catch, but only after another full download. So
         * detect it and restart the file honestly instead.
         */
        var resuming = have > 0 && response.StatusCode == System.Net.HttpStatusCode.PartialContent;
        if (have > 0 && !resuming)
        {
            Log.Write($"download: {label} — host ignored the range request, restarting");
            have = 0;
        }

        var mode = resuming ? FileMode.Append : FileMode.Create;

        await using var input = await response.Content.ReadAsStreamAsync(ct);
        await using var output = new FileStream(
            temp, mode, FileAccess.Write, FileShare.None, BufferBytes, useAsync: true);

        var buffer = new byte[BufferBytes];
        var copied = have;
        var lastReport = 0L;
        int read;

        while ((read = await input.ReadAsync(buffer, ct)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, read), ct);
            copied += read;

            if (copied - lastReport >= ReportEvery)
            {
                lastReport = copied;
                progress?.Report(new DownloadProgress(
                    copied, expectedSize, DownloadStage.Downloading, attempt, attempts));
            }
        }

        return copied;
    }
}
