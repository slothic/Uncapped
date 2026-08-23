using System.Text;
using System.Text.RegularExpressions;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// What the three copies of the client version say: the one installed on this machine, the one
/// the CDN is currently handing out, and the one GitHub actually has.
/// </summary>
/// <param name="Installed">Version in the player's game folder, or null if the addon is missing.</param>
/// <param name="Cdn">Version the file host is serving right now.</param>
/// <param name="Latest">Version of the release being published, straight from GitHub.</param>
/// <param name="CdnCurrent">False when the CDN is still serving the previous release.</param>
public sealed record ClientVersions(int? Installed, int? Cdn, int? Latest, bool CdnCurrent)
{
    public bool Matches => Installed is not null && Latest is not null && Installed == Latest;

    /// <summary>One short line for the launcher's status panel.</summary>
    public string Describe()
    {
        if (Installed is null && Latest is null) return "";
        if (Installed is null) return $"Client v{Latest} available";
        // Not knowing the latest version is not the same as being on it — say only what we know.
        if (Latest is null) return $"Client v{Installed}";
        if (Installed == Latest) return $"Client v{Installed} · up to date";
        return Installed < Latest
            ? $"Client v{Installed} → v{Latest}"
            : $"Client v{Installed} (realm is on v{Latest})";
    }
}

/// <summary>
/// Reads the client version number out of the UncappedVersion addon.
///
/// That addon is the half of the server's version gate that gets kicked, so its CLIENT_VERSION
/// is the number that decides whether a player can stay logged in — which makes it the honest
/// thing to show them, and the right canary for "has this release finished publishing".
/// </summary>
public sealed class ClientVersionService
{
    /// <summary>Manifest path of the addon file the version is baked into.</summary>
    public const string VersionFilePath = "Interface/AddOns/UncappedVersion/UncappedVersion.lua";

    /// <summary>
    /// ⚠ The lookbehind is load-bearing. Without it this also matches
    /// <c>REQUIRED_CLIENT_VERSION = n</c> — the SERVER's half of the gate — and whichever of
    /// the two appears first in the file wins. The addon carries only CLIENT_VERSION today,
    /// but the two constants must be bumped together, which makes adding the other one to the
    /// same file a natural thing for somebody to do. If that happened, this would silently
    /// start reporting the server's number as the client's and the version display (and
    /// preflight's four-copy check, which uses the same pattern) would agree with itself for
    /// the wrong reason.
    /// </summary>
    private static readonly Regex VersionRx =
        new(@"(?<![A-Za-z_])CLIENT_VERSION\s*=\s*(\d+)", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private readonly HttpClient _http;
    private readonly CdnGate _gate;

    public ClientVersionService(HttpClient http)
    {
        _http = http;
        _gate = new CdnGate(http);
    }

    /// <summary>The manifest entry for the version addon, or null if this manifest has none.</summary>
    public static ManifestFile? FindVersionFile(Manifest manifest) =>
        manifest.Files.FirstOrDefault(f =>
            string.Equals(f.Path.Replace('\\', '/'), VersionFilePath, StringComparison.OrdinalIgnoreCase));

    public async Task<ClientVersions> CheckAsync(Manifest manifest, string? installPath, CancellationToken ct)
    {
        var installed = ReadInstalled(installPath);
        var entry = FindVersionFile(manifest);

        if (entry is null) return new ClientVersions(installed, null, null, true);

        var current = await _gate.IsCurrentAsync(entry, ct);
        var cdn = await TryReadAsync(entry.Url, ct);

        // While the CDN is behind, the number it serves is the *old* one, so it cannot answer
        // "what are we updating to". The API is not the same cache, so ask it directly — worth
        // one request purely to be able to name the version the player is waiting on.
        var latest = current ? cdn : await TryReadAsync(ToApiUrl(entry.Url), ct, github: true) ?? cdn;

        return new ClientVersions(installed, cdn, latest, current);
    }

    /// <summary>Version of the copy sitting in the player's game folder.</summary>
    public static int? ReadInstalled(string? installPath)
    {
        if (string.IsNullOrWhiteSpace(installPath)) return null;

        var relative = SyncService.NormalizeRelative(VersionFilePath);
        if (relative is null) return null;

        var path = Path.Combine(installPath, relative);
        try { return File.Exists(path) ? Parse(File.ReadAllText(path)) : null; }
        catch (Exception ex) { Log.Write($"installed version: {ex.Message}"); return null; }
    }

    private async Task<int?> TryReadAsync(string? url, CancellationToken ct, bool github = false)
    {
        if (string.IsNullOrWhiteSpace(url)) return null;

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            // Asks the contents API for the file itself rather than the JSON envelope it
            // wraps around a base64 copy of it.
            if (github) request.Headers.Accept.ParseAdd("application/vnd.github.raw");

            using var response = await _http.SendAsync(request, ct);

            // Unauthenticated API calls are rate limited to 60/hour per address. Hitting that
            // is not an error worth showing anyone: we simply do not get to name the version.
            if (!response.IsSuccessStatusCode) return null;

            return Parse(Encoding.UTF8.GetString(await response.Content.ReadAsByteArrayAsync(ct)));
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { Log.Write($"version read {url}: {ex.Message}"); return null; }
    }

    private static int? Parse(string lua)
    {
        var match = VersionRx.Match(lua);
        return match.Success && int.TryParse(match.Groups[1].Value, out var version) ? version : null;
    }

    /// <summary>
    /// Turns a raw.githubusercontent.com URL into the api.github.com contents URL for the same
    /// file. Derived rather than configured so repointing the manifest at another repo does not
    /// silently leave this checking the old one.
    /// </summary>
    internal static string? ToApiUrl(string rawUrl)
    {
        if (!Uri.TryCreate(rawUrl, UriKind.Absolute, out var uri)) return null;
        if (!uri.Host.Equals("raw.githubusercontent.com", StringComparison.OrdinalIgnoreCase)) return null;

        // /{owner}/{repo}/{ref}/{path...}
        var parts = uri.AbsolutePath.Trim('/').Split('/');
        if (parts.Length < 4) return null;

        var path = string.Join('/', parts.Skip(3));
        return $"https://api.github.com/repos/{parts[0]}/{parts[1]}/contents/{path}?ref={parts[2]}";
    }
}
