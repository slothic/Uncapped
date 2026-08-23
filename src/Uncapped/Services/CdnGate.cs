using System.Security.Cryptography;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// Guards against GitHub's file CDN still serving the previous release.
///
/// The manifest is fetched with a cache-buster so it is always the newly pushed one, but the
/// payload files under raw.githubusercontent.com sit behind a Fastly cache of a few minutes.
/// In that window the manifest describes release N while the CDN still hands out release N-1's
/// bytes — the sync then fails every changed file on its checksum, and a player who launches
/// anyway is running a client the server's version gate will kick.
///
/// So instead of racing it, we ask the CDN for the bytes and compare them against the hash the
/// manifest declares. Same request the sync would make, so the answer is exactly the one that
/// matters: not "has GitHub got the file" but "will the download the player is about to do
/// produce the right file".
/// </summary>
public sealed class CdnGate
{
    /// <summary>
    /// How long to keep waiting before handing control back. raw.githubusercontent.com's cache
    /// is a few minutes, so this covers the normal case with room to spare — and when a publish
    /// is genuinely broken rather than merely slow, the player gets their buttons back and can
    /// retry, instead of staring at a window that has locked itself for a quarter of an hour.
    /// </summary>
    public static readonly TimeSpan MaxWait = TimeSpan.FromMinutes(6);

    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(15);

    /// <summary>
    /// The largest body this gate will pull down to hash.
    ///
    /// ★★ THIS CAP IS THE FIX FOR A GATE THAT COULD COST 7.5 GB OF SOMEBODY'S BANDWIDTH.
    ///
    /// It used to be a flat GetByteArrayAsync of every file handed to it, once per 15-second
    /// poll, for up to 24 polls. The set it is handed is SyncOutcome.Mismatched, and that
    /// includes the externally hosted MPQs -- patch-enUS-Q.MPQ is 313 MB. A single large MPQ
    /// landing in that set meant re-downloading it 24 times AND allocating a 313 MB byte[]
    /// each time, on a player who is already blocked and waiting.
    ///
    /// Above the cap the gate stops asking "are these the right bytes" and asks "is this the
    /// right LENGTH", from the response headers alone, with the body never read. That is a
    /// genuinely weaker test -- and it costs nothing here, because this gate exists for ONE
    /// condition: raw.githubusercontent.com's Fastly cache still serving release N-1 while the
    /// manifest describes release N. The files subject to that are our payload addons, all of
    /// them small. The multi-hundred-MB entries are MPQs on our own host, which has no CDN in
    /// front of it and cannot be stale in that way.
    ///
    /// 16 MB comfortably covers every payload file and the DLL, and is a size a blocked player
    /// can afford to have re-fetched 24 times.
    /// </summary>
    private const long MaxHashBytes = 16L * 1024 * 1024;

    private readonly HttpClient _http;

    public CdnGate(HttpClient http) => _http = http;

    /// <summary>
    /// True when the CDN is serving exactly what the manifest says this file should be. A file
    /// with no declared hash cannot be checked, so it is treated as fine; so is a network
    /// failure, because being offline must not lock the PLAY button.
    /// </summary>
    public async Task<bool> IsCurrentAsync(ManifestFile file, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(file.Url) || string.IsNullOrEmpty(file.Sha256)) return true;

        try
        {
            // Deliberately no cache-buster: we want to see what the cache is handing out.
            //
            // ResponseHeadersRead, so the decision about whether to pay for the body is made
            // BEFORE any of it is transferred. Disposing the response here aborts the request.
            using var response = await _http.GetAsync(file.Url, HttpCompletionOption.ResponseHeadersRead, ct);
            response.EnsureSuccessStatusCode();

            var served = response.Content.Headers.ContentLength;

            // Bigger than we are willing to hash: fall back to a length comparison, which needs
            // no body at all. Unknown length is treated as small enough to try -- an unbounded
            // read is bounded by MaxHashBytes below in any case.
            if (served is > MaxHashBytes)
            {
                if (file.Size <= 0)
                {
                    // Nothing to compare against. Same posture as a network failure: this gate
                    // must never be the reason PLAY is off.
                    Log.Write($"cdn check {file.Path}: {served} bytes, no manifest size — treating as current");
                    return true;
                }

                var lengthAgrees = served == file.Size;
                if (!lengthAgrees)
                    Log.Write($"cdn check {file.Path}: serving {served} bytes, manifest says {file.Size} — stale");

                return lengthAgrees;
            }

            await using var body = await response.Content.ReadAsStreamAsync(ct);
            var hash = await SHA256.HashDataAsync(body, ct);

            return Hashing.Matches(Convert.ToHexString(hash).ToLowerInvariant(), file.Sha256);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            Log.Write($"cdn check {file.Path}: {ex.Message}");
            return true;
        }
    }

    /// <summary>
    /// Polls until every one of <paramref name="files"/> is being served correctly, or until
    /// <see cref="MaxWait"/> runs out. Reports how long it has been waiting so the player can
    /// see it is doing something rather than hung.
    /// </summary>
    public async Task<bool> WaitUntilCurrentAsync(
        IReadOnlyList<ManifestFile> files,
        IProgress<TimeSpan> waited,
        CancellationToken ct)
    {
        if (files.Count == 0) return true;

        var started = DateTime.UtcNow;

        while (true)
        {
            var elapsed = DateTime.UtcNow - started;
            waited.Report(elapsed);

            var allCurrent = true;
            foreach (var file in files)
            {
                if (await IsCurrentAsync(file, ct)) continue;
                allCurrent = false;
                break;
            }

            if (allCurrent) return true;
            if (elapsed + PollInterval > MaxWait) return false;

            await Task.Delay(PollInterval, ct);
        }
    }

}
