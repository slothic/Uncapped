using System.Text.Json;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// Fetches the client baseline, and keeps the last good copy on disk.
///
/// The cached copy is the point. Verification is what stands between a player and a client
/// that gets kicked at the login screen, so it must not switch itself off the moment the patch
/// host is unreachable — "offline" would otherwise become the way to skip every check.
/// </summary>
public sealed class BaselineService
{
    private readonly HttpClient _http;

    public BaselineService(HttpClient http) => _http = http;

    private static string CachePath => Path.Combine(AppPaths.DataDir, "baseline.json");

    /// <summary>
    /// The baseline to verify against, or null when the manifest publishes none and nothing
    /// has ever been cached — in which case there is nothing to check and the caller falls
    /// back to manifest-only sync.
    /// </summary>
    public async Task<Baseline?> LoadAsync(Manifest manifest, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(manifest.BaselineUrl))
        {
            Log.Write("baseline: manifest publishes no baselineUrl; integrity check disabled");
            return null;
        }

        try
        {
            // Cache-busted for the same reason the manifest is: a stale baseline would
            // describe the previous release and fail every file it changed.
            var separator = manifest.BaselineUrl.Contains('?') ? '&' : '?';
            var url = $"{manifest.BaselineUrl}{separator}t={DateTime.UtcNow.Ticks}";

            var json = await _http.GetStringAsync(url, ct);
            var baseline = Parse(json);

            if (baseline is not null)
            {
                try
                {
                    Directory.CreateDirectory(AppPaths.DataDir);
                    await File.WriteAllTextAsync(CachePath, json, ct);
                }
                catch (Exception ex) { Log.Write($"baseline: could not cache — {ex.Message}"); }

                Log.Write($"baseline: {baseline.Files.Count} file(s), build {baseline.ClientBuild}, " +
                          $"locale {baseline.Locale}, generated {baseline.Generated}");
                return baseline;
            }
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { Log.Write($"baseline: fetch failed — {ex.Message}"); }

        return LoadCached();
    }

    private static Baseline? LoadCached()
    {
        try
        {
            if (!File.Exists(CachePath)) return null;

            var baseline = Parse(File.ReadAllText(CachePath));
            if (baseline is not null)
                Log.Write($"baseline: using cached copy ({baseline.Files.Count} files)");

            return baseline;
        }
        catch (Exception ex)
        {
            Log.Write($"baseline: cached copy unusable — {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// Parses, and refuses anything that would make the verifier misbehave.
    ///
    /// A baseline with no files would declare every file on disk foreign; one with no checked
    /// roots would check nothing at all. Both are far worse than having no baseline, so they
    /// are rejected rather than used.
    /// </summary>
    private static Baseline? Parse(string json)
    {
        var baseline = JsonSerializer.Deserialize<Baseline>(json);

        if (baseline is null) return null;

        if (baseline.Files.Count == 0)
        {
            Log.Write("baseline: rejected — no files listed");
            return null;
        }

        if (baseline.CheckedRoots.Count == 0)
        {
            Log.Write("baseline: rejected — no checked roots");
            return null;
        }

        return baseline;
    }
}
