using System.Text.Json;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// Fetches news from a URL separate to the manifest — in practice a static news.json dropped
/// into the registration site's document root, which is a live bind mount, so updating the
/// news is a file copy with no rebuild, no restart and no release.
///
/// Deliberately best-effort. News is decoration: if the realm box is down or slow, the player
/// still needs to be able to patch and play, so this has its own short timeout and every
/// failure path ends in "fall back to whatever the manifest carried".
/// </summary>
public sealed class NewsService
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(8);

    // The list scrolls, so this only needs to stop a runaway file rather than fit a panel.
    private const int MaxItems = 40;
    private const int MaxTitle = 90;
    private const int MaxBody = 1200;

    private readonly HttpClient _http;

    public NewsService(HttpClient http) => _http = http;

    /// <summary>
    /// Returns the remote list, or the manifest's own news if there is no URL configured or
    /// the fetch fails for any reason.
    /// </summary>
    public async Task<List<NewsItem>> LoadAsync(Manifest manifest, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(manifest.NewsUrl)) return manifest.News;

        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(Timeout);

            // Cache-buster: the news file is meant to be edited in place, and a proxy holding
            // a stale copy would make an update look like it had not applied.
            var separator = manifest.NewsUrl!.Contains('?') ? "&" : "?";
            var url = $"{manifest.NewsUrl}{separator}_={DateTimeOffset.UtcNow.ToUnixTimeSeconds()}";

            var json = await _http.GetStringAsync(url, timeout.Token);
            var items = JsonSerializer.Deserialize<List<NewsItem>>(json);

            if (items is null || items.Count == 0) return manifest.News;

            // This arrives over plain HTTP from a box we do not otherwise trust to be
            // well-behaved, so bound it rather than rendering whatever turns up. The values
            // only ever land in TextBlock.Text, which does not interpret markup.
            return items
                .Take(MaxItems)
                .Select(i => new NewsItem
                {
                    Date = Clip(i.Date, 20),
                    Title = Clip(i.Title, MaxTitle),
                    Body = Clip(i.Body, MaxBody),
                })
                .ToList();
        }
        catch (Exception ex)
        {
            Log.Write($"news: falling back to the manifest ({ex.Message})");
            return manifest.News;
        }
    }

    private static string Clip(string? value, int max)
    {
        if (string.IsNullOrEmpty(value)) return "";
        var flat = value.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return flat.Length <= max ? flat : flat[..max].TrimEnd() + "…";
    }
}
