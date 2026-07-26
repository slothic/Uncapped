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
            var bytes = await _http.GetByteArrayAsync(file.Url, ct);
            return Hashing.Matches(Sha256(bytes), file.Sha256);
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

    private static string Sha256(byte[] bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}
