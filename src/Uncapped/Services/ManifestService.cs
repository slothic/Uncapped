using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// The parsed manifest plus a hash of the exact bytes it came from. The hash lets the
/// re-check on PLAY skip the whole sync when nothing upstream has moved, so pressing PLAY
/// costs one HTTP request rather than a pass over every file on disk.
/// </summary>
public sealed record ManifestFetch(Manifest Manifest, string Hash);

public sealed class ManifestService
{
    private readonly HttpClient _http;

    public ManifestService(HttpClient http) => _http = http;

    private static string CachePath => Path.Combine(AppPaths.DataDir, "manifest.json");

    public async Task<ManifestFetch> FetchAsync(string url, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(url))
            throw new InvalidOperationException(
                $"No manifest URL configured. Set \"manifestUrl\" in {AppPaths.ConfigFile}.");

        // raw.githubusercontent.com sits behind a ~5 minute CDN cache. Fine for addon
        // updates, but the cache-buster keeps a just-pushed manifest from looking missing.
        var bust = url.Contains('?') ? "&" : "?";
        var requestUrl = $"{url}{bust}_={DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";

        var json = await _http.GetStringAsync(requestUrl, ct);
        var fetch = Parse(json);

        try
        {
            Directory.CreateDirectory(AppPaths.DataDir);
            await File.WriteAllTextAsync(CachePath, json, ct);
        }
        catch (Exception ex) { Log.Write($"manifest: could not cache — {ex.Message}"); }

        return fetch;
    }

    /// <summary>
    /// The last manifest that was successfully fetched, or null if there has never been one.
    ///
    /// Exists so that starting up with no network still verifies against something. Before
    /// this, an offline start enabled PLAY on no evidence at all — the launcher had no idea
    /// what the client was supposed to contain, so "playing offline with your current files"
    /// meant playing with whatever happened to be on disk. Being unable to check for a NEW
    /// release is not the same as being unable to check the files already here.
    /// </summary>
    public static ManifestFetch? LoadCached()
    {
        try
        {
            if (!File.Exists(CachePath)) return null;
            return Parse(File.ReadAllText(CachePath));
        }
        catch (Exception ex)
        {
            Log.Write($"manifest: cached copy unusable — {ex.Message}");
            return null;
        }
    }

    private static ManifestFetch Parse(string json)
    {
        var manifest = JsonSerializer.Deserialize<Manifest>(json)
            ?? throw new InvalidDataException("Manifest was empty or unparseable.");

        if (manifest.ManifestVersion > 1)
            throw new InvalidDataException(
                $"This manifest needs a newer launcher (format v{manifest.ManifestVersion}). Please update.");

        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(json))).ToLowerInvariant();
        return new ManifestFetch(manifest, hash);
    }
}
