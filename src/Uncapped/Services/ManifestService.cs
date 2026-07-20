using System.Text.Json;
using Uncapped.Model;

namespace Uncapped.Services;

public sealed class ManifestService
{
    private readonly HttpClient _http;

    public ManifestService(HttpClient http) => _http = http;

    public async Task<Manifest> FetchAsync(string url, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(url))
            throw new InvalidOperationException(
                $"No manifest URL configured. Set \"manifestUrl\" in {AppPaths.ConfigFile}.");

        // raw.githubusercontent.com sits behind a ~5 minute CDN cache. Fine for addon
        // updates, but the cache-buster keeps a just-pushed manifest from looking missing.
        var bust = url.Contains('?') ? "&" : "?";
        var requestUrl = $"{url}{bust}_={DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";

        var json = await _http.GetStringAsync(requestUrl, ct);

        var manifest = JsonSerializer.Deserialize<Manifest>(json)
            ?? throw new InvalidDataException("Manifest was empty or unparseable.");

        if (manifest.ManifestVersion > 1)
            throw new InvalidDataException(
                $"This manifest needs a newer launcher (format v{manifest.ManifestVersion}). Please update.");

        return manifest;
    }
}
