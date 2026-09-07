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

    // Raised from 1200 when news started being generated from the patch-note TL;DRs, which run
    // to about two thousand characters for a big release. The detail pane is a wrapping
    // TextBlock inside a ScrollViewer, so length costs scrolling and nothing else — whereas
    // clipping cost the last few bullets of every release, silently.
    private const int MaxBody = 6000;

    // A body is a bullet list, so it is allowed real line breaks. Bounded anyway: this file
    // arrives over plain HTTP and a pathological one should degrade, not wedge the panel.
    private const int MaxBodyLines = 80;

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
                    Body = ClipBody(i.Body),
                })
                .ToList();
        }
        catch (Exception ex)
        {
            Log.Write($"news: falling back to the manifest ({ex.Message})");
            return manifest.News;
        }
    }

    /// <summary>
    /// Single-line fields: the date and the title, both of which land in a one-line TextBlock
    /// where a stray newline would just look like a rendering fault.
    /// </summary>
    private static string Clip(string? value, int max)
    {
        if (string.IsNullOrEmpty(value)) return "";
        var flat = value.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return flat.Length <= max ? flat : flat[..max].TrimEnd() + "…";
    }

    /// <summary>
    /// The body keeps its line breaks — it is a bullet list, and flattening it into one
    /// paragraph was what made a generated release read as a wall of text.
    ///
    /// Still bounded on both axes. The value only ever reaches TextBlock.Text, which does not
    /// interpret markup, so the risk being managed here is a runaway file rather than an
    /// injection.
    /// </summary>
    private static string ClipBody(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "";

        var lines = value
            .Replace("\r\n", "\n")
            .Replace('\r', '\n')
            .Split('\n')
            .Select(l => l.TrimEnd())
            .ToList();

        // Collapse runs of blank lines rather than dropping them: one blank line is a
        // deliberate paragraph break, six are an accident of chunking.
        var kept = new List<string>();
        var blank = 0;
        foreach (var line in lines)
        {
            if (line.Length == 0)
            {
                if (++blank > 1) continue;
            }
            else blank = 0;

            kept.Add(line);
            if (kept.Count >= MaxBodyLines) break;
        }

        var text = string.Join("\n", kept).Trim();
        return text.Length <= MaxBody ? text : text[..MaxBody].TrimEnd() + "…";
    }
}
